#!/bin/sh
# Sandbox fix-up script for Alpine (BusyBox).
# Uses addgroup/adduser (BusyBox) and avoids getent (not present).

set -e

: "${SANDBOX_USER:?SANDBOX_USER is required}"
: "${SANDBOX_UID:?SANDBOX_UID is required}"
: "${SANDBOX_GID:?SANDBOX_GID is required}"
: "${SANDBOX_NAME:?SANDBOX_NAME is required}"

echo "127.0.1.1 ${SANDBOX_NAME}" >> /etc/hosts

# Resolve UID/GID collisions
conflict_user=$(awk -F: -v u="${SANDBOX_UID}" '$3==u {print $1; exit}' /etc/passwd || true)
if [ -n "${conflict_user}" ] && [ "${conflict_user}" != "${SANDBOX_USER}" ]; then
    deluser "${conflict_user}" 2>/dev/null || true
fi
conflict_group=$(awk -F: -v g="${SANDBOX_GID}" '$3==g {print $1; exit}' /etc/group || true)
if [ -n "${conflict_group}" ] && [ "${conflict_group}" != "${SANDBOX_USER}" ]; then
    delgroup "${conflict_group}" 2>/dev/null || true
fi

# Idempotent create
if ! getent_group=$(awk -F: -v n="${SANDBOX_USER}" '$1==n {print; exit}' /etc/group) || [ -z "${getent_group}" ]; then
    addgroup -g "${SANDBOX_GID}" "${SANDBOX_USER}"
fi
if ! getent_passwd=$(awk -F: -v n="${SANDBOX_USER}" '$1==n {print; exit}' /etc/passwd) || [ -z "${getent_passwd}" ]; then
    adduser -D -u "${SANDBOX_UID}" -G "${SANDBOX_USER}" -s /bin/sh "${SANDBOX_USER}"
fi

mkdir -p /tmp/runtime-user
chown "${SANDBOX_USER}:${SANDBOX_USER}" /tmp/runtime-user
chmod 700 /tmp/runtime-user
