#!/bin/bash
set -u

LOG="/root/gntech-finalize.log"
exec > >(tee -a "$LOG") 2>&1

echo "[GNTECH] Starting finalize script - EXT4 version"

apt update || true
apt install -y sudo curl git openssh-server ifupdown vlan ca-certificates rsync make gawk || true

### Hostname
echo "G1" > /etc/hostname

cat > /etc/hosts <<'EOF'
127.0.0.1       localhost
127.0.1.1       G1.GNTECH.ME G1

::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

### Final static VLAN 20 network
cat > /etc/network/interfaces <<'EOF'
# This file describes the network interfaces available on this system.

source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

# Physical NIC - no IP directly on parent
allow-hotplug enp1s0
iface enp1s0 inet manual

# VLAN 20
auto enp1s0.20
iface enp1s0.20 inet static
        address 10.0.20.30/24
        gateway 10.0.20.1
        dns-nameservers 10.0.20.1
        dns-search GNTECH.ME

iface enp1s0.20 inet6 auto
EOF

### SSH keys
mkdir -p /home/gntech/.ssh
chmod 700 /home/gntech/.ssh

curl -fsSL https://github.com/gntech-dev.keys \
  -o /home/gntech/.ssh/authorized_keys || true

chmod 600 /home/gntech/.ssh/authorized_keys || true
chown -R gntech:gntech /home/gntech/.ssh || true

### Sudo
usermod -aG sudo gntech || true

### SSH hardening
grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
grep -q '^PermitRootLogin no' /etc/ssh/sshd_config || echo 'PermitRootLogin no' >> /etc/ssh/sshd_config

update-grub || true

echo "[GNTECH] Finalize completed - EXT4 version"
exit 0
