#!/usr/bin/env bash
# snapper-setup.sh – Configure Snapper and APT snapshot hooks.
#
# Runs inside the target chroot after Btrfs subvolumes are mounted.
# Requires:
#   - snapper package installed
#   - /.snapshots mounted on the @snapshots Btrfs subvolume

set -euo pipefail

# shellcheck source=/dev/null
[[ -f /tmp/env.sh ]] && source /tmp/env.sh

log() { echo "[snapper-setup] $*"; }
die() { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------------------
# Validate environment
# ---------------------------------------------------------------------------

command -v snapper &>/dev/null || die "snapper is not installed"

if ! findmnt -n -o FSTYPE / | grep -q btrfs; then
    die "Root filesystem is not Btrfs"
fi

# ---------------------------------------------------------------------------
# Create snapper config for root
# ---------------------------------------------------------------------------

if snapper -c root list &>/dev/null 2>&1; then
    log "Snapper config 'root' already exists – skipping creation"
else
    log "Creating snapper config for /"
    # /.snapshots must be owned by root and the @snapshots subvolume
    # must be mounted there before snapper create-config runs.
    snapper -c root create-config / \
        || die "snapper create-config / failed"
fi

# ---------------------------------------------------------------------------
# Tune the snapper configuration
# ---------------------------------------------------------------------------

SNAPPER_ROOT_CFG=/etc/snapper/configs/root

[[ -f "${SNAPPER_ROOT_CFG}" ]] || die "Snapper root config not found"

log "Applying snapshot retention policy..."

set_snapper_cfg() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "${SNAPPER_ROOT_CFG}"; then
        sed -i "s|^${key}=.*|${key}=\"${val}\"|" "${SNAPPER_ROOT_CFG}"
    else
        echo "${key}=\"${val}\"" >> "${SNAPPER_ROOT_CFG}"
    fi
}

set_snapper_cfg TIMELINE_CREATE         "yes"
set_snapper_cfg TIMELINE_CLEANUP        "yes"
set_snapper_cfg TIMELINE_MAX_HOURLY     "${SNAPPER_TIMELINE_MAX_HOURLY:-5}"
set_snapper_cfg TIMELINE_MAX_DAILY      "${SNAPPER_TIMELINE_MAX_DAILY:-7}"
set_snapper_cfg TIMELINE_MAX_WEEKLY     "0"
set_snapper_cfg TIMELINE_MAX_MONTHLY    "${SNAPPER_TIMELINE_MAX_MONTHLY:-0}"
set_snapper_cfg TIMELINE_MAX_YEARLY     "${SNAPPER_TIMELINE_MAX_YEARLY:-0}"
set_snapper_cfg NUMBER_CLEANUP          "yes"
set_snapper_cfg NUMBER_MAX_COUNT        "${SNAPPER_NUMBER_MAX_COUNT:-10}"
set_snapper_cfg NUMBER_MIN_AGE          "1800"
set_snapper_cfg EMPTY_PRE_POST_CLEANUP  "yes"
set_snapper_cfg EMPTY_PRE_POST_MIN_AGE  "1800"

log "Snapper config written to ${SNAPPER_ROOT_CFG}"

# ---------------------------------------------------------------------------
# APT integration – pre/post snapshot hooks
# ---------------------------------------------------------------------------

log "Installing APT snapshot hooks..."

cat > /etc/apt/apt.conf.d/80snapper <<'APT_HOOK'
# Snapper APT integration
# Creates a numbered snapshot before and after each dpkg run.

DPkg::Pre-Invoke {
    "if [ -x /usr/bin/snapper ] && snapper -c root list &>/dev/null 2>&1; then \
        /usr/bin/snapper --config root create \
            --cleanup-algorithm number \
            --print-number \
            --description 'pre-apt' \
            2>&1 | logger -t snapper-apt || true; \
    fi";
};

DPkg::Post-Invoke {
    "if [ -x /usr/bin/snapper ] && snapper -c root list &>/dev/null 2>&1; then \
        /usr/bin/snapper --config root create \
            --cleanup-algorithm number \
            --print-number \
            --description 'post-apt' \
            2>&1 | logger -t snapper-apt || true; \
    fi";
};
APT_HOOK

log "APT hooks written to /etc/apt/apt.conf.d/80snapper"

# ---------------------------------------------------------------------------
# Enable snapper systemd timers
# ---------------------------------------------------------------------------

log "Enabling snapper systemd timers..."
systemctl enable snapper-timeline.timer  2>/dev/null || true
systemctl enable snapper-cleanup.timer   2>/dev/null || true

# ---------------------------------------------------------------------------
# Initial snapshot – baseline of the freshly installed system
# ---------------------------------------------------------------------------

log "Creating initial system snapshot..."
snapper -c root create \
    --cleanup-algorithm number \
    --description "Fresh Debian 13 (Trixie) installation" \
    2>/dev/null || log "WARNING: Initial snapshot creation failed (may succeed on first boot)"

log "Snapper setup complete."
