#!/usr/bin/env bash
#
# docs/record-demo.sh — record the README demo GIF on a real host.
#
# What it does:
#   1. Verifies prerequisites (vhs, ffmpeg, podman, sandbox).
#   2. Pre-pulls debian:trixie so the recording doesn't capture the image
#      download (which is long, network-dependent, and visually boring).
#   3. Removes any pre-existing sandbox named "demo" so the recording
#      starts from a clean slate.
#   4. Drives vhs against docs/demo.tape, producing docs/demo.gif.
#   5. Cleans up the "demo" sandbox afterwards (defence in depth — the
#      tape file already does this, but if the tape errors out mid-run
#      we still want a tidy host).
#
# Run from the repo root:
#     ./docs/record-demo.sh
#
# Requirements on the host:
#   - rootless podman set up for your user (subuid/subgid entries,
#     newuidmap/newgidmap with the setuid bit, etc.).
#   - vhs        https://github.com/charmbracelet/vhs
#   - ffmpeg     (vhs runtime dep)
#   - ttyd       (vhs runtime dep; vhs will tell you if it's missing)
#   - sandbox    the binary built from this repo, on $PATH
#                (cargo install --path sandbox  -- or symlink target/release/sandbox)
#
# It is safe to re-run this script; each run regenerates docs/demo.gif
# in place.

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

tape="docs/demo.tape"
output="docs/demo.gif"
sandbox_name="demo"
image="docker.io/library/debian:trixie"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX \033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 1. Prereq checks ----------
need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1  ($2)"
}

log "Checking prerequisites"
need vhs     "install from https://github.com/charmbracelet/vhs"
need ffmpeg  "apt install ffmpeg  /  brew install ffmpeg"
need podman  "install rootless podman; see README"
need sandbox "build this repo and put 'sandbox' on PATH (cargo install --path sandbox)"

[[ -f "$tape" ]] || die "tape file not found at $tape"

sandbox_version="$(sandbox --version 2>/dev/null || true)"
log "Using $(command -v sandbox)  ($sandbox_version)"

# Sanity-check rootless podman actually works before we hand off to vhs.
# Running podman from inside a nested user namespace fails here, and we'd
# rather surface that now than during the recording.
if ! podman info >/dev/null 2>&1; then
  die "podman info failed -- rootless podman is not usable on this host. \
Fix that first (subuid/subgid + newuidmap caps), then re-run."
fi

# ---------- 2. Pre-pull the image ----------
log "Pre-pulling $image (so the recording doesn't capture the download)"
podman pull "$image" >/dev/null

# ---------- 3. Clean slate ----------
if sandbox list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$sandbox_name"; then
  warn "Existing sandbox '$sandbox_name' found -- removing it (with --purge)"
  sandbox rm --purge "$sandbox_name" >/dev/null 2>&1 || true
fi

# Belt-and-braces: nuke any stray container with that name too.
podman rm -f "$sandbox_name" >/dev/null 2>&1 || true

cleanup() {
  # Always try to tidy up, even on failure.
  sandbox rm --purge "$sandbox_name" >/dev/null 2>&1 || true
  podman rm -f       "$sandbox_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------- 4. Record ----------
log "Recording with vhs -> $output"
vhs "$tape"

[[ -s "$output" ]] || die "vhs finished but $output is missing or empty"
size_kb="$(du -k "$output" | cut -f1)"
log "Wrote $output (${size_kb} KB)"

# ---------- 5. Suggest next steps ----------
cat <<EOF

Done.

  Preview:   xdg-open $output   (or open it in your image viewer of choice)
  Commit:    git add $output
             git commit -m "docs: refresh demo GIF"
             git push

If the GIF looks wrong (clipped output, prompt mismatch, theme off, etc.),
edit docs/demo.tape and re-run this script. vhs is deterministic given the
same tape + sandbox version, so iteration is cheap.
EOF
