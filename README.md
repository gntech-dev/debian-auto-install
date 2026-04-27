# debian-auto-install

Fully automated **Debian 13 (Trixie)** installation via preseed and GitHub-hosted
scripts. The system boots the Debian installer, automatically partitions the
disk, installs the base system, creates Btrfs subvolumes, sets up Snapper
snapshots with APT integration, provisions SSH public keys, and writes a
production-ready network configuration – all without any manual interaction.

---

## Features

| Feature | Details |
|---|---|
| **Unattended install** | Single preseed file drives the entire Debian 13 installation |
| **Btrfs subvolumes** | `@` `/`, `@home` `/home`, `@snapshots` `/.snapshots`, `@var_log` `/var/log` |
| **Btrfs mount options** | `compress=zstd:3`, `noatime`, `space_cache=v2` for optimal performance |
| **Snapper** | Root-filesystem snapshots configured and enabled on first boot |
| **APT snapshots** | Pre/post hooks automatically create numbered snapshots around every `apt`/`dpkg` run |
| **SSH key provisioning** | Public keys fetched from any URL (e.g. `https://github.com/<user>.keys`) |
| **Network config** | Static IP *or* DHCP via `/etc/network/interfaces`; hostname, FQDN and DNS fully set |
| **SSH hardening** | Disables password auth when keys are provisioned, no empty passwords, no X11 |
| **Unattended upgrades** | Security patches applied automatically |
| **UEFI / GPT** | EFI System Partition + `/boot` (ext4) + swap + Btrfs root |

---

## Repository Layout

```
debian-auto-install/
├── preseed.cfg           # Debian installer preseed (UEFI/GPT, Btrfs)
├── config.env            # All user-configurable variables
└── scripts/
    ├── setup.sh          # Orchestrator – called by preseed late_command
    ├── btrfs-subvols.sh  # Creates Btrfs subvolumes and rewrites fstab
    ├── post-install.sh   # In-chroot driver for the scripts below
    ├── snapper-setup.sh  # Snapper config + APT hooks
    ├── ssh-setup.sh      # SSH public-key provisioning
    └── network-setup.sh  # /etc/network/interfaces, hostname, DNS
```

---

## Quick Start

### 1 – Fork / clone this repository

```bash
git clone https://github.com/gntech-dev/debian-auto-install.git
cd debian-auto-install
```

### 2 – Customise `config.env`

Edit `config.env` and set at minimum:

```bash
# URL where YOUR fork's scripts/ directory is reachable
SCRIPTS_URL="https://raw.githubusercontent.com/<your-org>/<your-repo>/main/scripts"

# SSH public keys to install (GitHub keys endpoint works great)
SSH_KEYS_URL="https://github.com/<your-username>.keys"

# Target hostname
HOSTNAME="my-server"
DOMAIN="example.com"

# Static IP (leave empty for DHCP)
STATIC_IP="192.168.1.100"
GATEWAY="192.168.1.1"
DNS_SERVERS="1.1.1.1 8.8.8.8"
```

### 3 – Set password hashes in `preseed.cfg`

Generate SHA-512 hashes (requires the `whois` package):

```bash
echo "mysecretpassword" | mkpasswd -m sha-512 -s
```

Replace the `CHANGEME_ROOT_HASH` and `CHANGEME_ADMIN_HASH` placeholders in
`preseed.cfg` with the output.

### 4 – Push to GitHub

```bash
git add -A && git commit -m "configure for my environment" && git push
```

All scripts are served from the GitHub raw URL – no web server needed.

### 5 – Boot the Debian 13 installer

Add the following to the kernel command line in the boot menu
(press `e` in GRUB or `Tab` in isolinux):

```
auto=true priority=critical
url=https://raw.githubusercontent.com/<org>/<repo>/main/preseed.cfg
SCRIPTS_URL=https://raw.githubusercontent.com/<org>/<repo>/main/scripts
SSH_KEYS_URL=https://github.com/<user>.keys
HOSTNAME=my-server
DOMAIN=example.com
```

For a static IP, also add:

```
STATIC_IP=192.168.1.100
GATEWAY=192.168.1.1
DNS_SERVERS="1.1.1.1 8.8.8.8"
```

The installer downloads the preseed, answers every question automatically,
and hands off to the post-install scripts. The machine reboots into the
finished system.

---

## How It Works

```
Debian 13 installer
  │
  ├─ partman   Creates GPT with EFI + /boot + swap + Btrfs /
  ├─ debootstrap + packages installed
  │
  └─ late_command
       │
       └─ wget setup.sh && bash setup.sh
            │
            ├─ [chroot] btrfs-subvols.sh
            │     Creates @, @home, @snapshots, @var_log
            │     rsyncs installed tree into @
            │     Writes /etc/fstab with UUID references
            │     Sets @ as Btrfs default subvolume
            │     Adds rootflags=subvol=@ to /etc/default/grub
            │
            ├─ [installer env] Remounts /target with subvol=@
            │
            └─ [chroot] post-install.sh
                  │
                  ├─ snapper-setup.sh  (Snapper config + APT hooks)
                  ├─ ssh-setup.sh      (fetch & install public keys)
                  ├─ network-setup.sh  (interfaces, hostname, DNS)
                  └─ SSH hardening, unattended-upgrades, sudo
```

---

## Disk Layout

| Partition | Size | Type | Mount |
|---|---|---|---|
| `/dev/sda1` | 512 MB | EFI System (vfat) | `/boot/efi` |
| `/dev/sda2` | 1 GB | ext4 | `/boot` |
| `/dev/sda3` | 4 GB | swap | `[swap]` |
| `/dev/sda4` | remainder | Btrfs | `/` via `@` subvolume |

### Btrfs Subvolumes

| Subvolume | Mount Point | Purpose |
|---|---|---|
| `@` | `/` | Root filesystem |
| `@home` | `/home` | User home directories |
| `@snapshots` | `/.snapshots` | Snapper snapshot storage |
| `@var_log` | `/var/log` | Log files (excluded from root snapshots) |

### Btrfs Mount Options

All subvolumes are mounted with:

```
compress=zstd:3,noatime,space_cache=v2
```

- **compress=zstd:3** – transparent compression at level 3 (good ratio / fast)
- **noatime** – no access-time writes, reduces write amplification
- **space_cache=v2** – faster free-space lookups

---

## Snapper & APT Integration

Snapper is configured for the root subvolume with the following retention
policy (adjustable in `config.env`):

| Type | Default |
|---|---|
| Hourly | 5 |
| Daily | 7 |
| Weekly | 0 |
| Monthly | 0 |
| Yearly | 0 |
| APT (numbered) | 10 |

Every `apt install` / `apt upgrade` / `dpkg` run automatically creates a
**pre** and **post** snapshot via `/etc/apt/apt.conf.d/80snapper`.

To list snapshots:

```bash
snapper -c root list
```

To roll back to snapshot 3:

```bash
snapper -c root undochange 3..0
```

---

## SSH Key Provisioning

Set `SSH_KEYS_URL` to any URL that returns newline-separated SSH public keys.
The simplest option is the GitHub keys endpoint:

```
SSH_KEYS_URL=https://github.com/<username>.keys
```

Keys are installed for `root` and any users listed in `SSH_KEY_USERS`
(comma-separated, default: `root,admin`).

When at least one key is installed, SSH password authentication is
**automatically disabled** for improved security.

---

## Network Configuration

Set `STATIC_IP` in `config.env` or as a kernel boot parameter for a static
address.  Leave it empty for DHCP.

The following files are written:

- `/etc/network/interfaces` – interface configuration
- `/etc/hostname` – short hostname
- `/etc/hosts` – loopback + FQDN entries
- `/etc/resolv.conf` – DNS servers and search domain

---

## Configuration Reference

All variables can be set in **three places** (later overrides earlier):

1. `config.env` in the repository
2. Kernel command-line boot parameters
3. Environment variables exported before calling `setup.sh` manually

| Variable | Default | Description |
|---|---|---|
| `SCRIPTS_URL` | GitHub raw URL | Base URL for scripts (no trailing slash) |
| `SSH_KEYS_URL` | *(empty)* | URL returning SSH public keys |
| `SSH_KEY_USERS` | `root,admin` | Users to receive the provisioned keys |
| `HOSTNAME` | `debian-server` | Short hostname |
| `DOMAIN` | `local` | DNS domain / search domain |
| `TIMEZONE` | `UTC` | Timezone (e.g. `Europe/Berlin`) |
| `NETWORK_INTERFACE` | `eth0` | Primary NIC name |
| `STATIC_IP` | *(empty = DHCP)* | Static IPv4 address |
| `NETMASK` | `255.255.255.0` | Subnet mask |
| `GATEWAY` | *(empty)* | Default gateway (required for static) |
| `DNS_SERVERS` | `8.8.8.8 8.8.4.4` | Space-separated DNS resolvers |
| `BTRFS_OPTS` | `defaults,compress=zstd:3,noatime,space_cache=v2` | Btrfs fstab mount options |
| `SNAPPER_TIMELINE_MAX_HOURLY` | `5` | Max hourly snapshots |
| `SNAPPER_TIMELINE_MAX_DAILY` | `7` | Max daily snapshots |
| `SNAPPER_NUMBER_MAX_COUNT` | `10` | Max APT (numbered) snapshots |

---

## BIOS / Legacy Boot

The default `preseed.cfg` targets **UEFI / GPT** systems.  For legacy BIOS
installations, replace the EFI partition line in the partman recipe with a
BIOS boot partition:

```
1 1 1 free
    $iflabel{ gpt }
    $primary{ }
    method{ biosgrub } .
```

and set `d-i grub-installer/bootdev string /dev/sda` (the MBR, not a
partition).

---

## Troubleshooting

| Problem | Solution |
|---|---|
| Installer hangs at network | Add `netcfg/disable_dhcp=true` and set a static IP on the kernel cmdline |
| Scripts not found (404) | Verify `SCRIPTS_URL` points to a raw GitHub URL (not the HTML page) |
| Password login rejected | The `CHANGEME_*` placeholder hashes are invalid; replace them |
| Wrong disk targeted | Change `d-i partman-auto/disk string` in `preseed.cfg` |
| Snapper errors on first boot | `/.snapshots` must be writable; verify the `@snapshots` subvolume is mounted |
| Static IP not applied | Check `STATIC_IP`, `GATEWAY`, and `NETWORK_INTERFACE` values |
| Log inspection | SSH in and check `/var/log/post-install.log` |

---

## License

MIT – see [LICENSE](LICENSE) for details.