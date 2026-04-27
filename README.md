# Debian 13 Automated Installer (GNTECH)

This project provides a fully automated Debian 13 (Trixie) installation using **preseed + GitHub-hosted scripts**, with:

* Btrfs subvolume layout
* Snapper snapshots (timeline + APT-aware)
* Automatic APT snapshot descriptions (package-aware)
* SSH key deployment from GitHub
* Static VLAN network configuration
* Optional `grub-btrfs` integration

---

## 📁 Repository Structure

```
debian-auto-install/
├── preseed.cfg
└── scripts/
    ├── gntech-finalize.sh
    └── gntech-firstboot.sh
```

---

## 🚀 Usage

### 1. Boot Debian Netinstall ISO

Download official Debian 13 netinst ISO and boot.

---

### 2. Modify Boot Parameters

At the boot menu, press **`e`** and append:

```
auto=true priority=critical \
preseed/url=https://raw.githubusercontent.com/gntech-dev/debian-auto-install/main/preseed.cfg
```

Then boot.

---

## ⚙️ What This Installer Does

### During Installation

* Uses DHCP for temporary network
* Installs base system + SSH
* Downloads and executes `gntech-finalize.sh`

### After Installation (First Boot)

* Creates Btrfs subvolumes:

  ```
  @rootfs
  @home
  @var_log
  @docker
  @snapshots
  ```
* Configures `/etc/fstab`
* Mounts all subvolumes
* Sets up Snapper
* Enables snapshot timers
* Configures APT snapshot hooks
* Optionally installs `grub-btrfs`

---

## 🌐 Network Configuration

Final network is set to:

```
Interface: enp1s0.20
IP:        10.0.20.30/24
Gateway:   10.0.20.1
DNS:       10.0.20.1
Domain:    GNTECH.ME
Hostname:  G1.GNTECH.ME
```

---

## 🔐 SSH Access

* User: `gntech`
* SSH keys automatically pulled from:

  ```
  https://github.com/gntech-dev.keys
  ```
* Password login disabled

---

## 📸 Snapper Configuration

### Enabled Features

* Timeline snapshots
* Cleanup policies
* APT-aware snapshots

### APT Snapshots

Snapshots are automatically created before and after package operations:

```
Before APT: package1, package2
After APT:  package1, package2
```

---

## 🧪 Verification

Run after installation:

```bash
hostname -f
ip -br a
findmnt /
findmnt /.snapshots
sudo btrfs subvolume list /
sudo snapper list
```

Expected:

* Subvolumes mounted correctly
* Snapshots exist
* APT snapshots working

---

## 📊 Disk Usage

Check snapshot usage:

```bash
sudo btrfs filesystem usage /
sudo btrfs filesystem du -s /.snapshots
```

---

## ⚠️ Known Issues

### grub-btrfs warning

```
UUID of the root subvolume is not available
```

* This is a known issue with Debian 13 + `grub-btrfs`
* Does **not affect Snapper functionality**
* Only affects GRUB snapshot menu generation

---

## 🔧 Customization

### Change Disk

Edit in `preseed.cfg`:

```
d-i partman-auto/disk string /dev/sda
```

For NVMe:

```
/dev/nvme0n1
```

---

### Change Network

Modify inside:

```
scripts/gntech-finalize.sh
```

---

### Disable APT Snapshots

```bash
echo 'DISABLE_APT_SNAPSHOT=yes' | sudo tee /etc/default/snapper
```

---

## 🧠 Design Notes

* Installer is **stateless** → logic lives in GitHub
* Safe execution (`|| true`) avoids installer failures
* Btrfs layout optimized for rollback and isolation
* Snapper integrated with APT for real rollback points

---

## 🧾 License

Use freely. Modify as needed.
