# Sandbox Manager

A lightweight, daemonless CLI for running isolated dev sandboxes on Linux,
built on **rootless Podman**. Designed for spinning up disposable Linux
environments — useful for running AI agents, testing untrusted code, trying
new distros, or just keeping your host clean.

```
$ sandbox create debian:trixie work
…
✔ Sandbox 'work' is ready.

  Open a shell:     sandbox shell work
  Open as root:     sandbox shell --root work
  Run a command:    sandbox exec work <cmd>
  Stop / remove:    sandbox stop work  |  sandbox rm work
```

---

## ⚡ Quickstart (prebuilt binary)

Grab the latest release tarball, extract, and drop the binary somewhere on
your `$PATH`:

```bash
# Download the latest x86_64-linux-gnu release
curl -L -o sandbox.tar.gz \
  https://github.com/tcreswick/sandbox-manager/releases/latest/download/sandbox-1.0.0-x86_64-unknown-linux-gnu.tar.gz

# (optional) verify the checksum
curl -LO https://github.com/tcreswick/sandbox-manager/releases/latest/download/sha256sums.txt
sha256sum -c sha256sums.txt --ignore-missing

# Extract and install
tar -xzf sandbox.tar.gz
sudo install -m 0755 sandbox /usr/local/bin/sandbox

# Verify
sandbox --help
```

Then create your first sandbox:

```bash
sandbox create debian:trixie work
sandbox shell work
```

> **Note — Podman is required.** Sandbox Manager is a thin wrapper around
> **rootless [Podman](https://podman.io/)** (≥ 4.0). Install it from your
> distro's package manager (`apt install podman`, `dnf install podman`,
> `pacman -S podman`, …) and make sure rootless support is configured —
> i.e. you have entries in `/etc/subuid` and `/etc/subgid` for your user.
> Most modern distros set this up automatically when Podman is installed.
>
> The prebuilt binary is dynamically linked against glibc and will run on
> any reasonably recent glibc-based Linux distribution. For musl systems
> (e.g. Alpine) or other architectures, build from source — see
> [Build & install](#-build--install) below.

---

## 🚀 Features

- **Rootless isolation** — uses Podman with `--userns=keep-id`; your host
  UID maps to the same UID inside the container, so files on shared
  volumes have sensible ownership.
- **GUI-aware** — X11 sockets, Wayland sockets, `XDG_RUNTIME_DIR`, and
  `/dev/dri` are wired up by default. GUI apps inside sandboxes Just Work.
- **Per-distro fix-up scripts** — fetched once from this repo into your
  config dir, then user-editable. UTF-8 locale, sudo, user provisioning,
  `/etc/hosts`, `/tmp/runtime-user` all handled.
- **Snapshot / restore** — `podman commit` wrapped as a one-liner.
- **Bring-your-own image** — works with any image (`ubuntu:latest`,
  `debian:trixie`, `archlinux:latest`, `alpine:latest`, `fedora:latest`,
  derived images you've built yourself, etc.). Fix-up scripts handle the
  rest at create-time.
- **Dry-run mode** — `--dry-run` prints every podman / filesystem command
  it *would* run, without touching the system. Handy for debugging or
  understanding what the tool is doing.

## 🛠️ Requirements

- **Linux** (tested on rootless Podman setups; not designed for macOS/WSL).
- **[Podman](https://podman.io/)** ≥ 4.0 with rootless support configured
  (`/etc/subuid` and `/etc/subgid` entries for your user).
- **Rust toolchain** (only for building from source) — `rustc` 1.75+ or
  any 2024-edition-capable compiler. Install via [rustup](https://rustup.rs/).
- **Network access** on first sandbox creation, so the fix-up scripts can
  be fetched. After that, sandboxes can be created offline.

## 📦 Build & install

Clone and build with cargo:

```bash
git clone https://github.com/tcreswick/sandbox-manager.git
cd sandbox-manager/sandbox
cargo build --release
```

The binary lands at `target/release/sandbox`. Either run it from there, or
install it onto your `$PATH`:

```bash
# install to ~/.cargo/bin (rustup default), available immediately if that's on $PATH
cargo install --path .

# or copy the binary somewhere on PATH manually
sudo cp target/release/sandbox /usr/local/bin/
```

Verify the install:

```bash
sandbox --help
```

### Updating

```bash
cd sandbox-manager && git pull
cd sandbox && cargo install --path . --force
```

Fix-up scripts in `~/.config/sandbox/fixups/` are **not** overwritten on
update — see the [Fix-up scripts](#-fix-up-scripts) section for how to
refresh them.

## 📖 Usage

### Quick start

```bash
sandbox create debian:trixie work     # create a container called 'work'
sandbox shell work                    # open a login shell, lands in /home/$USER
sandbox exec work apt list --installed
sandbox stop work                     # stop without removing
sandbox start work                    # resume later
sandbox rm work                       # remove the container (home dir kept)
sandbox rm --purge work               # also delete the persistent home dir
```

### Command reference

| Command                                 | Description                                    |
|-----------------------------------------|------------------------------------------------|
| `sandbox create <image> <name>`         | Start a new sandbox from `<image>`             |
| `sandbox shell <name>`                  | Open an interactive `bash -l` login shell      |
| `sandbox shell --root <name>`           | Open a root shell (no `sudo` needed)           |
| `sandbox exec <name> <cmd…>`            | Run a one-off command as your user             |
| `sandbox exec --root <name> <cmd…>`     | Run a one-off command as root                  |
| `sandbox stop <name>`                   | Stop a running sandbox                         |
| `sandbox start <name>`                  | Resume a stopped sandbox                       |
| `sandbox rm <name>`                     | Remove the container (keeps the home dir)      |
| `sandbox rm --purge <name>`             | Remove the container *and* the home dir        |
| `sandbox list`                          | List all sandboxes                             |
| `sandbox snapshot <name> <tag>`         | `podman commit` the writable layer as `<name>:<tag>` |
| `sandbox restore <name> <tag>`          | Recreate `<name>` from a snapshot tag          |

### Global flags

| Flag           | Effect                                                              |
|----------------|---------------------------------------------------------------------|
| `-v, --verbose` | Print every podman/filesystem command before running it             |
| `--dry-run`     | Print what *would* be done without executing it (safe to run anywhere) |

### `create` flags

| Flag                  | Effect                                                       |
|-----------------------|--------------------------------------------------------------|
| `--no-gui`            | Omit X11/Wayland socket bind mounts                          |
| `--no-gpu`            | Omit `/dev/dri` passthrough                                  |
| `--no-network-host`   | Use bridged networking instead of `--network=host`           |
| `--home <PATH>`       | Override the default home directory bind mount               |
| `--work <PATH>`       | Additionally bind-mount `<PATH>` at `/work` inside           |
| `--fixup <SCRIPT>`    | Force a specific fix-up script, bypassing `mapping.conf`     |

### What happens during `sandbox create`?

1. Ensure `~/sandboxes/<name>/` exists on the host (or `--home`'s value).
2. `podman run -d --userns=keep-id …` with X11/Wayland/GPU bind-mounts and
   `LANG` / `LC_ALL` / `LANGUAGE` passed through from your shell environment.
3. Detect the guest's `PRETTY_NAME` from `/etc/os-release`.
4. Look up the matching fix-up script in `~/.config/sandbox/fixups/mapping.conf`,
   fetching it from GitHub on first use.
5. Pipe that script into `podman exec -i --user root <name> bash -s` with
   `SANDBOX_USER` / `SANDBOX_UID` / `SANDBOX_GID` / `SANDBOX_NAME` env vars.
6. Print a green success banner with quick-start commands.

### Persistent home directories

By default each sandbox gets `~/sandboxes/<name>/` bind-mounted at `/home`
inside the container. Your user's home (`/home/$USER`) is created on first
run from `/etc/skel`. This means:

- Files you create in `~` inside the sandbox survive `sandbox rm`.
- You can `sandbox rm` and `sandbox create` again with the same name to
  get a fresh container against the same persistent home.
- Use `sandbox rm --purge <name>` to delete the home dir too.
- Use `--home <PATH>` on `create` to point at a different host directory.

## 🧩 Fix-up scripts

When `sandbox create` starts a container, it runs a short shell script
inside as `root` to:

- create a user matching the host (resolving UID/GID collisions with any
  preinstalled user like Ubuntu's `ubuntu` at UID 1000),
- materialise the home directory from `/etc/skel`,
- add a `127.0.1.1 <name>` entry to `/etc/hosts`,
- prepare `/tmp/runtime-user` for the user (Wayland, etc.),
- write a passwordless `/etc/sudoers.d/<user>` entry,
- install a sensible default package set (sudo, curl, ca-certificates,
  build-essential on Debian, locale generation, etc.).

### Where they live

Scripts live on GitHub at
[`fixups/`](https://github.com/tcreswick/sandbox-manager/tree/main/fixups)
and are **fetched once on demand** into `~/.config/sandbox/fixups/`. After
the first fetch the local copy is canonical and `sandbox` will not
overwrite it — edit freely.

### Distro selection

- Sandbox reads `PRETTY_NAME` from `/etc/os-release` inside the freshly
  started container.
- It matches the value against the regexes in
  `~/.config/sandbox/fixups/mapping.conf`.
- Each line is `<regex>  <script-filename>` (the **last** whitespace-
  separated token is the filename; everything before it is the regex, so
  regexes may contain literal spaces).
- First match wins. The trailing `.*` line is the catch-all.

Built-in scripts: `debian.sh`, `ubuntu.sh`, `arch.sh`, `fedora.sh`,
`alpine.sh`, and `default.sh` as fallback.

### Customising

| Goal | How |
|---|---|
| Edit a script             | Open `~/.config/sandbox/fixups/<script>.sh` |
| Add a new distro          | Drop a new script in the cache dir; add a regex line in `mapping.conf` *above* `.*` |
| Refresh from upstream     | `rm` the file (or the whole dir) and re-run `sandbox create` |
| Force a specific script   | `sandbox create --fixup myscript.sh …` |
| Use a fork as the source  | `export SANDBOX_FIXUPS_URL=https://raw.githubusercontent.com/<you>/sandbox-manager/main/fixups/` |

See [`fixups/README.md`](fixups/README.md) for the full script contract
(input env vars, required behaviour, idempotency requirements).

## 🌐 Environment variables

| Variable                | Purpose                                                  |
|-------------------------|----------------------------------------------------------|
| `SANDBOX_FIXUPS_URL`    | Base URL for fetching fix-up scripts (override default)  |
| `LANG` / `LC_ALL` / `LANGUAGE` | Passed through to every new container so locale matches the host |
| `DISPLAY` / `WAYLAND_DISPLAY` / `XDG_RUNTIME_DIR` / `XAUTHORITY` | Picked up automatically for GUI passthrough (unless `--no-gui`) |
| `NO_COLOR`              | Disable ANSI colours in terminal output                  |

## 🛡️ Security

Sandbox Manager uses Podman's **rootless** container model: even if a
process inside a sandbox escapes the container, it ends up confined to
the calling user's privileges on the host. Combined with user namespaces
(`--userns=keep-id`), file ownership inside the sandbox mirrors the host
without any setuid trickery.

That said, this is a **dev sandbox**, not a hardened security boundary.
By default sandboxes run with `--network=host`, the user's X11/Wayland
sockets are exposed (so GUI apps can talk to the host display server),
and `/dev/dri` is passed through. If you need stronger isolation, pass
`--no-network-host --no-gui --no-gpu` on `create`.

## 🧪 Development

```bash
cd sandbox
cargo build              # debug build
cargo test               # run unit tests (covers fixup mapping parser)
cargo run -- --help      # run without installing
cargo run -- --dry-run create ubuntu:latest test   # exercise create logic offline
```

The repo layout:

```
.
├── README.md             — you are here
├── fixups/               — per-distro fix-up shell scripts (fetched on demand)
│   ├── README.md           script contract
│   ├── mapping.conf        regex → script (first match wins)
│   ├── debian.sh / ubuntu.sh / arch.sh / fedora.sh / alpine.sh / default.sh
├── sandbox/              — Rust CLI crate
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs         CLI, subcommands, podman invocation
│       ├── fixups.rs       fetch/cache/parse/select fix-up scripts
│       └── term.rs         ANSI/TTY helpers
└── sandbox-tool-spec.md  — design notes
```

### Releasing

Releases are produced by `.github/workflows/release.yml`, which builds a
stripped `x86_64-unknown-linux-gnu` binary on `ubuntu-22.04` (glibc ~2.35
baseline) whenever a `v*` tag is pushed.

To cut a release:

```bash
# 1. Bump the crate version
$EDITOR sandbox/Cargo.toml          # update version = "X.Y.Z"
(cd sandbox && cargo generate-lockfile)
git add sandbox/Cargo.toml sandbox/Cargo.lock
git commit -m "Release vX.Y.Z"
git push origin main

# 2. Tag and push
git tag vX.Y.Z
git push origin vX.Y.Z
```

The workflow then:

1. Builds `cargo build --release --locked --target x86_64-unknown-linux-gnu`.
2. Strips the binary.
3. Stages `sandbox-X.Y.Z-x86_64-unknown-linux-gnu/{sandbox,README.md,LICENSE}`
   (fix-up scripts are **not** bundled — they're fetched at runtime).
4. Produces `sandbox-X.Y.Z-x86_64-unknown-linux-gnu.tar.gz` and
   `sha256sums.txt`.
5. Publishes a GitHub release with both files attached and auto-generated
   release notes.

You can also trigger the workflow manually via **Actions → release → Run
workflow** for a dry run; the upload step is gated on a tag ref, so a
manual dispatch builds and packages without publishing anything.

The produced binary is **dynamically linked against glibc**. For musl /
Alpine, rebuild against `x86_64-unknown-linux-musl` from source.

## 📄 License

[MIT](LICENSE) © Luumo Factory Limited
