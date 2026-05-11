# Sandbox fix-up scripts

These shell scripts are run inside a freshly-started sandbox container as
`root`, immediately after `podman run`, to make the container's user/group
environment match the host user invoking `sandbox`.

## How it works

1. `sandbox create` starts the container.
2. It reads `PRETTY_NAME` from `/etc/os-release` inside the container.
3. It looks up the matching script in `mapping.conf` (first regex wins).
4. It pipes that script via stdin into `podman exec -i --user root … bash -s`,
   passing the required variables as environment.

On a user's machine the scripts and `mapping.conf` are cached under
`~/.config/sandbox/fixups/`. The first time a given file is needed, it is
fetched from this directory on GitHub; after that the local copy is canonical
and is **never** overwritten by `sandbox`. Edit freely.

## Contract

Every script receives the following environment variables:

| Variable        | Meaning                                  |
|-----------------|------------------------------------------|
| `SANDBOX_USER`  | Host username to materialise inside      |
| `SANDBOX_UID`   | Host numeric UID                         |
| `SANDBOX_GID`   | Host numeric GID                         |
| `SANDBOX_NAME`  | The sandbox / container name             |

A compliant script must:

- Be **idempotent** (safe to re-run; guard everything with existence checks).
- Exit non-zero on failure (`set -e` is recommended).
- Resolve UID/GID collisions with users/groups already present in the base
  image (e.g. `ubuntu:latest` ships with `ubuntu` at UID 1000).
- Ensure a user named `$SANDBOX_USER` with UID `$SANDBOX_UID` and primary
  GID `$SANDBOX_GID` exists.
- Append `127.0.1.1 $SANDBOX_NAME` to `/etc/hosts`.
- Create `/tmp/runtime-user`, owned by `$SANDBOX_USER`, mode `700`.

Anything beyond that is fair game — install packages, set locales, configure
shell defaults, etc.

## Mapping file

`mapping.conf` is plain text: `<regex>  <script-filename>`, one per line.
The **last whitespace-separated token** on the line is the script filename;
everything before it is the regex. This means regexes can contain literal
spaces (e.g. `^Ubuntu 22\.`). First match wins. A trailing `.*` line is
the catch-all fallback. Regexes are matched against the `PRETTY_NAME`
field of `/etc/os-release` inside the container.

Examples:

```
^Ubuntu 22\.            ubuntu-22.sh   # release-specific
^Ubuntu\b               debian.sh      # any other Ubuntu
^Debian GNU/Linux 12    debian-12.sh
^Debian\b               debian.sh
.*                      default.sh
```

## Adding a custom distro

1. Drop a new script into `~/.config/sandbox/fixups/`.
2. Add a regex line to `~/.config/sandbox/fixups/mapping.conf` **above**
   the `.*` fallback.

## Forcing a re-fetch

The cache is fetch-once. To pick up upstream changes:

```
rm ~/.config/sandbox/fixups/debian.sh           # one file
rm -rf ~/.config/sandbox/fixups/                # everything
```

The next `sandbox create` will re-download whatever's missing.

## Override at invocation time

`sandbox create --fixup <script-name> …` bypasses the regex matching and
uses `<script-name>` directly (looked up in the cache; fetched if missing).
Handy for derived images whose `PRETTY_NAME` doesn't match any regex.
