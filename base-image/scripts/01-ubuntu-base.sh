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
# Expected time: ~20-25 minutes under QEMU
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
# Upgrade changes dependency versions. Without this refresh, install fails
# with "held broken packages" because apt resolves against stale metadata.
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
# - python3-pyasyncore: exists in apt (provides asyncore)
# - python3-pyasynchat: does NOT exist in Ubuntu 24.04 apt repos
#   Must install via pip. fail2ban does NOT vendor asynchat internally —
#   it imports asynchat at startup and crashes with "No module named 'asynchat'"
#   if missing. This bug persisted through Alpha.22, .23, and .24.
echo "[BASE] Installing fail2ban Python 3.12 dependencies (B65)..."
apt-get install -y --no-install-recommends python3-pyasyncore
echo "[BASE]   python3-pyasyncore: installed (apt)"
pip3 install pyasynchat --break-system-packages 2>&1 | tail -3
echo "[BASE]   pyasynchat: installed (pip — not available in apt)"

# Verify BOTH asyncore AND asynchat are importable
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

# libraspberrypi-bin may not exist in all Ubuntu ARM64 repos
install_optional "libraspberrypi-bin" "libraspberrypi-bin (vcgencmd)"

# ===== GROUP 5: Cellular / Modem (MuleCube expedition) =====
install_group "Cellular / Modem" \
    modemmanager \
    libqmi-utils \
    libmbim-utils \
    usb-modeswitch \
    usb-modeswitch-data

# ===== GROUP 6: GPS & Time =====
# NOTE: gpsd-clients REMOVED — it pulls in python3-gps, python3-cairo,
# python3-gi, python3-serial and GTK deps for xgps/xgpsspeed graphical tools.
# These add ~40 min to QEMU ARM64 builds. HAL talks to gpsd via socket
# protocol directly, no Python CLI tools needed.
install_group "GPS / Time" \
    gpsd \
    chrony

# ===== GROUP 7: Storage & Filesystems =====
install_group "Storage" \
    cifs-utils \
    smbclient \
    nfs-common \
    parted \
    e2fsprogs \
    dosfstools \
    ntfs-3g \
    smartmontools

# exfatprogs is the modern kernel-native exFAT toolset (Ubuntu 24.04+)
install_optional "exfatprogs" "exfatprogs (exFAT support)"

# ===== GROUP 8: Monitoring =====
# NOTE: iotop-c replaces iotop (broken python deps on Ubuntu 24.04 ARM64)
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

# B62: Configure ZRAM for 100% of RAM (default is 14%, way too low)
echo "[BASE] Configuring ZRAM (100% RAM, lz4)..."
cat > /etc/default/zramswap <<'ZRAM'
ALGO=lz4
PERCENT=100
ZRAM
echo "[BASE]   ZRAM: 100% of RAM with lz4 compression"

# ===== GROUP 11: Cloud-init =====
install_group "Cloud-init" \
    cloud-init

# NOTE: python3-pip intentionally NOT installed.
# On Ubuntu 24.04 it causes dependency conflicts under QEMU.
install_group "Python (no pip)" \
    python3

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
# These packages have no strong reverse-dependencies, so apt marks them as
# "auto-installed" and autoremove removes them. apt-mark manual prevents this.
# This is the DEFINITIVE fix for the 5-alpha hwclock saga (B03/B44).
# ---------------------------------------------------------------------------
echo ""
echo "[BASE] Protecting critical packages from autoremove..."
PROTECTED_PACKAGES=(
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
    python3-pyasyncore  # B65: fail2ban asyncore compat (Python 3.12)
    wpasupplicant       # B52: SERVER_WIFI mode needs wpa_supplicant on host
    networkd-dispatcher # B52: auto eth0 carrier detection hooks
)
for pkg in "${PROTECTED_PACKAGES[@]}"; do
    apt-mark manual "$pkg" 2>/dev/null || true
done
echo "[BASE]   Protected ${#PROTECTED_PACKAGES[@]} packages from autoremove"

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
SYSCTL

cat > /etc/modules-load.d/cubeos.conf << 'MODULES'
overlay
br_netfilter
i2c-dev
MODULES

echo "[BASE]   Kernel config: OK"

# ---------------------------------------------------------------------------
# Chrony: disable default NTP pools (offline-first, GPS/PPS later)
# ---------------------------------------------------------------------------
# On first boot the user has no internet. Default pool.ntp.org servers
# cause log spam. Chrony will be configured by the setup wizard.
# ---------------------------------------------------------------------------
echo "[BASE] Configuring chrony for offline-first..."
if [ -f /etc/chrony/chrony.conf ]; then
    # Comment out default pool/server lines
    sed -i 's/^pool /#pool /' /etc/chrony/chrony.conf
    sed -i 's/^server /#server /' /etc/chrony/chrony.conf
    # Add local reference clock (stratum 10 = unsynchronized but usable)
    echo "" >> /etc/chrony/chrony.conf
    echo "# CubeOS: local clock fallback for air-gapped operation" >> /etc/chrony/chrony.conf
    echo "local stratum 10" >> /etc/chrony/chrony.conf
    echo "# Allow subnet clients to sync from us" >> /etc/chrony/chrony.conf
    echo "allow 10.42.24.0/24" >> /etc/chrony/chrony.conf
fi
# Disable timesyncd (chrony replaces it)
systemctl disable systemd-timesyncd 2>/dev/null || true
echo "[BASE]   chrony: configured for offline-first + local stratum 10"

# ---------------------------------------------------------------------------
# gpsd: disable auto-start (HAL manages GPS lifecycle)
# ---------------------------------------------------------------------------
echo "[BASE] Disabling gpsd auto-start..."
systemctl disable gpsd 2>/dev/null || true
systemctl disable gpsd.socket 2>/dev/null || true
echo "[BASE]   gpsd: disabled (HAL manages lifecycle)"

# ---------------------------------------------------------------------------
# ModemManager: disable auto-start (HAL manages modem lifecycle)
# ---------------------------------------------------------------------------
echo "[BASE] Disabling ModemManager auto-start..."
systemctl disable ModemManager 2>/dev/null || true
echo "[BASE]   ModemManager: disabled (HAL manages lifecycle)"

# ---------------------------------------------------------------------------
# OpenVPN: disable auto-start (API/HAL manage VPN lifecycle)
# ---------------------------------------------------------------------------
echo "[BASE] Disabling OpenVPN auto-start..."
systemctl disable openvpn 2>/dev/null || true
systemctl disable 'openvpn@*' 2>/dev/null || true
echo "[BASE]   openvpn: disabled (API manages lifecycle)"

# ---------------------------------------------------------------------------
# Tor: disable auto-start (API/HAL manage Tor lifecycle)
# ---------------------------------------------------------------------------
echo "[BASE] Disabling Tor auto-start..."
systemctl disable tor 2>/dev/null || true
echo "[BASE]   tor: disabled (API manages lifecycle)"

# ---------------------------------------------------------------------------
# smartmontools: disable auto-start (SD cards don't support SMART)
# ---------------------------------------------------------------------------
# smartd fails on boot with "No devices found to scan" because SD cards
# and eMMC don't support SMART. The package is installed for users who
# attach USB/SATA drives via HAT, but the daemon shouldn't auto-start.
# ---------------------------------------------------------------------------
echo "[BASE] Disabling smartmontools auto-start..."
systemctl disable smartd 2>/dev/null || true
systemctl disable smartmontools 2>/dev/null || true
echo "[BASE]   smartd: disabled (enable manually for external drives)"

# ---------------------------------------------------------------------------
# avahi-daemon: disable for now (boot scripts enable if needed)
# ---------------------------------------------------------------------------
echo "[BASE] Disabling avahi-daemon auto-start..."
systemctl disable avahi-daemon 2>/dev/null || true
echo "[BASE]   avahi-daemon: disabled (enables on demand)"

# ---------------------------------------------------------------------------
# wpa_supplicant: disable but DO NOT MASK (B52 SERVER_WIFI needs it)
# ---------------------------------------------------------------------------
# B52 SERVER_WIFI mode uses netplan wifis: section which triggers
# wpa_supplicant via networkctl reconfigure. If masked, SERVER_WIFI breaks.
# The 02-networking.sh release script also disables it, but we set the
# correct state here to be explicit.
# ---------------------------------------------------------------------------
echo "[BASE] Disabling wpa_supplicant (NOT masked — B52 SERVER_WIFI needs it)..."
systemctl disable wpa_supplicant 2>/dev/null || true
# Ensure it's NOT masked (undo any previous masking)
systemctl unmask wpa_supplicant 2>/dev/null || true
echo "[BASE]   wpa_supplicant: disabled (unmask verified)"

# ---------------------------------------------------------------------------
# networkd-dispatcher: enable (B52 auto eth0 carrier detection)
# ---------------------------------------------------------------------------
# B52 installs hook scripts in /etc/networkd-dispatcher/ that auto-enable
# NAT when ethernet is plugged in OFFLINE mode. The service must be active
# for these hooks to fire.
# ---------------------------------------------------------------------------
echo "[BASE] Enabling networkd-dispatcher..."
systemctl enable networkd-dispatcher 2>/dev/null || true
echo "[BASE]   networkd-dispatcher: enabled"

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

# B65: Verify both asyncore AND asynchat are importable (fail2ban needs both)
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
echo "  NEW in v2.0:"
echo "    + GPS:      gpsd, chrony, pps-tools"
echo "    + Cellular: modemmanager, libqmi, libmbim, usb-modeswitch"
echo "    + Pi HW:    gpiod, v4l-utils, libraspberrypi-bin"
echo "    + Storage:  ntfs-3g, exfatprogs, smartmontools, smbclient"
echo "    + Network:  wireguard-tools, ethtool, avahi-daemon"
echo "    + VPN:      openvpn, tor (client daemons)"
echo "    + B52 net:  wpasupplicant (SERVER_WIFI), networkd-dispatcher (auto-detect)"
echo "    + B62 mem:  ZRAM configured at 100% RAM with lz4 (was 14% default)"
echo "    + B65 sec:  fail2ban Python 3.12 asynchat/asyncore backports"
echo "    + B87 net:  isc-dhcp-client (HAL DHCP endpoint, Android tethering)"
echo "    + Tools:    sqlite3, picocom, plocate, nano, zram-tools"
echo ""
echo "  REMOVED in v2.2:"
echo "    - gpsd-clients (python3-gps + GTK deps — 40min QEMU, HAL uses socket)"
echo ""
echo "  All packages installed. No configuration applied."
echo "  Configuration happens in the release pipeline."
echo "============================================================"
