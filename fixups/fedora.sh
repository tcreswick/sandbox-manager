#!/usr/bin/env bash
# Sandbox fix-up script for Fedora / RHEL / Rocky / AlmaLinux / CentOS.
# Same shadow-utils tooling as Debian; kept separate for future divergence.

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

# --------------------------------------------------------------------------
# Sensible default packages
#
# Convenience baseline — safe to comment out if you want a leaner container.
# 'dnf' on minimal images may not be present; fall back to 'microdnf' / 'yum'.
# --------------------------------------------------------------------------
if command -v dnf >/dev/null 2>&1; then
    dnf install -y sudo curl ca-certificates
elif command -v microdnf >/dev/null 2>&1; then
    microdnf install -y sudo curl ca-certificates
elif command -v yum >/dev/null 2>&1; then
    yum install -y sudo curl ca-certificates
fi
