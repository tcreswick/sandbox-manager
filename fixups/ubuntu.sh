#!/usr/bin/env bash
# Sandbox fix-up script for Ubuntu.
#
# Differs from debian.sh in that we don't run `tasksel install standard` —
# Ubuntu's 'standard' task pulls in packages (snapd, ubuntu-advantage-tools,
# popularity-contest, update-notifier, etc.) whose postinsts misbehave in a
# container even with policy-rc.d in place. Instead we install an explicit,
# curated list of the genuinely useful "standard system utilities".

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
# Convenience baseline — safe to comment out any/all of these lines if you
# prefer a leaner container.
# --------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

# Capture the host locale before we override $LANG below.
host_locale="${LANG:-C.UTF-8}"

# Use C.UTF-8 *inside this script only* so package postinsts (perl etc.)
# don't warn about $LANG not being generated yet. The container's
# persistent env still has the host LANG for the user's sessions.
export LANG=C.UTF-8
unset LC_ALL LANGUAGE

# Prevent package postinsts from trying to start services in a container.
cat > /usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x /usr/sbin/policy-rc.d

apt-get update

# Preseed locale generation so the 'locales' postinst is non-interactive.
# Use the captured host_locale, not the overridden $LANG.
target_locale="${host_locale}"
charset="${target_locale##*.}"
if [ "${charset}" = "${target_locale}" ]; then
    charset="UTF-8"
fi
apt-get install -y --no-install-recommends debconf
echo "locales locales/locales_to_be_generated multiselect ${target_locale} ${charset}" | debconf-set-selections
echo "locales locales/default_environment_locale select ${target_locale}" | debconf-set-selections

# Curated equivalent of `tasksel install standard`, minus the bits that
# don't belong in a container (snapd, ubuntu-advantage-tools, popularity-
# contest, update-notifier, unattended-upgrades, etc.).
apt-get install -y --no-install-recommends \
    locales sudo curl ca-certificates build-essential \
    bash-completion less vim-tiny nano \
    man-db file tree htop jq \
    procps iproute2 iputils-ping dnsutils hostname

apt-get upgrade -y
apt-get clean
rm -rf /var/lib/apt/lists/*

# Restore default service-start behaviour for the user's own future installs.
rm -f /usr/sbin/policy-rc.d
