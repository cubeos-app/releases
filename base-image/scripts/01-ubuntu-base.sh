#!/bin/bash
# =============================================================================
# 01-ubuntu-base.sh — Golden base image: package installation
# =============================================================================
# Takes stock Ubuntu 24.04.3 Server for Raspberry Pi and installs everything
# CubeOS needs. This script does NOT configure anything — it only installs
# packages and removes bloat. Configuration is done by the release pipeline.
#
# After this script:
#   - snap is removed (saves ~150MB RAM + disk)
#   - Docker CE is installed from Docker's official repo
#   - All system packages are installed (hostapd, dnsmasq, fail2ban, etc.)
#   - Ubuntu is trimmed for headless server use
#
# Run frequency: Monthly, or when the package list changes.
# Run environment: QEMU ARM64 emulation (packer-builder-arm)
# Expected time: ~15-20 minutes under QEMU
# =============================================================================
set -euo pipefail

echo "============================================================"
echo "  CubeOS Golden Base Image — Ubuntu Package Installation"
echo "  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "============================================================"
echo ""

# ---------------------------------------------------------------------------
# QEMU py3compile workaround
# ---------------------------------------------------------------------------
# Under QEMU user-mode emulation, py3compile can SIGSEGV during package
# installs. Replace with a no-op to prevent build failures.
# This is safe because we're building an image, not running Python apps.
echo "[BASE] Installing QEMU py3compile workaround..."

if [ -f /usr/bin/py3compile ]; then
    mv /usr/bin/py3compile /usr/bin/py3compile.real
    cat > /usr/bin/py3compile << 'WRAPPER'
#!/bin/sh
# QEMU workaround: py3compile crashes under aarch64 emulation.
# Replaced during image build. Restored after package installation.
exit 0
WRAPPER
    chmod +x /usr/bin/py3compile
    echo "[BASE]   py3compile wrapped (QEMU workaround active)"
fi

if [ -f /usr/bin/py3clean ]; then
    mv /usr/bin/py3clean /usr/bin/py3clean.real
    cat > /usr/bin/py3clean << 'WRAPPER'
#!/bin/sh
exit 0
WRAPPER
    chmod +x /usr/bin/py3clean
    echo "[BASE]   py3clean wrapped (QEMU workaround active)"
fi

# ---------------------------------------------------------------------------
# Remove snap (saves ~150MB RAM, significant disk space, faster boot)
# ---------------------------------------------------------------------------
echo "[BASE] Removing snap..."

# Stop snapd services
systemctl stop snapd.service snapd.socket snapd.seeded.service 2>/dev/null || true
systemctl disable snapd.service snapd.socket snapd.seeded.service 2>/dev/null || true

# Remove all installed snaps
if command -v snap &>/dev/null; then
    for snap_name in $(snap list 2>/dev/null | awk 'NR>1 {print $1}' | grep -v "^core" | grep -v "^snapd"); do
        snap remove --purge "$snap_name" 2>/dev/null || true
    done
    snap remove --purge snapd 2>/dev/null || true
fi

# Purge snapd package
apt-get purge -y -qq snapd squashfs-tools 2>/dev/null || true
apt-get autoremove -y -qq 2>/dev/null || true

# Prevent snapd from being reinstalled
cat > /etc/apt/preferences.d/no-snapd.pref << 'NOSNAP'
Package: snapd
Pin: release *
Pin-Priority: -10
NOSNAP

rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd
echo "[BASE]   snap removed and blocked from reinstall"

# ---------------------------------------------------------------------------
# Remove other Ubuntu bloat not needed for headless server
# ---------------------------------------------------------------------------
echo "[BASE] Removing unnecessary packages..."

apt-get purge -y -qq \
    ubuntu-advantage-tools \
    landscape-common \
    popularity-contest \
    unattended-upgrades \
    update-notifier-common \
    motd-news-config \
    2>/dev/null || true

apt-get autoremove -y -qq 2>/dev/null || true
echo "[BASE]   Bloat packages removed"

# ---------------------------------------------------------------------------
# System update
# ---------------------------------------------------------------------------
echo "[BASE] Updating package lists..."
apt-get update -qq

echo "[BASE] Upgrading existing packages..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"
echo "[BASE]   System upgraded"

# ---------------------------------------------------------------------------
# Install system packages
# ---------------------------------------------------------------------------
echo "[BASE] Installing system packages..."

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    \
    `# --- Core system ---` \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    \
    `# --- Networking ---` \
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
    nmap \
    \
    `# --- Security ---` \
    fail2ban \
    ufw \
    openssh-server \
    \
    `# --- Hardware / Pi ---` \
    i2c-tools \
    watchdog \
    libraspberrypi-bin \
    linux-firmware \
    \
    `# --- Storage ---` \
    cifs-utils \
    nfs-common \
    parted \
    e2fsprogs \
    dosfstools \
    \
    `# --- Monitoring ---` \
    htop \
    iotop \
    sysstat \
    lsof \
    strace \
    \
    `# --- Utils ---` \
    jq \
    git \
    vim-tiny \
    tmux \
    wget \
    rsync \
    zip \
    unzip \
    xz-utils \
    pigz \
    \
    `# --- Cloud-init (for Raspberry Pi Imager support) ---` \
    cloud-init \
    \
    `# --- Python (for system scripts) ---` \
    python3 \
    python3-pip \
    \
    2>&1 | tail -5

echo "[BASE]   System packages installed"

# ---------------------------------------------------------------------------
# Install Docker CE from official Docker repository
# ---------------------------------------------------------------------------
echo "[BASE] Installing Docker CE..."

# Add Docker's GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker apt repository
echo \
  "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

apt-get update -qq

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin \
    2>&1 | tail -3

echo "[BASE]   Docker installed: $(docker --version 2>/dev/null || echo 'version check skipped')"

# ---------------------------------------------------------------------------
# Kernel modules and sysctl for networking
# ---------------------------------------------------------------------------
echo "[BASE] Configuring kernel parameters..."

# Enable IP forwarding (required for NAT/AP mode)
cat > /etc/sysctl.d/99-cubeos.conf << 'SYSCTL'
# CubeOS networking requirements
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Performance tuning for Docker overlay networks
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 1024

# Disable IPv6 autoconfig (we manage this ourselves)
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.default.autoconf = 0
SYSCTL

# Ensure required kernel modules load on boot
cat > /etc/modules-load.d/cubeos.conf << 'MODULES'
# CubeOS required kernel modules
overlay
br_netfilter
i2c-dev
MODULES

echo "[BASE]   Kernel parameters configured"

# ---------------------------------------------------------------------------
# Restore py3compile
# ---------------------------------------------------------------------------
echo "[BASE] Restoring py3compile..."
if [ -f /usr/bin/py3compile.real ]; then
    mv /usr/bin/py3compile.real /usr/bin/py3compile
fi
if [ -f /usr/bin/py3clean.real ]; then
    mv /usr/bin/py3clean.real /usr/bin/py3clean
fi
echo "[BASE]   py3compile restored"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Golden Base Image — Package Installation Complete"
echo "============================================================"
echo ""
echo "  Ubuntu:     $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)"
echo "  Kernel:     $(uname -r)"
echo "  Docker:     $(docker --version 2>/dev/null || echo 'installed')"
echo "  snap:       REMOVED"
echo ""
echo "  This base image contains all packages. No configuration"
echo "  has been applied — that happens in the release pipeline."
echo "============================================================"
