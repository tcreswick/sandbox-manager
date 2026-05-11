#!/usr/bin/env bash
# Sandbox fix-up fallback for unrecognised distros.
# Assumes glibc + shadow-utils (the lowest-common-denominator on Linux).
# Edit freely if you need behaviour different from the Debian/Fedora default.

set -e

: "${SANDBOX_USER:?SANDBOX_USER is required}"
: "${SANDBOX_UID:?SANDBOX_UID is required}"
: "${SANDBOX_GID:?SANDBOX_GID is required}"
: "${SANDBOX_NAME:?SANDBOX_NAME is required}"

echo "127.0.1.1 ${SANDBOX_NAME}" >> /etc/hosts

conflict_user=$(getent passwd "${SANDBOX_UID}" | cut -d: -f1 || true)
if [ -n "${conflict_user}" ] && [ "${conflict_user}" != "${SANDBOX_USER}" ]; then
    userdel "${conflict_user}" 2>/dev/null || true
fi
conflict_group=$(getent group "${SANDBOX_GID}" | cut -d: -f1 || true)
if [ -n "${conflict_group}" ] && [ "${conflict_group}" != "${SANDBOX_USER}" ]; then
    groupdel "${conflict_group}" 2>/dev/null || true
fi

getent group  "${SANDBOX_USER}" >/dev/null || groupadd -g "${SANDBOX_GID}" "${SANDBOX_USER}"
getent passwd "${SANDBOX_USER}" >/dev/null || useradd  -u "${SANDBOX_UID}" -g "${SANDBOX_GID}" -m -s /bin/bash "${SANDBOX_USER}"

# Passwordless sudo for the sandbox user (effective once sudo is installed).
mkdir -p /etc/sudoers.d
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "${SANDBOX_USER}" > "/etc/sudoers.d/${SANDBOX_USER}"
chmod 440 "/etc/sudoers.d/${SANDBOX_USER}"

mkdir -p /tmp/runtime-user
chown "${SANDBOX_USER}:${SANDBOX_USER}" /tmp/runtime-user
chmod 700 /tmp/runtime-user

# Default UTF-8 locale for login shells.
mkdir -p /etc/profile.d
cat > /etc/profile.d/sandbox-locale.sh <<'EOF'
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
EOF
chmod 644 /etc/profile.d/sandbox-locale.sh

# --------------------------------------------------------------------------
# Sensible default packages
#
# This fallback script doesn't know the distro's package manager. Detect the
# common ones and install sudo + curl + ca-certificates where possible.
# Safe to comment out, or replace with a distro-specific block.
# --------------------------------------------------------------------------
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update && apt-get install -y --no-install-recommends sudo curl ca-certificates
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y sudo curl ca-certificates
elif command -v microdnf >/dev/null 2>&1; then
    microdnf install -y sudo curl ca-certificates
elif command -v yum >/dev/null 2>&1; then
    yum install -y sudo curl ca-certificates
elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed sudo curl ca-certificates
elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache sudo curl ca-certificates
elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install sudo curl ca-certificates
fi
