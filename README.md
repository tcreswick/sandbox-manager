# Sandbox Manager

Sandbox Manager is a tool designed to simplify the management of isolated agent sandboxes on Linux systems. By leveraging **Podman**, it provides a lightweight, daemonless, and secure way to run AI agents or untrusted code in strictly controlled environments.

## 🚀 Features

- **High Isolation**: Uses Podman containers to ensure agents are decoupled from your host system.
- **Easy Management**: Simplified CLI/API to create, start, stop, and delete sandboxes.
- **Linux Optimized**: Built specifically for Linux environments to take full advantage of containerization technologies.
- **Agent-Centric**: Designed with the lifecycle of an AI agent in mind (ephemeral environments, state persistence, etc.).

## 🛠️ Requirements

- Linux
- [Podman](https://podman.io/)

## 📋 Installation

*(Installation instructions coming soon)*

## 📖 Usage

*(Usage examples coming soon)*

## 🧩 Fix-up scripts

When `sandbox create` starts a container, it runs a short shell script as
`root` inside the container to:

- create a user/group matching the host user (resolving UID/GID collisions),
- add a `127.0.1.1 <name>` entry to `/etc/hosts`,
- set up `/tmp/runtime-user` for the user.

These scripts live on GitHub at
[`fixups/`](https://github.com/tcreswick/sandbox-manager/tree/main/fixups)
and are **fetched once on demand** into `~/.config/sandbox/fixups/`. After
the first fetch the local copy is canonical and `sandbox` will not
overwrite it — edit freely.

### Selection

- Sandbox reads `PRETTY_NAME` from `/etc/os-release` inside the freshly
  started container.
- It looks up the matching script in `~/.config/sandbox/fixups/mapping.conf`.
- Each line is `<regex>  <script-filename>` (the **last** whitespace-separated
  token is the filename; everything before it is the regex, so regexes may
  contain literal spaces). First match wins; the trailing `.*` line is the
  catch-all.

### Customising

- **Edit a script**: just open `~/.config/sandbox/fixups/<script>.sh`.
- **Add a distro**: drop a new script in the cache directory, then add a
  regex line in `mapping.conf` **above** the `.*` fallback.
- **Refresh from upstream**: delete the file (or the whole directory) and
  re-run `sandbox create` — missing files are re-fetched.
- **Force a specific script**: `sandbox create --fixup myscript.sh …`
  bypasses the regex matching.
- **Use a different source**: set `SANDBOX_FIXUPS_URL` to point at any
  raw URL prefix (e.g. a fork or a private mirror).

See [`fixups/README.md`](fixups/README.md) for the full script contract.

## 🛡️ Security

Sandbox Manager prioritizes security by utilizing Podman's rootless container capabilities, ensuring that even if an agent escapes the application layer, it remains constrained by standard Linux user permissions and container namespaces.

## 📄 License

[MIT](LICENSE)
