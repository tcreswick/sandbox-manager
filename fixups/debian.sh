#!/usr/bin/env bash
# Sandbox fix-up script for Debian / Ubuntu family.
#
# Contract (see fixups/README.md):
#   Inputs:  $SANDBOX_USER  $SANDBOX_UID  $SANDBOX_GID  $SANDBOX_NAME
#   Effect:  ensure host user exists inside container, /etc/hosts entry,
#            /tmp/runtime-user prepared.
#   Must be idempotent.

set -e

: "${SANDBOX_USER:?SANDBOX_USER is required}"
: "${SANDBOX_UID:?SANDBOX_UID is required}"
: "${SANDBOX_GID:?SANDBOX_GID is required}"
: "${SANDBOX_NAME:?SANDBOX_NAME is required}"

echo "127.0.1.1 ${SANDBOX_NAME}" >> /etc/hosts

# Resolve UID/GID collisions from base images (e.g. ubuntu's preinstalled 'ubuntu' user)
conflict_user=$(getent passwd "${SANDBOX_UID}" | cut -d: -f1 || true)
if [ -n "${conflict_user}" ] && [ "${conflict_user}" != "${SANDBOX_USER}" ]; then
    userdel "${conflict_user}" 2>/dev/null || true
fi
conflict_group=$(getent group "${SANDBOX_GID}" | cut -d: -f1 || true)
if [ -n "${conflict_group}" ] && [ "${conflict_group}" != "${SANDBOX_USER}" ]; then
    groupdel "${conflict_group}" 2>/dev/null || true
fi

# Idempotent create
getent group  "${SANDBOX_USER}" >/dev/null || groupadd -g "${SANDBOX_GID}" "${SANDBOX_USER}"
getent passwd "${SANDBOX_USER}" >/dev/null || useradd  -u "${SANDBOX_UID}" -g "${SANDBOX_GID}" -m -s /bin/bash "${SANDBOX_USER}"

# Passwordless sudo for the sandbox user (effective once sudo is installed).
mkdir -p /etc/sudoers.d
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "${SANDBOX_USER}" > "/etc/sudoers.d/${SANDBOX_USER}"
chmod 440 "/etc/sudoers.d/${SANDBOX_USER}"

mkdir -p /tmp/runtime-user
chown "${SANDBOX_USER}:${SANDBOX_USER}" /tmp/runtime-user
chmod 700 /tmp/runtime-user

# --------------------------------------------------------------------------
# Sensible default packages
#
# Everything below is a convenience baseline that most sandboxes will want.
# It is safe to comment out any or all of these lines if you prefer a leaner
# container; the user/group/hosts/runtime-user setup above is what actually
# makes the sandbox usable.
# --------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    sudo curl ca-certificates build-essential tasksel
# 'standard' brings in the Debian/Ubuntu "standard system utilities" task
# (less, bash-completion, locales, etc). Drop this line for a more minimal box.
tasksel install standard
apt-get upgrade -y
apt-get clean
rm -rf /var/lib/apt/lists/*
