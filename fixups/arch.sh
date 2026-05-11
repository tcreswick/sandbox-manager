#!/usr/bin/env bash
# Sandbox fix-up script for Arch Linux.
# Currently identical to debian.sh — shadow-utils tooling is the same.
# Kept as a separate file so distro-specific tweaks can land later
# (e.g. wheel group membership, pacman cache bind-mount, etc).

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
getent passwd "${SANDBOX_USER}" >/dev/null || useradd  -u "${SANDBOX_UID}" -g "${SANDBOX_GID}" -M -s /bin/bash -d "/home/${SANDBOX_USER}" "${SANDBOX_USER}"

# Ensure the home directory exists, is owned by the user, populated from /etc/skel.
user_home="/home/${SANDBOX_USER}"
if [ ! -d "${user_home}" ]; then
    mkdir -p "${user_home}"
    if [ -d /etc/skel ]; then
        cp -aT /etc/skel "${user_home}"
    fi
fi
chown -R "${SANDBOX_USER}:${SANDBOX_USER}" "${user_home}"
chmod 750 "${user_home}"

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
# Convenience baseline — safe to comment out if you want a leaner container.
# --------------------------------------------------------------------------
pacman -Sy --noconfirm --needed sudo curl ca-certificates
