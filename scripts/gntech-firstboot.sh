#!/bin/bash
set -u

LOG="/root/gntech-firstboot.log"
exec > >(tee -a "$LOG") 2>&1

echo "[GNTECH] Starting firstboot script"

apt update || true
apt install -y btrfs-progs snapper inotify-tools rsync git make gawk || true

ROOT_UUID="$(findmnt -n -o UUID /)"
echo "[GNTECH] Root UUID: $ROOT_UUID"

### Create Btrfs subvolumes
mkdir -p /mnt/btrfs-root
mount -o subvolid=5 UUID="$ROOT_UUID" /mnt/btrfs-root || exit 0

for subvol in @home @var_log @docker @snapshots; do
  if [ ! -d "/mnt/btrfs-root/$subvol" ]; then
    btrfs subvolume create "/mnt/btrfs-root/$subvol" || true
  fi
done

rsync -aAXH /home/ /mnt/btrfs-root/@home/ || true
rsync -aAXH /var/log/ /mnt/btrfs-root/@var_log/ || true

umount /mnt/btrfs-root || true

mkdir -p /home /var/log /var/lib/docker /.snapshots

### Preserve EFI and swap lines
EFI_LINE="$(grep -E '[[:space:]]/boot/efi[[:space:]]' /etc/fstab || true)"
SWAP_LINE="$(grep -E '[[:space:]]swap[[:space:]]' /etc/fstab || true)"

cat > /etc/fstab <<EOF
# /etc/fstab - GNTECH Debian 13 Btrfs layout

UUID=$ROOT_UUID / btrfs defaults,noatime,compress=zstd,subvol=@rootfs 0 0
UUID=$ROOT_UUID /home btrfs defaults,noatime,compress=zstd,subvol=@home 0 0
UUID=$ROOT_UUID /var/log btrfs defaults,noatime,compress=zstd,subvol=@var_log 0 0
UUID=$ROOT_UUID /var/lib/docker btrfs defaults,noatime,compress=zstd,subvol=@docker 0 0
UUID=$ROOT_UUID /.snapshots btrfs defaults,noatime,compress=zstd,subvol=@snapshots 0 0
EOF

[ -n "$EFI_LINE" ] && echo "$EFI_LINE" >> /etc/fstab
[ -n "$SWAP_LINE" ] && echo "$SWAP_LINE" >> /etc/fstab

systemctl daemon-reload || true

mount /home || true
mount /var/log || true
mount /var/lib/docker || true
mount /.snapshots || true

chmod 750 /.snapshots || true

### Manual Snapper config for existing @snapshots
mkdir -p /etc/snapper/configs

cat > /etc/snapper/configs/root <<'EOF'
SUBVOLUME="/"
FSTYPE="btrfs"
QGROUP=""
SPACE_LIMIT="0.5"
FREE_LIMIT="0.2"
ALLOW_USERS=""
ALLOW_GROUPS=""
SYNC_ACL="no"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="10"
NUMBER_LIMIT_IMPORTANT="5"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="6"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="4"
TIMELINE_LIMIT_MONTHLY="3"
TIMELINE_LIMIT_YEARLY="0"
EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
EOF

echo 'SNAPPER_CONFIGS="root"' > /etc/default/snapper

chmod 640 /etc/snapper/configs/root || true
chmod 750 /.snapshots || true

### Improved APT snapshots with package names
cat > /usr/local/sbin/snapper-apt-snapshot <<'EOF'
#!/bin/sh
set -u

PRE_FILE="/var/tmp/snapper-apt-pre"
DESC_FILE="/var/tmp/snapper-apt-desc"

if [ -e /etc/default/snapper ]; then
  . /etc/default/snapper
fi

[ "${DISABLE_APT_SNAPSHOT:-no}" = "yes" ] && exit 0
[ -x /usr/bin/snapper ] || exit 0
[ -e /etc/snapper/configs/root ] || exit 0

case "${1:-}" in
  pre)
    PKGS="$(while read -r deb; do
      [ -f "$deb" ] && dpkg-deb -f "$deb" Package 2>/dev/null
    done | sort -u | paste -sd ', ' -)"

    [ -z "$PKGS" ] && PKGS="unknown packages"

    DESC="Before APT: $PKGS"
    echo "$DESC" | cut -c1-180 > "$DESC_FILE"

    snapper create -d "$(cat "$DESC_FILE")" -c number -t pre -p > "$PRE_FILE" || true
    snapper cleanup number || true
    ;;

  post)
    if [ -e "$PRE_FILE" ]; then
      DESC="After APT: $(cat "$DESC_FILE" 2>/dev/null | sed 's/^Before APT: //')"
      snapper create -d "$(echo "$DESC" | cut -c1-180)" -c number -t post --pre-number="$(cat "$PRE_FILE")" || true
      snapper cleanup number || true
      rm -f "$PRE_FILE" "$DESC_FILE"
    fi
    ;;
esac

exit 0
EOF

chmod +x /usr/local/sbin/snapper-apt-snapshot

cat > /etc/apt/apt.conf.d/80snapper <<'EOF'
DPkg::Pre-Install-Pkgs {
    "/usr/local/sbin/snapper-apt-snapshot pre";
};

DPkg::Post-Invoke {
    "/usr/local/sbin/snapper-apt-snapshot post";
};
EOF

systemctl enable --now snapper-timeline.timer || true
systemctl enable --now snapper-cleanup.timer || true

snapper -c root create --description "Initial clean Debian 13 GNTECH install" || true

### Optional grub-btrfs from GitHub
if [ ! -d /opt/grub-btrfs ]; then
  git clone https://github.com/Antynea/grub-btrfs /opt/grub-btrfs || true
fi

if [ -d /opt/grub-btrfs ]; then
  cd /opt/grub-btrfs
  make install || true
  systemctl enable --now grub-btrfs.path || true
fi

update-grub || true

systemctl disable gntech-firstboot.service || true
rm -f /etc/systemd/system/gntech-firstboot.service
systemctl daemon-reload || true

echo "[GNTECH] Firstboot completed"
exit 0