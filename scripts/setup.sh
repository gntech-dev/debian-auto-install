#!/usr/bin/env bash
# setup.sh – Main post-install orchestrator.
#
# Called by the Debian installer's preseed late_command.  Runs in the
# *installer* environment (not inside the target chroot).
#
# Environment variables (all optional – defaults are in config.env):
#   SCRIPTS_URL   – Base URL for all scripts (no trailing slash)
#   SSH_KEYS_URL  – URL returning SSH public keys
#   STATIC_IP     – Static IP for the installed system (empty = DHCP)
#   GATEWAY       – Default gateway (required when STATIC_IP is set)
#   DNS_SERVERS   – Space-separated DNS server list
#   HOSTNAME      – System hostname
#   DOMAIN        – DNS domain / search domain
#   NETWORK_INTERFACE – Primary NIC name
#   TIMEZONE      – Timezone (e.g. "UTC", "Europe/Berlin")

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

SCRIPTS_URL="${SCRIPTS_URL:-https://raw.githubusercontent.com/gntech-dev/debian-auto-install/main/scripts}"
TARGET="${TARGET:-/target}"
LOG_FILE="${TARGET}/var/log/post-install.log"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }
die()  { log "ERROR: $*"; exit 1; }
info() { log "INFO:  $*"; }
warn() { log "WARN:  $*"; }

mkdir -p "$(dirname "${LOG_FILE}")"
info "=== debian-auto-install post-install started ==="
info "SCRIPTS_URL=${SCRIPTS_URL}"

# ---------------------------------------------------------------------------
# Helper: download a script into the target's /tmp
# ---------------------------------------------------------------------------

fetch_script() {
    local name="$1"
    local dest="${TARGET}/tmp/${name}"
    info "Fetching ${name}..."
    wget -q --timeout=30 --tries=3 -O "${dest}" "${SCRIPTS_URL}/${name}" \
        || die "Failed to download ${SCRIPTS_URL}/${name}"
    chmod +x "${dest}"
}

# ---------------------------------------------------------------------------
# Step 0 – Discover mount topology before we touch anything
# ---------------------------------------------------------------------------

BTRFS_DEV="$(findmnt -n -o SOURCE "${TARGET}" 2>/dev/null)" \
    || die "Cannot determine root device of ${TARGET}"
BOOT_DEV="$(findmnt -n -o SOURCE "${TARGET}/boot" 2>/dev/null || true)"
EFI_DEV="$(findmnt -n -o SOURCE "${TARGET}/boot/efi" 2>/dev/null || true)"

info "Root (btrfs) device : ${BTRFS_DEV}"
info "Boot device         : ${BOOT_DEV:-none}"
info "EFI device          : ${EFI_DEV:-none}"

# ---------------------------------------------------------------------------
# Step 1 – Download scripts into the target's /tmp
# ---------------------------------------------------------------------------

mkdir -p "${TARGET}/tmp"

for script in config.env btrfs-subvols.sh post-install.sh \
              snapper-setup.sh ssh-setup.sh network-setup.sh; do
    # config.env lives one level up relative to the scripts directory
    if [[ "${script}" == "config.env" ]]; then
        wget -q --timeout=30 --tries=3 \
             -O "${TARGET}/tmp/config.env" \
             "${SCRIPTS_URL}/../config.env" 2>/dev/null \
             || warn "config.env not found at ${SCRIPTS_URL}/../config.env – using defaults"
    else
        fetch_script "${script}"
    fi
done

# ---------------------------------------------------------------------------
# Step 2 – Run Btrfs subvolume setup inside the target chroot
# ---------------------------------------------------------------------------
# /proc, /sys and /dev are already bind-mounted by the installer; btrfs-progs
# is installed (listed in pkgsel/include in preseed.cfg).

info "Setting up Btrfs subvolumes..."
chroot "${TARGET}" bash /tmp/btrfs-subvols.sh 2>&1 | tee -a "${LOG_FILE}" \
    || die "btrfs-subvols.sh failed"

# ---------------------------------------------------------------------------
# Step 3 – Remount /target with the new subvolume layout
# ---------------------------------------------------------------------------
# After btrfs-subvols.sh the target's fstab already references subvol=@, but
# /target itself is still mounted on the top-level Btrfs subvolume.  Remount
# everything so that subsequent in-chroot operations run against the @ tree.

info "Remounting /target with Btrfs subvolumes..."

# Tear down virtual / nested mounts (ignore errors for mounts that may not exist)
umount "${TARGET}/dev/pts"                           2>/dev/null || true
umount "${TARGET}/dev"                               2>/dev/null || true
umount "${TARGET}/sys/firmware/efi/efivars"          2>/dev/null || true
umount "${TARGET}/sys"                               2>/dev/null || true
umount "${TARGET}/proc"                              2>/dev/null || true
[[ -n "${EFI_DEV}" ]]  && umount "${TARGET}/boot/efi" 2>/dev/null || true
[[ -n "${BOOT_DEV}" ]] && umount "${TARGET}/boot"     2>/dev/null || true
umount "${TARGET}" || die "Cannot unmount ${TARGET}"

# Re-mount subvolumes
mount -t btrfs -o "${BTRFS_OPTS:-defaults,compress=zstd:3,noatime,space_cache=v2},subvol=@" \
      "${BTRFS_DEV}" "${TARGET}"

mkdir -p "${TARGET}"/{home,.snapshots,var/log,boot,proc,sys,dev,run,tmp}

mount -t btrfs -o "${BTRFS_OPTS:-defaults,compress=zstd:3,noatime,space_cache=v2},subvol=@home" \
      "${BTRFS_DEV}" "${TARGET}/home"
mount -t btrfs -o "${BTRFS_OPTS:-defaults,compress=zstd:3,noatime,space_cache=v2},subvol=@snapshots" \
      "${BTRFS_DEV}" "${TARGET}/.snapshots"
mount -t btrfs -o "${BTRFS_OPTS:-defaults,compress=zstd:3,noatime,space_cache=v2},subvol=@var_log" \
      "${BTRFS_DEV}" "${TARGET}/var/log"

if [[ -n "${BOOT_DEV}" ]]; then
    mount "${BOOT_DEV}" "${TARGET}/boot"
fi
if [[ -n "${EFI_DEV}" ]]; then
    mkdir -p "${TARGET}/boot/efi"
    mount "${EFI_DEV}" "${TARGET}/boot/efi"
fi

# Re-bind virtual filesystems
mount -t proc  proc   "${TARGET}/proc"
mount -t sysfs sysfs  "${TARGET}/sys"
mount --bind /dev     "${TARGET}/dev"
mount --bind /dev/pts "${TARGET}/dev/pts"
if [[ -d /sys/firmware/efi/efivars ]]; then
    mkdir -p "${TARGET}/sys/firmware/efi/efivars"
    mount --bind /sys/firmware/efi/efivars \
                 "${TARGET}/sys/firmware/efi/efivars"
fi

info "Subvolume mounts verified:"
findmnt --target "${TARGET}" --output TARGET,SOURCE,FSTYPE,OPTIONS \
    2>/dev/null | tee -a "${LOG_FILE}" || true

# ---------------------------------------------------------------------------
# Step 4 – Re-download scripts to /tmp in the newly mounted @ subvolume
# ---------------------------------------------------------------------------
# The rsync in btrfs-subvols.sh excluded /tmp, so we must re-fetch.

mkdir -p "${TARGET}/tmp"

for script in config.env btrfs-subvols.sh post-install.sh \
              snapper-setup.sh ssh-setup.sh network-setup.sh; do
    if [[ "${script}" == "config.env" ]]; then
        wget -q --timeout=30 --tries=3 \
             -O "${TARGET}/tmp/config.env" \
             "${SCRIPTS_URL}/../config.env" 2>/dev/null \
             || warn "config.env not available – using defaults"
    else
        fetch_script "${script}"
    fi
done

# ---------------------------------------------------------------------------
# Step 5 – Write a sourced env-file so post-install.sh has all variables
# ---------------------------------------------------------------------------

cat > "${TARGET}/tmp/env.sh" <<EOF
# Auto-generated by setup.sh – do not edit manually
export SCRIPTS_URL="${SCRIPTS_URL}"
export SSH_KEYS_URL="${SSH_KEYS_URL:-}"
export SSH_KEY_USERS="${SSH_KEY_USERS:-root,admin}"
export STATIC_IP="${STATIC_IP:-}"
export NETMASK="${NETMASK:-255.255.255.0}"
export PREFIX_LENGTH="${PREFIX_LENGTH:-24}"
export GATEWAY="${GATEWAY:-}"
export DNS_SERVERS="${DNS_SERVERS:-8.8.8.8 8.8.4.4}"
export DNS_SEARCH="${DNS_SEARCH:-local}"
export HOSTNAME="${HOSTNAME:-debian-server}"
export DOMAIN="${DOMAIN:-local}"
export NETWORK_INTERFACE="${NETWORK_INTERFACE:-eth0}"
export TIMEZONE="${TIMEZONE:-UTC}"
export BTRFS_OPTS="${BTRFS_OPTS:-defaults,compress=zstd:3,noatime,space_cache=v2}"
export SNAPPER_TIMELINE_MAX_HOURLY="${SNAPPER_TIMELINE_MAX_HOURLY:-5}"
export SNAPPER_TIMELINE_MAX_DAILY="${SNAPPER_TIMELINE_MAX_DAILY:-7}"
export SNAPPER_TIMELINE_MAX_MONTHLY="${SNAPPER_TIMELINE_MAX_MONTHLY:-0}"
export SNAPPER_TIMELINE_MAX_YEARLY="${SNAPPER_TIMELINE_MAX_YEARLY:-0}"
export SNAPPER_NUMBER_MAX_COUNT="${SNAPPER_NUMBER_MAX_COUNT:-10}"
EOF

# ---------------------------------------------------------------------------
# Step 6 – Run post-install configuration inside the chroot
# ---------------------------------------------------------------------------

info "Running in-chroot post-install configuration..."
chroot "${TARGET}" bash -c \
    "source /tmp/env.sh && bash /tmp/post-install.sh" \
    2>&1 | tee -a "${LOG_FILE}" \
    || die "post-install.sh failed"

# ---------------------------------------------------------------------------
# Step 7 – Rebuild initramfs and GRUB with subvolume awareness
# ---------------------------------------------------------------------------

info "Rebuilding initramfs..."
chroot "${TARGET}" update-initramfs -u -k all 2>&1 | tee -a "${LOG_FILE}" || true

info "Updating GRUB..."
chroot "${TARGET}" update-grub 2>&1 | tee -a "${LOG_FILE}" \
    || die "update-grub failed"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

info "=== post-install completed successfully ==="
info "Log saved to ${LOG_FILE}"
