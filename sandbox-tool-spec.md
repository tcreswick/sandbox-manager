# `sandbox` — A Container-Based Dev Sandbox CLI

Build a small CLI for spinning up and managing isolated podman containers as
development sandboxes, primarily for use with AI coding agents (e.g. pi.dev,
Claude Code, Aider) that need broad sudo + filesystem access but should not
be allowed to touch the host system or its credentials.

This document specifies the design and captures the technical decisions and
gotchas already worked through. Use it as a brief — feel free to deviate
where it makes the design better.

## Goal

Replace `distrobox` for use cases where its tight host integration is a
liability. `distrobox` bind-mounts the entire host filesystem at `/run/host`,
shares /tmp/dev/sys/IPC, and was never designed to isolate. We want:

- **Sudo inside the sandbox** — agents can install packages, modify configs,
  bind to privileged ports.
- **No access to host filesystem** outside explicitly bind-mounted paths.
- **No access to host credentials** — `~/.ssh`, `~/.aws`, `~/.config/gh`,
  Bitwarden agent socket, etc. are not visible.
- **Host networking** — applications binding to ports inside the sandbox
  appear on the host's network interface directly. No bridge, no NAT, no
  port-forward bookkeeping.
- **Optional GUI** — apps started inside the sandbox can spawn windows on
  the host desktop (Wayland + XWayland).
- **Optional GPU** — hardware acceleration for graphical apps.
- **Persistent per-sandbox home** — kept on the host at
  `~/container-homes/<name>/`, survives container rebuilds.

## Non-Goals

- **Not a security boundary against sophisticated attackers.** The host
  kernel is trusted. The threat model is "agent does something stupid",
  "malicious npm postinstall", or "prompt injection from web content" — not
  state actors with kernel exploits.
- **Not a replacement for VMs.** For genuine isolation against kernel-level
  attacks, use a VM.
- **Not a multi-tenant tool.** Single user, single workstation.

## Architecture

Two artefacts:

1. **A Containerfile** that bakes per-distro customisations into a base
   image (user, sudo, locale, basic tools, GUI prep).
2. **A CLI wrapper** that wraps `podman run` / `exec` with the right flags
   for networking, GUI, GPU, volumes, etc.

Persistent state lives in:

- `~/container-homes/<name>/` — bind-mounted as `/home` inside the
  container. Survives `sandbox rm`.
- The container's writable layer — survives `stop`/`start`, lost on `rm`.

## Implementation Language

The reference snippets below are in fish, since the user shell is fish.
However, the tool should ideally be written in something more portable —
Python, Go, or Rust would all be fine. The CLI should not require any
particular host shell to use.

## Dynamic User

**The container's user must match the host user dynamically.** Do not
hardcode usernames. The current user (`whoami` / `$USER` / `id -un`), UID
(`id -u`), and primary GID (`id -g`) on the host should be passed through to
the container as build args, so:

- File ownership in bind mounts matches across the boundary
  (combined with `--userns=keep-id`).
- The same Containerfile works for any user on any machine without edits.

```bash
podman build \
    --build-arg USERNAME=$(whoami) \
    --build-arg USER_UID=$(id -u) \
    --build-arg USER_GID=$(id -g) \
    -t sandbox:debian-trixie .
```

## CLI Design

```
sandbox build <variant>             # Build a sandbox image (e.g. debian-trixie)
sandbox create <image> <name>       # Create and start a sandbox container
sandbox shell <name>                # Open an interactive login shell
sandbox exec <name> <cmd...>        # Run a command (returns its exit code)
sandbox stop <name>                 # Stop without removing
sandbox start <name>                # Start a stopped sandbox
sandbox rm <name> [--purge]         # Remove container; --purge also drops home dir
sandbox list                        # List sandboxes
sandbox snapshot <name> <tag>       # podman commit the writable layer
sandbox restore <name> <tag>        # Recreate sandbox from a snapshot
```

Optional flags on `create`:

- `--no-gui` — omit X11/Wayland sockets
- `--no-gpu` — omit `/dev/dri` passthrough
- `--no-network-host` — use bridged networking instead of host
- `--home <path>` — override the default `~/container-homes/<name>` path
- `--work <path>` — bind-mount an extra working directory at `/work`

## Containerfile (Reference Starting Point)

```dockerfile
ARG BASE_IMAGE=debian:trixie
FROM ${BASE_IMAGE}

ARG USERNAME
ARG USER_UID
ARG USER_GID

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_GB.UTF-8
ENV LC_ALL=en_GB.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo ca-certificates curl wget git bash-completion \
        build-essential nodejs npm \
        nano vim less file tree htop jq \
        procps iproute2 iputils-ping dnsutils hostname \
        locales \
        x11-apps mesa-utils \
    && sed -i 's/# en_GB.UTF-8/en_GB.UTF-8/' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g ${USER_GID} ${USERNAME} \
    && useradd -u ${USER_UID} -g ${USER_GID} -s /bin/bash -G sudo ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 440 /etc/sudoers.d/${USERNAME}

CMD ["sleep", "infinity"]
```

An equivalent Arch variant should exist (using `pacman` and `wheel` group).
Other distros (Ubuntu, Fedora) are bonus.

## Run-time Flags (`podman run`)

```
--name <name>
--hostname <name>
--network=host
--userns=keep-id
--ipc=host                              # for X11 MIT-SHM
--device=/dev/dri                       # GPU acceleration
-e DISPLAY=$DISPLAY
-e WAYLAND_DISPLAY=$WAYLAND_DISPLAY
-e XDG_RUNTIME_DIR=/tmp/runtime-$USER
-e XAUTHORITY=/tmp/.Xauthority
-e QT_QPA_PLATFORM='wayland;xcb'
-e GDK_BACKEND='wayland,x11'
-v /tmp/.X11-unix:/tmp/.X11-unix
-v "$XDG_RUNTIME_DIR/wayland-0:/tmp/runtime-$USER/wayland-0"
-v "$XAUTHORITY:/tmp/.Xauthority:ro"
-v "$HOME/code:/work"
-v "$HOME/container-homes/<name>:/home"
<image> sleep infinity
```

Post-start fix-ups (must run after the container starts, as root):

```bash
podman exec --user root <name> bash -c "
    echo '127.0.1.1 <name>' >> /etc/hosts
    mkdir -p /tmp/runtime-$USER
    chown $USER:$USER /tmp/runtime-$USER
    chmod 700 /tmp/runtime-$USER
"
```

## Gotchas (Worked Out The Hard Way)

These bit during prototyping. Bake them into the design.

### 1. `--userns=keep-id` changes default user

With `--userns=keep-id`, the container's main process runs as your *host*
UID by default, not UID 0. `podman exec` without an explicit `--user`
inherits this — so you land as your unprivileged user, not root.

**Implication:** to get root, pass `--user root` (or `--user 0`).

### 2. Supplementary groups require name-based `--user`

If you pass `--user <uid>` (a number) to `podman exec`, only the primary
GID is set. Supplementary groups (e.g. `sudo`, `wheel`, `render`) are *not*
loaded. The sudoers `%sudo` rule won't apply.

**Implication:** always pass `--user <username>` (a name) to `podman exec`
when you want the user's full group membership. podman does an internal
`/etc/passwd` + `/etc/group` lookup and populates supplementary groups
from the result.

### 3. `bash -l` with extra args treats them as a script path

`bash -l hostname` does not execute the `hostname` command — it tries to
execute a *file* named `hostname` as a script. To run a command in a login
shell, use `bash -lc "command"`.

**Implication:** the `exec` subcommand must wrap user-supplied args in
`-lc "..."`. The `shell` subcommand (no args) should use plain `bash -l`.

### 4. Sudoers file mode must be 0440

If a file in `/etc/sudoers.d/` has any other mode, sudo silently rejects
it and behaves as if the user isn't in sudoers. The Containerfile sets
`chmod 440` explicitly.

### 5. Hostname must be in `/etc/hosts`

With `--network=host` and a custom `--hostname`, sudo (and other tools)
will warn "unable to resolve host <name>" because there's no entry in
the container's `/etc/hosts`. Add `127.0.1.1 <name>` post-start.

Cannot be baked into the image because the hostname is per-sandbox, not
per-image.

### 6. `XDG_RUNTIME_DIR` doesn't exist in container by default

Wayland socket lives at `$XDG_RUNTIME_DIR/wayland-0` on the host
(typically `/run/user/1000/wayland-0`). The container has no
`/run/user/1000` directory and creating one with the right permissions
through bind mounts is awkward.

**Implication:** remap `XDG_RUNTIME_DIR` to somewhere predictable
(`/tmp/runtime-$USER` works), bind-mount the Wayland socket into the
remapped path, create the dir at startup with 0700 perms.

### 7. `DEBIAN_FRONTEND=noninteractive`

Without it, debconf complains about missing dialog frontends on every
`apt install`. With it, prompts are skipped using package defaults —
correct behaviour for non-interactive container setup.

Set in the Containerfile via `ENV` so it persists for `podman exec`
sessions too.

### 8. Don't `useradd -m` into a bind-mounted /home

If `/home` is bind-mounted from the host before user creation, `useradd
-m` can fail (or do the wrong thing) because the directory layout
already exists. Either create the user without `-m` and `chown` the
existing home, or create the user during image build (before any bind
mount) — the Containerfile above does the latter.

### 9. Locale generation

Debian's container images strip locales. Many tools throw "locale not
set" warnings. The Containerfile generates `en_GB.UTF-8` (adjust for
preference) and sets `LANG`/`LC_ALL`. Skip if you don't care.

### 10. GUI/X11 security model is leaky

Sharing the X11 socket means any X client in the container can keylog,
screenshot, and inject events into other X11 windows on the host.
Wayland's protocol enforces isolation between clients, so native
Wayland apps inside the container can't do this. XWayland apps can.

For the agent use case this is usually fine, but worth surfacing in the
README so users understand the trade-off and can choose `--no-gui` for
sensitive sandboxes.

## Testing Checklist

The tool is "done" when these all work end-to-end:

- [ ] `sandbox build debian-trixie` creates an image
- [ ] `sandbox create sandbox:debian-trixie test` starts a container
- [ ] `sandbox shell test` drops into `/home/<user>` as `<user>`, login
      shell, `sudo` group present, `sudo whoami` returns `root` without
      a password prompt
- [ ] `sandbox exec test "hostname"` prints `test` and returns 0
- [ ] `sandbox exec test "ls /work"` shows the bind-mounted host dir
- [ ] Files created inside `/home/<user>` appear in
      `~/container-homes/test/<user>/` on the host with correct ownership
- [ ] `sandbox exec test "xclock"` pops a window on the host desktop
- [ ] `sandbox exec test "glxinfo | head -5"` shows a real GPU, not
      llvmpipe (software rendering)
- [ ] `curl localhost:8000` from the host hits a python http.server
      started inside the sandbox (host networking)
- [ ] `sandbox stop test` then `sandbox start test` preserves all
      filesystem state inside the container
- [ ] `sandbox rm test` removes the container; without `--purge`,
      `~/container-homes/test/` is preserved
- [ ] Smoke test: `/run/host` should NOT exist inside the container.
      `~/.ssh` from the host should NOT be visible from inside.
- [ ] Recreating a sandbox with the same name reuses the home directory,
      so dotfiles persist across rebuilds.

## Future Extensions

- **Profiles** — pre-configured combinations of flags (e.g. `dev-full`,
  `headless`, `network-isolated`) loadable from `~/.config/sandbox/profiles/`.
- **Snapshot/restore** — `podman commit` + tag tracking so an agent can
  be told "snapshot before this experiment, restore if it goes wrong."
- **Project-local sandboxes** — `cd ~/code/foo; sandbox shell` finds a
  `.sandbox/` directory and uses it.
- **Dotfile injection** — bind-mount a curated `~/.dotfiles-container/`
  into each new sandbox so shell setup, git config, etc. are shared.
- **Multiple users per sandbox** — currently single user only. Probably
  unnecessary.
- **Arch variant** — Containerfile and group setup for Arch base image.
- **Shell completions** — fish/bash/zsh completion for sandbox names,
  available images, etc.

## Repository Layout (Suggested)

```
sandbox/
├── README.md
├── Containerfile.debian
├── Containerfile.arch
├── sandbox                    # The CLI (Python/Go/Rust/whatever)
├── completions/
│   ├── sandbox.fish
│   └── sandbox.bash
└── tests/
    └── smoke.sh              # Run the testing checklist above
```

## Distribution

The CLI itself should be installable via:

- A single-file script that lives somewhere in `$PATH`, or
- A proper package (Python: `pipx install`; Go/Rust: a binary), or
- An AUR package (`paru -S sandbox-cli` style) once stable.

The Containerfiles ship alongside the CLI and are referenced by name
(`sandbox build debian-trixie` knows where to find them).
