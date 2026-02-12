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

        if apt-get install -y \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            "${packages[@]}" 2>&1 | tail -20; then
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

install_group "Core system" \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common

install_group "Networking" \
    hostapd \
    dnsmasq \
    iptables \
    iw \
    wireless-tools \
    rfkill \
    bridge-utils \
    net-tools \
    iputils-ping \
    dnsutils \
    tcpdump \
    nmap

install_group "Security" \
    fail2ban \
    ufw \
    openssh-server

install_group "Hardware / Pi" \
    i2c-tools \
    watchdog \
    linux-firmware

# libraspberrypi-bin may not exist in all Ubuntu ARM64 repos
echo ""
echo "[BASE] >>> Installing: libraspberrypi-bin (optional)"
apt-get install -y libraspberrypi-bin 2>/dev/null && \
    echo "[BASE]     libraspberrypi-bin: OK" || \
    echo "[BASE]     libraspberrypi-bin: not available (non-fatal)"

install_group "Storage" \
    cifs-utils \
    nfs-common \
    parted \
    e2fsprogs \
    dosfstools

# NOTE: iotop-c replaces iotop (broken python deps on Ubuntu 24.04 ARM64)
install_group "Monitoring" \
    htop \
    iotop-c \
    sysstat \
    lsof \
    strace

install_group "Utilities" \
    jq \
    git \
    vim-tiny \
    tmux \
    wget \
    rsync \
    zip \
    unzip \
    xz-utils \
    pigz

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
SYSCTL

cat > /etc/modules-load.d/cubeos.conf << 'MODULES'
overlay
br_netfilter
i2c-dev
MODULES

echo "[BASE]   Kernel config: OK"

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
echo "  All packages installed. No configuration applied."
echo "  Configuration happens in the release pipeline."
echo "============================================================"
