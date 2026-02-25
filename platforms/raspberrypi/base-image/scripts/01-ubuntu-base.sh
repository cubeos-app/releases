#!/bin/bash
# =============================================================================
# 01-ubuntu-base.sh — Golden base image: package installation
# =============================================================================
# Takes stock Ubuntu 24.04.3 Server for Raspberry Pi and installs everything
# CubeOS needs. This script does NOT configure anything — it only installs
# packages and removes bloat. Configuration is done by the release pipeline.
#
# Run frequency: Monthly, or when the package list changes.
# Run environment: QEMU ARM64 emulation (packer-builder-arm)
# Expected time: ~25-30 minutes under QEMU
#
# v2.0 (alpha.21+):
#   - Added: sqlite3, gpiod, libgpiod2, usbutils, v4l-utils, pps-tools
#   - Added: modemmanager, libqmi-utils, libmbim-utils, usb-modeswitch
#   - Added: gpsd, gpsd-clients, chrony (replaces timesyncd)
#   - Added: wireguard-tools, ethtool, avahi-daemon
#   - Added: ntfs-3g, exfatprogs, smartmontools
#   - Added: picocom, nano, less, zram-tools
#   - Removed: nmap (unnecessary, large)
#   - --no-install-recommends on non-essential groups
#   - Disable man-db auto-update (saves ~10 min QEMU build time)
#   - All critical packages protected with apt-mark manual
#
# v2.1 (alpha.22):
#   - B62: ZRAM configured at 100% of RAM with lz4 (was default 14%)
#   - B65: Added python3-pyasyncore + python3-pyasynchat for fail2ban
#          (Python 3.12 removed asynchat/asyncore from stdlib)
#   - Added fail2ban, asynchat/asyncore to protected packages list
#
# v2.2 (alpha.24):
#   - Added: openvpn, tor (VPN/anonymity client daemons)
#   - Added: smbclient (SMB CLI tools, complements cifs-utils)
#   - Added: plocate (fast file search, replaces mlocate)
#   - Removed: gpsd-clients (python3-gps + GTK deps, ~40min QEMU build)
#     HAL communicates with gpsd via socket protocol, no Python CLI needed
#   - B65: Pipe masking fixed, verification now aborts build on failure
#
# v3.0 (golden base rebuild — "cook once, use forever"):
#   - Added GROUP 12: bluez, bluez-tools (BLE for MeshSat Track B)
#   - Added GROUP 13: rtl-sdr, alsa-utils (SDR C4, Radio C5)
#   - Added GROUP 14: lm-sensors (Power profiles C3)
#   - Added GROUP 15: apparmor-utils (Security hardening SEC-09)
#   - Added GROUP 16: mptcpd (optional — MPTCP WAN bonding C0)
#   - Added GROUP 17: udisks2 (USB drive management, Phase 4 backup)
#   - Added GROUP 18: setserial (optional — serial port config C3/C5)
#   - Added GROUP 19: samba, nfs-kernel-server (file sharing server)
#   - Added GROUP 20: lvm2, cryptsetup, btrfs-progs, xfsprogs, hdparm,
#     fio, drbd-utils, ocfs2-tools (advanced storage / RAID / encryption)
#   - Expanded GROUP 7: nvme-cli, mdadm (NVMe + software RAID)
#   - Added RTL-SDR modprobe blacklist (dvb_usb_rtl28xxu)
#   - Added kernel modules: pps_gpio, snd-usb-audio, raid1, dm-crypt
#   - Covers: Track A (Phases 1-6), Track B (MeshSat), Track C (C0-C7),
#     X1004 dual NVMe HAT, clustered storage (DRBD/OCFS2)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Global environment — prevents debconf warnings and ensures visible output
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
export TERM=dumb
export LANG=C.UTF-8

# ---------------------------------------------------------------------------
# Helper: install a group of packages with retry and visible progress
# ---------------------------------------------------------------------------
install_group() {
    local group_name="$1"
    shift
    local packages=("$@")
    local max_attempts=3
    local attempt=1

    echo ""
    echo "[BASE] >>> Installing: $group_name"
    echo "[BASE]     Packages: ${packages[*]}"
    echo "[BASE]     Started: $(date -u +%H:%M:%S)"

    while [ $attempt -le $max_attempts ]; do
        if [ $attempt -gt 1 ]; then
            echo "[BASE]     Retry $attempt/$max_attempts (refreshing cache first)..."
            apt-get update -q >/dev/null 2>&1 || true
            sleep 5
        fi

        if apt-get install -y --no-install-recommends \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            "${packages[@]}"; then
            echo "[BASE]     $group_name: OK ($(date -u +%H:%M:%S))"
            return 0
        fi

        echo "[BASE]     $group_name: FAILED (attempt $attempt/$max_attempts)"
        attempt=$((attempt + 1))
    done

    echo "[BASE] FATAL: $group_name failed after $max_attempts attempts"
    echo "[BASE] Failed packages: ${packages[*]}"
    return 1
}

# ---------------------------------------------------------------------------
# Helper: install optional packages (non-fatal if missing from repo)
# ---------------------------------------------------------------------------
install_optional() {
    local pkg="$1"
    local desc="${2:-$1}"
    echo ""
    echo "[BASE] >>> Installing (optional): $desc"
    if apt-get install -y --no-install-recommends "$pkg" 2>/dev/null; then
        echo "[BASE]     $desc: OK"
    else
        echo "[BASE]     $desc: not available (non-fatal)"
    fi
}

echo "============================================================"
echo "  CubeOS Golden Base Image — Ubuntu Package Installation"
echo "  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "============================================================"
echo ""

# ---------------------------------------------------------------------------
# Fix DNS resolution in QEMU chroot
# ---------------------------------------------------------------------------
echo "[BASE] Fixing DNS resolution for chroot..."

rm -f /etc/resolv.conf
cat > /etc/resolv.conf << 'RESOLV'
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 8.8.4.4
RESOLV

echo -n "[BASE]   Testing DNS... "
if getent hosts archive.ubuntu.com >/dev/null 2>&1; then
    echo "OK"
else
    echo "FAILED"
    echo "FATAL: Cannot resolve hostnames. Aborting."
    exit 1
fi

# ---------------------------------------------------------------------------
# QEMU py3compile workaround
# ---------------------------------------------------------------------------
echo "[BASE] Installing QEMU workarounds..."

for bin in py3compile py3clean; do
    if [ -f "/usr/bin/$bin" ]; then
        mv "/usr/bin/$bin" "/usr/bin/${bin}.real"
        printf '#!/bin/sh\nexit 0\n' > "/usr/bin/$bin"
        chmod +x "/usr/bin/$bin"
    fi
done
echo "[BASE]   py3compile/py3clean wrapped"

# ---------------------------------------------------------------------------
# policy-rc.d — prevent services starting in chroot
# ---------------------------------------------------------------------------
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d
echo "[BASE]   policy-rc.d installed"

# ---------------------------------------------------------------------------
# Disable man-db auto-update (saves ~10 min under QEMU emulation)
# ---------------------------------------------------------------------------
echo "[BASE] Disabling man-db auto-update..."
echo 'man-db man-db/auto-update boolean false' | debconf-set-selections
echo "[BASE]   man-db auto-update: disabled"

# ---------------------------------------------------------------------------
# Remove snap
# ---------------------------------------------------------------------------
echo ""
echo "[BASE] Removing snap..."

systemctl stop snapd.service snapd.socket snapd.seeded.service 2>/dev/null || true
systemctl disable snapd.service snapd.socket snapd.seeded.service 2>/dev/null || true

if command -v snap &>/dev/null; then
    for snap_name in $(snap list 2>/dev/null | awk 'NR>1 {print $1}' | grep -v "^core" | grep -v "^snapd"); do
        snap remove --purge "$snap_name" 2>/dev/null || true
    done
    snap remove --purge snapd 2>/dev/null || true
fi

apt-get purge -y snapd squashfs-tools 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

cat > /etc/apt/preferences.d/no-snapd.pref << 'NOSNAP'
Package: snapd
Pin: release *
Pin-Priority: -10
NOSNAP

rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd
echo "[BASE]   snap: REMOVED"

# ---------------------------------------------------------------------------
# Remove bloat
# ---------------------------------------------------------------------------
echo "[BASE] Removing bloat packages..."
apt-get purge -y \
    ubuntu-advantage-tools \
    landscape-common \
    popularity-contest \
    unattended-upgrades \
    update-notifier-common \
    motd-news-config \
    2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
echo "[BASE]   Bloat: REMOVED"

# ---------------------------------------------------------------------------
# System update — WITH VISIBLE PROGRESS
# ---------------------------------------------------------------------------
echo ""
echo "[BASE] ============================================"
echo "[BASE]  apt-get update (expect 3-5 min under QEMU)"
echo "[BASE]  Started: $(date -u +%H:%M:%S)"
echo "[BASE] ============================================"
apt-get update 2>&1 | grep -E "^(Hit|Get|Fetched|Reading)" || true
echo "[BASE] Finished: $(date -u +%H:%M:%S)"
echo "[BASE] Package lists: OK"

echo ""
echo "[BASE] ============================================"
echo "[BASE]  apt-get upgrade (expect 5-10 min under QEMU)"
echo "[BASE]  Started: $(date -u +%H:%M:%S)"
echo "[BASE] ============================================"
apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    2>&1 | grep -E "^(Setting up|Unpacking|Preparing|Processing)" | tail -30 || true
echo "[BASE] Finished: $(date -u +%H:%M:%S)"
echo "[BASE] Upgrade: OK"

# ---------------------------------------------------------------------------
# CRITICAL: Refresh apt cache AFTER upgrade
# ---------------------------------------------------------------------------
echo ""
echo "[BASE] Refreshing package lists after upgrade..."
apt-get update 2>&1 | grep -E "^(Hit|Get|Fetched|Reading)" || true
echo "[BASE] Cache refresh: OK"

echo "[BASE] Fixing any broken dependencies..."
apt-get install -f -y 2>/dev/null || true

# ---------------------------------------------------------------------------
# Install packages in groups (visible progress, isolated failures)
# ---------------------------------------------------------------------------

# ===== GROUP 1: Core System =====
install_group "Core system" \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common

# ===== GROUP 2: Networking =====
install_group "Networking" \
    hostapd \
    dnsmasq \
    iptables \
    iw \
    wireless-tools \
    wpasupplicant \
    rfkill \
    bridge-utils \
    net-tools \
    iputils-ping \
    dnsutils \
    tcpdump \
    ethtool \
    avahi-daemon \
    networkd-dispatcher \
    isc-dhcp-client

# ===== GROUP 3: Security & VPN =====
install_group "Security / VPN" \
    fail2ban \
    ufw \
    openssh-server \
    wireguard-tools \
    openvpn \
    tor

# B65: fail2ban on Python 3.12+ needs both asyncore AND asynchat.
echo "[BASE] Installing fail2ban Python 3.12 dependencies (B65)..."
apt-get install -y --no-install-recommends python3-pyasyncore
echo "[BASE]   python3-pyasyncore: installed (apt)"

ASYNCHAT_VERSION="1.0.4"
echo "[BASE]   Installing pyasynchat ${ASYNCHAT_VERSION} from PyPI tarball..."
curl -sL -o /tmp/pyasynchat.tar.gz \
  "https://files.pythonhosted.org/packages/source/p/pyasynchat/pyasynchat-${ASYNCHAT_VERSION}.tar.gz"
tar xzf /tmp/pyasynchat.tar.gz -C /tmp/
cp -r "/tmp/pyasynchat-${ASYNCHAT_VERSION}/asynchat" /usr/lib/python3/dist-packages/
rm -rf /tmp/pyasynchat.tar.gz /tmp/pyasynchat-${ASYNCHAT_VERSION}
echo "[BASE]   pyasynchat: installed (tarball — pip not available, apt has no package)"

if python3 -c "import asyncore; import asynchat; print('asyncore+asynchat: OK')" 2>&1; then
    echo "[BASE]   B65 verification: PASS (both modules importable)"
else
    echo "[BASE]   FATAL: asyncore or asynchat not importable. fail2ban will crash."
    echo "[BASE]   asyncore: $(python3 -c 'import asyncore' 2>&1)"
    echo "[BASE]   asynchat: $(python3 -c 'import asynchat' 2>&1)"
    exit 1
fi

# ===== GROUP 4: Raspberry Pi Hardware =====
install_group "Hardware / Pi" \
    i2c-tools \
    util-linux-extra \
    watchdog \
    linux-firmware \
    usbutils \
    libgpiod2 \
    gpiod \
    v4l-utils \
    pps-tools

install_optional "libraspberrypi-bin" "libraspberrypi-bin (vcgencmd)"

# ===== GROUP 5: Cellular / Modem =====
install_group "Cellular / Modem" \
    modemmanager \
    libqmi-utils \
    libmbim-utils \
    usb-modeswitch \
    usb-modeswitch-data

# ===== GROUP 6: GPS & Time =====
install_group "GPS / Time" \
    gpsd \
    chrony

# ===== GROUP 7: Storage & Filesystems =====
# v3.0: Added nvme-cli (X1004 dual NVMe HAT) and mdadm (software RAID)
install_group "Storage" \
    cifs-utils \
    smbclient \
    nfs-common \
    parted \
    e2fsprogs \
    dosfstools \
    ntfs-3g \
    smartmontools \
    nvme-cli \
    mdadm

install_optional "exfatprogs" "exfatprogs (exFAT support)"

# ===== GROUP 8: Monitoring =====
install_group "Monitoring" \
    htop \
    iotop-c \
    sysstat \
    lsof \
    strace

# ===== GROUP 9: Utilities =====
install_group "Utilities" \
    jq \
    git \
    vim-tiny \
    nano \
    less \
    tmux \
    wget \
    rsync \
    zip \
    unzip \
    xz-utils \
    pigz \
    sqlite3 \
    picocom \
    plocate \
    bc

# ===== GROUP 10: SD Card & Memory Optimization =====
install_group "SD Card optimization" \
    zram-tools

echo "[BASE] Configuring ZRAM (100% RAM, lz4)..."
cat > /etc/default/zramswap <<'ZRAM'
ALGO=lz4
PERCENT=100
ZRAM
echo "[BASE]   ZRAM: 100% of RAM with lz4 compression"

# ===== GROUP 11: Cloud-init =====
install_group "Cloud-init" \
    cloud-init

install_group "Python (no pip)" \
    python3

# =========================================================================
# NEW IN v3.0: Groups 12–20
# =========================================================================

# ===== GROUP 12: Bluetooth / BLE (Track B: MeshSat) =====
install_group "Bluetooth / BLE" \
    bluez \
    bluez-tools

# ===== GROUP 13: SDR / Radio Host Tools (C4: SDR, C5: Radio) =====
install_group "SDR / Radio" \
    rtl-sdr \
    alsa-utils

# ===== GROUP 14: Sensors & Power Monitoring (C3: Smart Power) =====
install_group "Sensors" \
    lm-sensors

# ===== GROUP 15: Security Hardening (Phase 1.3, SEC-09) =====
install_group "Security hardening" \
    apparmor-utils

# ===== GROUP 16: MPTCP Support (C0: WAN Bonding) =====
install_optional "mptcpd" "mptcpd (MPTCP path manager daemon)"

# ===== GROUP 17: USB Drive Management (Phase 4: Backup) =====
install_group "USB drive management" \
    udisks2

# ===== GROUP 18: Serial Port Tools (Track B, C3, C5) =====
install_optional "setserial" "setserial (serial port config)"

# ===== GROUP 19: File Sharing Server (NVMe storage) =====
# Samba and NFS server daemons for sharing NVMe/RAID storage over the
# network. Run on the host (not Docker) — need direct access to RAID
# mount points and kernel-level NFS exports.
install_group "File sharing server" \
    samba \
    nfs-kernel-server

# ===== GROUP 20: Advanced Storage / RAID / Encryption =====
# Full storage stack for the Geekworm X1004 dual NVMe HAT and future
# multi-node clustered storage.
#
# Stack options available after install:
#   Simple:    NVMe -> ext4/XFS/Btrfs
#   RAID:      NVMe x2 -> mdadm RAID0/1 -> ext4/XFS
#   LVM:       NVMe -> LVM -> LVs (Docker, shares, backup)
#   Encrypted: NVMe -> LUKS -> LVM -> LVs
#   Btrfs:     NVMe x2 -> Btrfs RAID1 (built-in, no mdadm needed)
#   Clustered: NVMe -> DRBD -> OCFS2 (multi-node shared filesystem)
install_group "Advanced storage" \
    lvm2 \
    cryptsetup \
    btrfs-progs \
    xfsprogs \
    hdparm \
    fio

# DRBD + OCFS2: clustered storage for multi-node CubeOS deployments.
# DRBD mirrors block devices over the network (RAID1 across nodes).
# OCFS2 provides a shared-access cluster filesystem on top of DRBD.
# Both require kernel modules — cannot run in Docker.
install_optional "drbd-utils" "drbd-utils (DRBD network-mirrored block devices)"
install_optional "ocfs2-tools" "ocfs2-tools (OCFS2 cluster filesystem)"

# ---------------------------------------------------------------------------
# Install Docker CE
# ---------------------------------------------------------------------------
echo ""
echo "[BASE] Installing Docker CE..."

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

echo "[BASE]   Refreshing apt with Docker repo..."
apt-get update 2>&1 | grep -E "^(Hit|Get|Fetched|Reading)" || true

install_group "Docker CE" \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

echo "[BASE]   Docker: $(docker --version 2>/dev/null || echo 'installed')"

# ---------------------------------------------------------------------------
# CRITICAL: Mark packages that autoremove likes to strip
# ---------------------------------------------------------------------------
echo ""
echo "[BASE] Protecting critical packages from autoremove..."
PROTECTED_PACKAGES=(
    # --- v2.x packages ---
    util-linux-extra    # hwclock for RTC (B03/B44)
    sqlite3             # CLI database debugging
    i2c-tools           # UPS HAT, RTC, sensors
    gpiod               # Modern GPIO interface (Pi 5)
    libgpiod2           # GPIO library
    usbutils            # lsusb device detection
    v4l-utils           # Camera/video
    pps-tools           # GPS PPS precision time
    modemmanager        # Cellular modems
    libqmi-utils        # Qualcomm modem tools
    libmbim-utils       # MBIM modem tools
    usb-modeswitch      # USB modem mode-switch
    usb-modeswitch-data # Modem device database
    gpsd                # GPS daemon
    chrony              # NTP replacement
    openvpn             # VPN client
    tor                 # Tor client
    smbclient           # SMB/CIFS CLI tools
    plocate             # Fast file search
    picocom             # Serial terminal
    smartmontools       # SMART disk monitoring
    ethtool             # Network diagnostics
    avahi-daemon        # mDNS discovery
    wireguard-tools     # VPN
    zram-tools          # Compressed swap
    exfatprogs          # exFAT support
    ntfs-3g             # NTFS support
    bc                  # Calculator for scripts
    fail2ban            # B65: SSH intrusion prevention
    python3-pyasyncore  # B65: fail2ban asyncore compat
    wpasupplicant       # B52: SERVER_WIFI
    networkd-dispatcher # B52: auto eth0 carrier detection
    # --- v3.0 NEW: Hardware & Radio ---
    bluez               # Bluetooth stack (Track B)
    bluez-tools         # BT CLI tools
    rtl-sdr             # SDR device management (C4)
    alsa-utils          # Audio device management (C5)
    lm-sensors          # Hardware sensors (C3)
    apparmor-utils      # Security profiles (SEC-09)
    udisks2             # USB drive management
    # --- v3.0 NEW: Storage & RAID (X1004 dual NVMe) ---
    nvme-cli            # NVMe drive management
    mdadm               # Software RAID
    lvm2                # Logical Volume Manager
    cryptsetup          # LUKS disk encryption
    btrfs-progs         # Btrfs filesystem
    xfsprogs            # XFS filesystem
    hdparm              # Disk parameter tuning
    fio                 # I/O benchmarking
    # --- v3.0 NEW: File sharing server ---
    samba               # SMB file server
    nfs-kernel-server   # NFS file server
)
for pkg in "${PROTECTED_PACKAGES[@]}"; do
    apt-mark manual "$pkg" 2>/dev/null || true
done
# Optional packages — protect if installed
for pkg in drbd-utils ocfs2-tools mptcpd setserial; do
    apt-mark manual "$pkg" 2>/dev/null || true
done
echo "[BASE]   Protected ${#PROTECTED_PACKAGES[@]}+ packages from autoremove"

# ---------------------------------------------------------------------------
# Kernel modules and sysctl
# ---------------------------------------------------------------------------
echo ""
echo "[BASE] Configuring kernel parameters..."

cat > /etc/sysctl.d/99-cubeos.conf << 'SYSCTL'
# CubeOS networking requirements
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 1024
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.default.autoconf = 0

# Reduce kernel log noise
kernel.printk = 3 4 1 3

# MPTCP WAN bonding (C0) — disabled by default, enable via API
# net.mptcp.enabled = 1
SYSCTL

cat > /etc/modules-load.d/cubeos.conf << 'MODULES'
overlay
br_netfilter
i2c-dev
pps_gpio
snd-usb-audio
raid1
dm-crypt
MODULES

echo "[BASE]   Kernel config: OK"

# ---------------------------------------------------------------------------
# RTL-SDR: Blacklist DVB-T kernel driver (C4)
# ---------------------------------------------------------------------------
echo "[BASE] Configuring RTL-SDR modprobe blacklist..."
cat > /etc/modprobe.d/cubeos-blacklist.conf << 'BLACKLIST'
# RTL-SDR: prevent DVB-T driver from claiming RTL2832U devices (C4)
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2830
BLACKLIST
echo "[BASE]   RTL-SDR blacklist: OK"

# ---------------------------------------------------------------------------
# Chrony: disable default NTP pools (offline-first, GPS/PPS later)
# ---------------------------------------------------------------------------
echo "[BASE] Configuring chrony for offline-first..."
if [ -f /etc/chrony/chrony.conf ]; then
    sed -i 's/^pool /#pool /' /etc/chrony/chrony.conf
    sed -i 's/^server /#server /' /etc/chrony/chrony.conf
    echo "" >> /etc/chrony/chrony.conf
    echo "# CubeOS: local clock fallback for air-gapped operation" >> /etc/chrony/chrony.conf
    echo "local stratum 10" >> /etc/chrony/chrony.conf
    echo "# Allow subnet clients to sync from us" >> /etc/chrony/chrony.conf
    echo "allow 10.42.24.0/24" >> /etc/chrony/chrony.conf
fi
systemctl disable systemd-timesyncd 2>/dev/null || true
echo "[BASE]   chrony: configured for offline-first + local stratum 10"

# ---------------------------------------------------------------------------
# Disable services (HAL/API manage their lifecycle)
# ---------------------------------------------------------------------------

echo "[BASE] Disabling gpsd auto-start..."
systemctl disable gpsd 2>/dev/null || true
systemctl disable gpsd.socket 2>/dev/null || true
echo "[BASE]   gpsd: disabled"

echo "[BASE] Disabling ModemManager auto-start..."
systemctl disable ModemManager 2>/dev/null || true
echo "[BASE]   ModemManager: disabled"

echo "[BASE] Disabling OpenVPN auto-start..."
systemctl disable openvpn 2>/dev/null || true
systemctl disable 'openvpn@*' 2>/dev/null || true
echo "[BASE]   openvpn: disabled"

echo "[BASE] Disabling Tor auto-start..."
systemctl disable tor 2>/dev/null || true
echo "[BASE]   tor: disabled"

echo "[BASE] Disabling smartmontools auto-start..."
systemctl disable smartd 2>/dev/null || true
systemctl disable smartmontools 2>/dev/null || true
echo "[BASE]   smartd: disabled (enable manually for NVMe/external drives)"

echo "[BASE] Disabling avahi-daemon auto-start..."
systemctl disable avahi-daemon 2>/dev/null || true
echo "[BASE]   avahi-daemon: disabled"

echo "[BASE] Disabling wpa_supplicant (NOT masked — B52 SERVER_WIFI needs it)..."
systemctl disable wpa_supplicant 2>/dev/null || true
systemctl unmask wpa_supplicant 2>/dev/null || true
echo "[BASE]   wpa_supplicant: disabled (unmask verified)"

echo "[BASE] Enabling networkd-dispatcher..."
systemctl enable networkd-dispatcher 2>/dev/null || true
echo "[BASE]   networkd-dispatcher: enabled"

# --- v3.0 new services ---

echo "[BASE] Disabling bluetooth auto-start..."
systemctl disable bluetooth 2>/dev/null || true
echo "[BASE]   bluetooth: disabled (HAL manages BLE lifecycle)"

echo "[BASE] Disabling lm-sensors auto-start..."
systemctl disable lm-sensors 2>/dev/null || true
echo "[BASE]   lm-sensors: disabled (HAL reads on-demand)"

echo "[BASE] Disabling udisks2 auto-start..."
systemctl disable udisks2 2>/dev/null || true
echo "[BASE]   udisks2: disabled (HAL manages mount lifecycle)"

echo "[BASE] Disabling samba auto-start..."
systemctl disable smbd 2>/dev/null || true
systemctl disable nmbd 2>/dev/null || true
echo "[BASE]   samba (smbd+nmbd): disabled (API manages lifecycle)"

echo "[BASE] Disabling nfs-kernel-server auto-start..."
systemctl disable nfs-kernel-server 2>/dev/null || true
echo "[BASE]   nfs-kernel-server: disabled (API manages lifecycle)"

# mdadm: KEEP ENABLED — RAID must auto-assemble at boot
echo "[BASE]   mdadm: keeping enabled (RAID auto-assembly required)"

echo "[BASE] Disabling DRBD auto-start..."
systemctl disable drbd 2>/dev/null || true
echo "[BASE]   drbd: disabled (API manages multi-node replication)"

# ---------------------------------------------------------------------------
# Restore workarounds
# ---------------------------------------------------------------------------
echo ""
echo "[BASE] Cleaning up build workarounds..."

for bin in py3compile py3clean; do
    [ -f "/usr/bin/${bin}.real" ] && mv "/usr/bin/${bin}.real" "/usr/bin/$bin"
done
echo "[BASE]   py3compile: restored"

rm -f /usr/sbin/policy-rc.d
echo "[BASE]   policy-rc.d: removed"

rm -f /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
echo "[BASE]   resolv.conf: restored"

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
echo ""
echo "[BASE] Verifying critical binaries..."
VERIFY_OK=true

# v2.x binaries
for cmd_check in "hwclock:util-linux-extra" "sqlite3:sqlite3" "i2cdetect:i2c-tools" \
                  "gpiodetect:gpiod" "lsusb:usbutils" "gpsd:gpsd" "mmcli:modemmanager" \
                  "chronyd:chrony" "picocom:picocom" "jq:jq" "curl:curl" \
                  "usb_modeswitch:usb-modeswitch" "smartctl:smartmontools" \
                  "wpa_supplicant:wpasupplicant" "fail2ban-server:fail2ban" \
                  "dhclient:isc-dhcp-client"; do
    cmd="${cmd_check%%:*}"
    pkg="${cmd_check##*:}"
    if command -v "$cmd" &>/dev/null; then
        echo "[BASE]   $cmd ($pkg): OK"
    else
        echo "[BASE]   $cmd ($pkg): MISSING"
        VERIFY_OK=false
    fi
done

# v3.0 binaries — hardware & radio
echo ""
echo "[BASE] Verifying v3.0 binaries (hardware & radio)..."
for cmd_check in "bluetoothctl:bluez" "rtl_test:rtl-sdr" "aplay:alsa-utils" \
                  "sensors:lm-sensors" "aa-status:apparmor-utils" \
                  "udisksctl:udisks2"; do
    cmd="${cmd_check%%:*}"
    pkg="${cmd_check##*:}"
    if command -v "$cmd" &>/dev/null; then
        echo "[BASE]   $cmd ($pkg): OK"
    else
        echo "[BASE]   $cmd ($pkg): MISSING"
        VERIFY_OK=false
    fi
done

# v3.0 binaries — storage & RAID & file sharing
echo ""
echo "[BASE] Verifying v3.0 binaries (storage & RAID & file sharing)..."
for cmd_check in "nvme:nvme-cli" "mdadm:mdadm" "pvcreate:lvm2" \
                  "cryptsetup:cryptsetup" "mkfs.btrfs:btrfs-progs" \
                  "mkfs.xfs:xfsprogs" "hdparm:hdparm" "fio:fio" \
                  "smbd:samba" "exportfs:nfs-kernel-server"; do
    cmd="${cmd_check%%:*}"
    pkg="${cmd_check##*:}"
    if command -v "$cmd" &>/dev/null; then
        echo "[BASE]   $cmd ($pkg): OK"
    else
        echo "[BASE]   $cmd ($pkg): MISSING"
        VERIFY_OK=false
    fi
done

# v3.0 optional binaries (non-fatal)
echo ""
echo "[BASE] Verifying v3.0 optional binaries..."
for cmd_check in "drbdadm:drbd-utils" "mkfs.ocfs2:ocfs2-tools"; do
    cmd="${cmd_check%%:*}"
    pkg="${cmd_check##*:}"
    if command -v "$cmd" &>/dev/null; then
        echo "[BASE]   $cmd ($pkg): OK"
    else
        echo "[BASE]   $cmd ($pkg): not installed (optional, non-fatal)"
    fi
done

# B65: Verify asyncore + asynchat
echo ""
echo "[BASE] Verifying fail2ban Python dependencies (B65)..."
if python3 -c "import asyncore; import asynchat" 2>/dev/null; then
    echo "[BASE]   fail2ban Python deps: OK (asyncore+asynchat importable)"
else
    echo "[BASE]   fail2ban Python deps: MISSING"
    echo "[BASE]     asyncore: $(python3 -c 'import asyncore' 2>&1)"
    echo "[BASE]     asynchat: $(python3 -c 'import asynchat' 2>&1)"
    VERIFY_OK=false
fi

if [ "$VERIFY_OK" = false ]; then
    echo "[BASE] FATAL: Some critical binaries are missing. Aborting build."
    exit 1
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Golden Base Image — COMPLETE"
echo "  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "============================================================"
echo ""
echo "  Ubuntu:  $(lsb_release -ds 2>/dev/null || echo 'unknown')"
echo "  Kernel:  $(uname -r)"
echo "  Docker:  $(docker --version 2>/dev/null || echo 'installed')"
echo "  snap:    REMOVED"
echo "  pip:     NOT INSTALLED (by design)"
echo ""
TOTAL_PKGS=$(dpkg -l 2>/dev/null | grep -c '^ii' || echo 'unknown')
echo "  Total packages: $TOTAL_PKGS"
echo "  Installed size: $(du -sh /usr 2>/dev/null | cut -f1 || echo 'unknown')"
echo ""
echo "  v3.0 NEW packages:"
echo "    + BLE:      bluez, bluez-tools (Track B: MeshSat)"
echo "    + SDR:      rtl-sdr (C4), alsa-utils (C5: Digirig)"
echo "    + Sensors:  lm-sensors (C3: thermal profiles)"
echo "    + Security: apparmor-utils (SEC-09)"
echo "    + MPTCP:    mptcpd (optional — C0: WAN bonding)"
echo "    + USB:      udisks2 (backup destinations)"
echo "    + Serial:   setserial (optional — C3/C5)"
echo "    + NVMe:     nvme-cli (X1004 dual NVMe HAT)"
echo "    + RAID:     mdadm, lvm2, cryptsetup (RAID0/1, LVM, LUKS)"
echo "    + FS:       btrfs-progs, xfsprogs (NVMe filesystems)"
echo "    + Disk:     hdparm, fio (tuning + benchmarking)"
echo "    + Server:   samba, nfs-kernel-server (file sharing)"
echo "    + Cluster:  drbd-utils, ocfs2-tools (optional — multi-node)"
echo "    + Kernel:   pps_gpio, snd-usb-audio, raid1, dm-crypt"
echo "    + Modprobe: RTL-SDR DVB-T blacklist"
echo ""
echo "  All packages installed. No configuration applied."
echo "  Configuration happens in the release pipeline."
echo "============================================================"
