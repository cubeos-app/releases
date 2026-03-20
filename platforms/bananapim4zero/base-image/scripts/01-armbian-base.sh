#!/bin/bash
# =============================================================================
# 01-armbian-base.sh — Golden base image: package installation (BPI-M4 Zero)
# =============================================================================
# Takes stock Armbian Noble minimal for BPI-M4 Zero (Allwinner H618) and
# installs everything CubeOS needs. This script does NOT configure anything —
# it only installs packages and removes bloat. Configuration is done by the
# release pipeline.
#
# Based on the Raspberry Pi golden base (01-ubuntu-base.sh v3.0) with:
#   - No Pi-specific packages (libraspberrypi-bin, gpiod, pps-tools)
#   - Armbian may ship with different defaults (NetworkManager, etc.)
#   - Same Docker, networking, storage, security packages
#
# Run environment: QEMU ARM64 emulation (packer-builder-arm)
# Expected time: ~25-30 minutes under QEMU
# =============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export TERM=dumb
export LANG=C.UTF-8

# ---------------------------------------------------------------------------
# Helper: install a group of packages with retry
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
echo "  CubeOS Golden Base Image — Armbian BPI-M4 Zero"
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
# Disable man-db auto-update (saves ~10 min under QEMU)
# ---------------------------------------------------------------------------
echo "[BASE] Disabling man-db auto-update..."
echo 'man-db man-db/auto-update boolean false' | debconf-set-selections
echo "[BASE]   man-db auto-update: disabled"

# ---------------------------------------------------------------------------
# Remove snap (Armbian minimal may not have it, but just in case)
# ---------------------------------------------------------------------------
echo ""
echo "[BASE] Removing snap (if present)..."

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
# System update
# ---------------------------------------------------------------------------
echo ""
echo "[BASE] ============================================"
echo "[BASE]  apt-get update (expect 3-5 min under QEMU)"
echo "[BASE]  Started: $(date -u +%H:%M:%S)"
echo "[BASE] ============================================"
apt-get update 2>&1 | grep -E "^(Hit|Get|Fetched|Reading)" || true
echo "[BASE] Finished: $(date -u +%H:%M:%S)"

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

echo ""
echo "[BASE] Refreshing package lists after upgrade..."
apt-get update 2>&1 | grep -E "^(Hit|Get|Fetched|Reading)" || true

echo "[BASE] Fixing any broken dependencies..."
apt-get install -f -y 2>/dev/null || true

# ---------------------------------------------------------------------------
# Install packages in groups
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
    avahi-utils \
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

# B65: fail2ban on Python 3.12+ needs asyncore AND asynchat
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
echo "[BASE]   pyasynchat: installed (tarball)"

if python3 -c "import asyncore; import asynchat; print('asyncore+asynchat: OK')" 2>&1; then
    echo "[BASE]   B65 verification: PASS"
else
    echo "[BASE]   FATAL: asyncore or asynchat not importable. fail2ban will crash."
    exit 1
fi

# ===== GROUP 4: Hardware (Armbian / H618) =====
# No Pi-specific packages (libraspberrypi-bin, gpiod, pps-tools).
# i2c-tools for UPS HAT / sensor access. util-linux-extra for hwclock.
install_group "Hardware / Armbian" \
    i2c-tools \
    util-linux-extra \
    linux-firmware \
    usbutils

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

# ===== GROUP 12: Bluetooth / BLE =====
install_group "Bluetooth / BLE" \
    bluez \
    bluez-tools

# ===== GROUP 13: SDR / Radio =====
install_group "SDR / Radio" \
    rtl-sdr \
    alsa-utils

# ===== GROUP 14: Sensors =====
install_group "Sensors" \
    lm-sensors

# ===== GROUP 15: Security Hardening =====
install_group "Security hardening" \
    apparmor-utils

# ===== GROUP 16: MPTCP (optional) =====
install_optional "mptcpd" "mptcpd (MPTCP path manager daemon)"

# ===== GROUP 17: USB Drive Management =====
install_group "USB drive management" \
    udisks2

# ===== GROUP 18: Serial Port Tools =====
install_optional "setserial" "setserial (serial port config)"

# ===== GROUP 19: File Sharing Server =====
install_group "File sharing server" \
    samba \
    nfs-kernel-server

# ===== GROUP 20: Advanced Storage / RAID / Encryption =====
install_group "Advanced storage" \
    lvm2 \
    cryptsetup \
    btrfs-progs \
    xfsprogs \
    hdparm \
    fio

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
# Protect critical packages from autoremove
# ---------------------------------------------------------------------------
echo ""
echo "[BASE] Protecting critical packages from autoremove..."
PROTECTED_PACKAGES=(
    util-linux-extra sqlite3 i2c-tools usbutils
    hostapd dnsmasq iw wireless-tools rfkill avahi-daemon avahi-utils
    modemmanager libqmi-utils libmbim-utils usb-modeswitch usb-modeswitch-data
    gpsd chrony openvpn tor smbclient plocate picocom
    smartmontools ethtool wireguard-tools zram-tools
    exfatprogs ntfs-3g bc wpasupplicant networkd-dispatcher
    fail2ban python3-pyasyncore isc-dhcp-client
    bluez bluez-tools rtl-sdr alsa-utils lm-sensors
    apparmor-utils udisks2
    nvme-cli mdadm lvm2 cryptsetup btrfs-progs xfsprogs hdparm fio
    samba nfs-kernel-server
)
for pkg in "${PROTECTED_PACKAGES[@]}"; do
    apt-mark manual "$pkg" 2>/dev/null || true
done
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
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 1024
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.default.autoconf = 0
kernel.printk = 3 4 1 3
SYSCTL

cat > /etc/modules-load.d/cubeos.conf << 'MODULES'
overlay
br_netfilter
i2c-dev
snd-usb-audio
raid1
dm-crypt
MODULES

echo "[BASE]   Kernel config: OK"

# ---------------------------------------------------------------------------
# RTL-SDR: Blacklist DVB-T kernel driver
# ---------------------------------------------------------------------------
echo "[BASE] Configuring RTL-SDR modprobe blacklist..."
cat > /etc/modprobe.d/cubeos-blacklist.conf << 'BLACKLIST'
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2830
BLACKLIST
echo "[BASE]   RTL-SDR blacklist: OK"

# ---------------------------------------------------------------------------
# Chrony: offline-first
# ---------------------------------------------------------------------------
echo "[BASE] Configuring chrony for offline-first..."
if [ -f /etc/chrony/chrony.conf ]; then
    sed -i 's/^pool /#pool /' /etc/chrony/chrony.conf
    sed -i 's/^server /#server /' /etc/chrony/chrony.conf
    echo "" >> /etc/chrony/chrony.conf
    echo "local stratum 10" >> /etc/chrony/chrony.conf
    echo "allow 10.42.24.0/24" >> /etc/chrony/chrony.conf
fi
systemctl disable systemd-timesyncd 2>/dev/null || true
echo "[BASE]   chrony: configured for offline-first"

# ---------------------------------------------------------------------------
# Disable services (HAL/API manage lifecycle)
# ---------------------------------------------------------------------------
echo "[BASE] Disabling auto-start for managed services..."
for svc in gpsd gpsd.socket ModemManager openvpn 'openvpn@*' tor \
           smartd smartmontools avahi-daemon wpa_supplicant \
           bluetooth lm-sensors udisks2 smbd nmbd nfs-kernel-server drbd; do
    systemctl disable "$svc" 2>/dev/null || true
done
# wpa_supplicant must be unmaskable for wifi_client mode
systemctl unmask wpa_supplicant 2>/dev/null || true
# networkd-dispatcher stays enabled
systemctl enable networkd-dispatcher 2>/dev/null || true
# mdadm stays enabled (RAID auto-assembly)
echo "[BASE]   Services configured"

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
                  "lsusb:usbutils" "gpsd:gpsd" "mmcli:modemmanager" \
                  "chronyd:chrony" "picocom:picocom" "jq:jq" "curl:curl" \
                  "hostapd:hostapd" "iw:iw" "rfkill:rfkill" \
                  "usb_modeswitch:usb-modeswitch" "smartctl:smartmontools" \
                  "wpa_supplicant:wpasupplicant" "fail2ban-server:fail2ban" \
                  "dhclient:isc-dhcp-client" \
                  "bluetoothctl:bluez" "rtl_test:rtl-sdr" "aplay:alsa-utils" \
                  "sensors:lm-sensors" "aa-status:apparmor-utils" \
                  "udisksctl:udisks2" \
                  "nvme:nvme-cli" "mdadm:mdadm" "pvcreate:lvm2" \
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

# Optional
for cmd_check in "drbdadm:drbd-utils" "mkfs.ocfs2:ocfs2-tools"; do
    cmd="${cmd_check%%:*}"
    pkg="${cmd_check##*:}"
    if command -v "$cmd" &>/dev/null; then
        echo "[BASE]   $cmd ($pkg): OK"
    else
        echo "[BASE]   $cmd ($pkg): not installed (optional)"
    fi
done

# B65 verification
if python3 -c "import asyncore; import asynchat" 2>/dev/null; then
    echo "[BASE]   fail2ban Python deps: OK"
else
    echo "[BASE]   fail2ban Python deps: MISSING"
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
echo "  Golden Base Image (Armbian BPI-M4 Zero) — COMPLETE"
echo "  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "============================================================"
echo ""
echo "  Armbian: $(cat /etc/armbian-release 2>/dev/null | grep VERSION= | cut -d= -f2 || echo 'unknown')"
echo "  Ubuntu:  $(lsb_release -ds 2>/dev/null || echo 'unknown')"
echo "  Kernel:  $(uname -r)"
echo "  Docker:  $(docker --version 2>/dev/null || echo 'installed')"
echo "  snap:    REMOVED"
echo ""
TOTAL_PKGS=$(dpkg -l 2>/dev/null | grep -c '^ii' || echo 'unknown')
echo "  Total packages: $TOTAL_PKGS"
echo "  Installed size: $(du -sh /usr 2>/dev/null | cut -f1 || echo 'unknown')"
echo ""
echo "  All packages installed. No configuration applied."
echo "  Configuration happens in the release pipeline."
echo "============================================================"
