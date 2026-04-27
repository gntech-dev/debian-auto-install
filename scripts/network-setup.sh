#!/usr/bin/env bash
# network-setup.sh – Production-ready network configuration.
#
# Runs inside the target chroot.
# Configures /etc/network/interfaces (static or DHCP), hostname, hosts, and DNS.

set -euo pipefail

# shellcheck source=/dev/null
[[ -f /tmp/env.sh ]] && source /tmp/env.sh

log()  { echo "[network-setup] $*"; }
warn() { log "WARN: $*"; }

NETWORK_INTERFACE="${NETWORK_INTERFACE:-eth0}"
STATIC_IP="${STATIC_IP:-}"
NETMASK="${NETMASK:-255.255.255.0}"
GATEWAY="${GATEWAY:-}"
DNS_SERVERS="${DNS_SERVERS:-8.8.8.8 8.8.4.4}"
DNS_SEARCH="${DNS_SEARCH:-local}"
HOSTNAME="${HOSTNAME:-debian-server}"
DOMAIN="${DOMAIN:-local}"
FQDN="${HOSTNAME}.${DOMAIN}"

# ---------------------------------------------------------------------------
# /etc/hostname
# ---------------------------------------------------------------------------

log "Setting hostname to ${HOSTNAME}..."
echo "${HOSTNAME}" > /etc/hostname

# ---------------------------------------------------------------------------
# /etc/hosts
# ---------------------------------------------------------------------------

log "Configuring /etc/hosts..."

{
    echo "127.0.0.1   localhost"
    echo "::1         localhost ip6-localhost ip6-loopback"
    echo "ff02::1     ip6-allnodes"
    echo "ff02::2     ip6-allrouters"
    echo ""
    if [[ -n "${STATIC_IP}" ]]; then
        echo "${STATIC_IP}   ${FQDN} ${HOSTNAME}"
    else
        echo "127.0.1.1   ${FQDN} ${HOSTNAME}"
    fi
} > /etc/hosts

# ---------------------------------------------------------------------------
# /etc/network/interfaces
# ---------------------------------------------------------------------------

log "Writing /etc/network/interfaces..."

# Build DNS line from space-separated servers
DNS_NS_LINE="$(echo "${DNS_SERVERS}" | tr ' ' '\n' | awk '{print}' | paste -sd ' ')"

if [[ -n "${STATIC_IP}" ]]; then
    log "Configuring static IP: ${STATIC_IP} via ${GATEWAY}"

    if [[ -z "${GATEWAY}" ]]; then
        warn "STATIC_IP is set but GATEWAY is empty – routing may not work"
    fi

    cat > /etc/network/interfaces <<EOF
# /etc/network/interfaces – configured by debian-auto-install

source /etc/network/interfaces.d/*

# Loopback
auto lo
iface lo inet loopback

# Primary interface – static
auto ${NETWORK_INTERFACE}
iface ${NETWORK_INTERFACE} inet static
    address ${STATIC_IP}
    netmask ${NETMASK}
    gateway ${GATEWAY}
    dns-nameservers ${DNS_NS_LINE}
    dns-search ${DNS_SEARCH}
EOF

else
    log "Configuring DHCP on ${NETWORK_INTERFACE}"

    cat > /etc/network/interfaces <<EOF
# /etc/network/interfaces – configured by debian-auto-install

source /etc/network/interfaces.d/*

# Loopback
auto lo
iface lo inet loopback

# Primary interface – DHCP
auto ${NETWORK_INTERFACE}
iface ${NETWORK_INTERFACE} inet dhcp
    dns-nameservers ${DNS_NS_LINE}
    dns-search ${DNS_SEARCH}
EOF
fi

log "Network interfaces configured."

# ---------------------------------------------------------------------------
# /etc/resolv.conf
# ---------------------------------------------------------------------------

log "Writing /etc/resolv.conf..."

{
    [[ -n "${DNS_SEARCH}" ]] && echo "search ${DNS_SEARCH}"
    for ns in ${DNS_SERVERS}; do
        echo "nameserver ${ns}"
    done
} > /etc/resolv.conf

# ---------------------------------------------------------------------------
# /etc/network/interfaces.d/ – ensure directory exists for includes
# ---------------------------------------------------------------------------

mkdir -p /etc/network/interfaces.d

# ---------------------------------------------------------------------------
# Ensure ifupdown is installed and enabled
# ---------------------------------------------------------------------------

if ! dpkg -l ifupdown 2>/dev/null | grep -q '^ii'; then
    log "Installing ifupdown..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ifupdown 2>&1 || true
fi

# Disable systemd-networkd if it would conflict with ifupdown
if systemctl is-enabled systemd-networkd &>/dev/null 2>&1; then
    log "Disabling systemd-networkd (using ifupdown instead)..."
    systemctl disable systemd-networkd 2>/dev/null || true
fi

# Disable NetworkManager if present (server installs should not use it)
if systemctl is-enabled NetworkManager &>/dev/null 2>&1; then
    log "Disabling NetworkManager (server install)..."
    systemctl disable NetworkManager 2>/dev/null || true
fi

# Enable networking service
systemctl enable networking 2>/dev/null || true

log "Network setup complete."
log "  Hostname : ${FQDN}"
log "  Interface: ${NETWORK_INTERFACE}"
log "  Mode     : $([[ -n "${STATIC_IP}" ]] && echo "static (${STATIC_IP})" || echo "DHCP")"
log "  DNS      : ${DNS_NS_LINE}"
