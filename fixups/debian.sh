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

# Idempotent create. We deliberately do NOT use 'useradd -m' here so we can
# manage the home directory ourselves below — 'useradd -m' can fail silently
# in some bind-mount / userns scenarios.
getent group  "${SANDBOX_USER}" >/dev/null || groupadd -g "${SANDBOX_GID}" "${SANDBOX_USER}"
getent passwd "${SANDBOX_USER}" >/dev/null || useradd  -u "${SANDBOX_UID}" -g "${SANDBOX_GID}" -M -s /bin/bash -d "/home/${SANDBOX_USER}" "${SANDBOX_USER}"

# Ensure the home directory exists, is owned by the user, and is populated
# from /etc/skel on first creation.
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
# Everything below is a convenience baseline that most sandboxes will want.
# It is safe to comment out any or all of these lines if you prefer a leaner
# container; the user/group/hosts/runtime-user setup above is what actually
# makes the sandbox usable.
# --------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

# Capture the host locale *before* we override $LANG below, so the debconf
# preseed further down generates the right locale.
host_locale="${LANG:-C.UTF-8}"

# Use C.UTF-8 *inside this script only* so package postinsts (perl etc.)
# don't warn about $LANG (e.g. en_GB.UTF-8) not being generated yet. The
# container's persistent env still has the host LANG; once the 'locales'
# package is installed below, that locale becomes available for the user's
# subsequent sessions.
export LANG=C.UTF-8
unset LC_ALL LANGUAGE

# Prevent package postinsts from trying to start services (systemctl/initctl/
# invoke-rc.d will all see exit 101 and skip). Without this, packages pulled
# in by 'tasksel install standard' often abort with 'apt-get failed (100)'
# because there is no init system inside the container.
cat > /usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x /usr/sbin/policy-rc.d

apt-get update

# Preseed locale selection so the 'locales' package postinst generates the
# host's locale non-interactively (no debconf prompt). Uses $host_locale
# captured above (we deliberately overrode $LANG to C.UTF-8 for the install).
target_locale="${host_locale}"
charset="${target_locale##*.}"
if [ "${charset}" = "${target_locale}" ]; then
    charset="UTF-8"
fi
apt-get install -y --no-install-recommends debconf
echo "locales locales/locales_to_be_generated multiselect ${target_locale} ${charset}" | debconf-set-selections
echo "locales locales/default_environment_locale select ${target_locale}" | debconf-set-selections

apt-get install -y --no-install-recommends \
    locales sudo curl ca-certificates build-essential tasksel

# 'standard' brings in the Debian/Ubuntu "standard system utilities" task
# (less, bash-completion, etc). Drop this line for a more minimal box.
tasksel install standard
apt-get upgrade -y
apt-get clean
rm -rf /var/lib/apt/lists/*

# Remove the service-start block so any *future* in-container apt installs
# the user runs interactively behave normally.
rm -f /usr/sbin/policy-rc.d
