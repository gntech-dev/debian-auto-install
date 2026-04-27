#!/usr/bin/env bash
# ssh-setup.sh – Provision SSH public keys.
#
# Runs inside the target chroot.
# Fetches public keys from SSH_KEYS_URL (e.g. https://github.com/user.keys)
# and writes them to authorized_keys for root and any users in SSH_KEY_USERS.

set -euo pipefail

# shellcheck source=/dev/null
[[ -f /tmp/env.sh ]] && source /tmp/env.sh

log() { echo "[ssh-setup] $*"; }
warn() { log "WARN: $*"; }

SSH_KEYS_URL="${SSH_KEYS_URL:-}"
SSH_KEY_USERS="${SSH_KEY_USERS:-root}"

if [[ -z "${SSH_KEYS_URL}" ]]; then
    log "SSH_KEYS_URL is empty – skipping SSH key provisioning"
    exit 0
fi

# ---------------------------------------------------------------------------
# Fetch public keys
# ---------------------------------------------------------------------------

log "Fetching SSH public keys from ${SSH_KEYS_URL}..."

KEYS_TMPFILE="$(mktemp /tmp/ssh-keys.XXXXXX)"
trap 'rm -f "${KEYS_TMPFILE}"' EXIT

if ! wget -q --timeout=30 --tries=3 -O "${KEYS_TMPFILE}" "${SSH_KEYS_URL}"; then
    warn "Failed to fetch keys from ${SSH_KEYS_URL}"
    exit 0
fi

KEY_COUNT="$(grep -c 'ssh-' "${KEYS_TMPFILE}" 2>/dev/null || echo 0)"
if [[ "${KEY_COUNT}" -eq 0 ]]; then
    warn "No SSH public keys found in response from ${SSH_KEYS_URL}"
    exit 0
fi
log "Found ${KEY_COUNT} key(s)"

# ---------------------------------------------------------------------------
# Install keys for each specified user
# ---------------------------------------------------------------------------

install_keys_for_user() {
    local user="$1"
    local home_dir

    if [[ "${user}" == "root" ]]; then
        home_dir="/root"
    else
        home_dir="$(getent passwd "${user}" 2>/dev/null | cut -d: -f6)" || true
        if [[ -z "${home_dir}" ]]; then
            warn "User '${user}' does not exist – skipping"
            return
        fi
    fi

    local ssh_dir="${home_dir}/.ssh"
    local auth_keys="${ssh_dir}/authorized_keys"

    mkdir -p "${ssh_dir}"
    chmod 700 "${ssh_dir}"

    # Append keys that are not already present
    while IFS= read -r key; do
        [[ "${key}" =~ ^ssh- || "${key}" =~ ^ecdsa- || "${key}" =~ ^sk- ]] || continue
        if grep -qxF "${key}" "${auth_keys}" 2>/dev/null; then
            log "Key already present for ${user}: ${key:0:40}..."
        else
            echo "${key}" >> "${auth_keys}"
            log "Added key for ${user}: ${key:0:40}..."
        fi
    done < "${KEYS_TMPFILE}"

    chmod 600 "${auth_keys}"

    # Fix ownership
    if [[ "${user}" != "root" ]]; then
        local uid gid
        uid="$(id -u "${user}" 2>/dev/null || true)"
        gid="$(id -g "${user}" 2>/dev/null || true)"
        if [[ -n "${uid}" && -n "${gid}" ]]; then
            chown -R "${uid}:${gid}" "${ssh_dir}"
        fi
    else
        chown -R root:root "${ssh_dir}"
    fi

    log "SSH authorized_keys updated for ${user} (${auth_keys})"
}

# root is always provisioned when a key URL is given
install_keys_for_user root

# Additional users from SSH_KEY_USERS
IFS=',' read -ra USERS <<< "${SSH_KEY_USERS}"
for u in "${USERS[@]}"; do
    u="${u// /}"   # trim spaces
    [[ "${u}" == "root" ]] && continue
    install_keys_for_user "${u}"
done

log "SSH key provisioning complete."
