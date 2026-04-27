#!/usr/bin/env bash
# post-install.sh – In-chroot post-install driver.
#
# Runs inside the target chroot AFTER setup.sh has remounted /target with
# the correct Btrfs subvolumes.  Orchestrates the remaining configuration
# sub-scripts.

set -euo pipefail

# Source environment injected by setup.sh
# shellcheck source=/dev/null
[[ -f /tmp/env.sh ]] && source /tmp/env.sh

# Also source config.env for any variables not set by env.sh
# shellcheck source=/dev/null
[[ -f /tmp/config.env ]] && source /tmp/config.env

log()  { echo "[post-install] $*"; }
die()  { log "ERROR: $*"; exit 1; }

log "=== In-chroot post-install configuration ==="

# ---------------------------------------------------------------------------
# Package updates and additional installs
# ---------------------------------------------------------------------------

log "Updating APT package lists..."
DEBIAN_FRONTEND=noninteractive apt-get update -qq

log "Installing post-install packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    snapper \
    inotify-tools \
    resolvconf \
    2>&1 || log "WARNING: some packages could not be installed"

# ---------------------------------------------------------------------------
# Timezone
# ---------------------------------------------------------------------------

TZ="${TIMEZONE:-UTC}"
log "Setting timezone to ${TZ}..."
if [[ -f "/usr/share/zoneinfo/${TZ}" ]]; then
    ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
    dpkg-reconfigure -f noninteractive tzdata 2>&1 || true
else
    log "WARNING: Unknown timezone '${TZ}' – keeping UTC"
fi

# ---------------------------------------------------------------------------
# Sub-scripts
# ---------------------------------------------------------------------------

run_script() {
    local script="$1"
    local path="/tmp/${script}"
    if [[ -x "${path}" ]]; then
        log "--- Running ${script} ---"
        bash "${path}" 2>&1 || log "WARNING: ${script} returned non-zero exit code"
    else
        log "WARNING: ${script} not found or not executable – skipping"
    fi
}

run_script snapper-setup.sh
run_script ssh-setup.sh
run_script network-setup.sh

# ---------------------------------------------------------------------------
# Harden SSH daemon
# ---------------------------------------------------------------------------

log "Applying SSH hardening..."
SSHD_CFG=/etc/ssh/sshd_config

# Disable root password login; allow key-based root login
sed -i 's|^#\?PermitRootLogin.*|PermitRootLogin prohibit-password|' "${SSHD_CFG}"

# Disable empty passwords
sed -i 's|^#\?PermitEmptyPasswords.*|PermitEmptyPasswords no|' "${SSHD_CFG}"

# If an SSH key was provisioned, disable password authentication entirely
if [[ -s /root/.ssh/authorized_keys ]]; then
    sed -i 's|^#\?PasswordAuthentication.*|PasswordAuthentication no|' "${SSHD_CFG}"
    log "SSH password authentication disabled (key found)"
else
    sed -i 's|^#\?PasswordAuthentication.*|PasswordAuthentication yes|' "${SSHD_CFG}"
    log "SSH password authentication kept enabled (no key provisioned)"
fi

# Enable public-key authentication explicitly
sed -i 's|^#\?PubkeyAuthentication.*|PubkeyAuthentication yes|' "${SSHD_CFG}"

# Disable X11 forwarding
sed -i 's|^#\?X11Forwarding.*|X11Forwarding no|' "${SSHD_CFG}"

# Use a non-default port? – leave as 22 for production predictability
# but allow operator to override via SSH_PORT env var.
if [[ -n "${SSH_PORT:-}" ]]; then
    sed -i "s|^#\?Port.*|Port ${SSH_PORT}|" "${SSHD_CFG}"
fi

log "SSH daemon configuration applied."

# ---------------------------------------------------------------------------
# Enable unattended-upgrades for security patches
# ---------------------------------------------------------------------------

if command -v unattended-upgrades &>/dev/null; then
    log "Configuring unattended-upgrades..."
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
fi

# ---------------------------------------------------------------------------
# sudo configuration for admin user
# ---------------------------------------------------------------------------

if id -u admin &>/dev/null 2>&1; then
    log "Ensuring admin is in sudoers..."
    usermod -aG sudo admin 2>/dev/null || true
fi

log "=== In-chroot post-install configuration complete ==="
