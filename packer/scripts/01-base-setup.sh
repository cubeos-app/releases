#!/bin/bash
# =============================================================================
# 01-base-setup.sh — Base system configuration
# =============================================================================
# Runs inside QEMU chroot during image build.
# Installs packages, configures kernel, sysctl, swap, SSH, journald.
# =============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "=== [01] Base System Setup ==="

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
echo "[01] Installing system packages..."
apt-get update -qq
apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -y -qq

apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y -qq --no-install-recommends \
    jq \
    curl \
    wget \
    ca-certificates \
    gnupg \
    lsb-release \
    sudo \
    cifs-utils \
    nfs-common \
    parted \
    e2fsprogs \
    dosfstools \
    watchdog \
    fail2ban \
    cloud-init \
    ufw \
    hostapd \
    dnsmasq \
    iptables \
    nftables \
    bridge-utils \
    wireless-tools \
    wpasupplicant \
    net-tools \
    iw \
    rfkill \
    avahi-daemon \
    libnss-mdns \
    xz-utils \
    unzip \
    htop \
    vim-tiny \
    usbutils \
    i2c-tools \
    python3-minimal

echo "[01] Packages installed."

# ---------------------------------------------------------------------------
# CubeOS user
# ---------------------------------------------------------------------------
echo "[01] Creating cubeos user..."
if ! id cubeos &>/dev/null; then
    useradd -m -s /bin/bash -G sudo,docker,adm,dialout,video,plugdev,netdev,gpio,spi,i2c cubeos
fi

# Lock password login — SSH key only after wizard sets it up
passwd -l cubeos

# Passwordless sudo for cubeos user
echo "cubeos ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/cubeos
chmod 0440 /etc/sudoers.d/cubeos

# ---------------------------------------------------------------------------
# Kernel command line — cgroups for Docker
# ---------------------------------------------------------------------------
echo "[01] Configuring kernel command line..."
CMDLINE="/boot/firmware/cmdline.txt"
if [ -f "$CMDLINE" ]; then
    # Add cgroup settings if not already present
    if ! grep -q "cgroup_enable=memory" "$CMDLINE"; then
        sed -i 's/$/ cgroup_enable=memory cgroup_memory=1/' "$CMDLINE"
    fi
    # Reduce kernel verbosity
    if ! grep -q "quiet" "$CMDLINE"; then
        sed -i 's/$/ quiet/' "$CMDLINE"
    fi
fi

# ---------------------------------------------------------------------------
# Sysctl — networking, watchdog, memory
# ---------------------------------------------------------------------------
echo "[01] Writing sysctl configuration..."
cat > /etc/sysctl.d/99-cubeos.conf << 'SYSCTL'
# =============================================================================
# CubeOS Kernel Parameters
# =============================================================================

# --- IP Forwarding (required for AP + NAT) ---
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# --- Network hardening ---
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1

# --- Memory management (low-RAM optimization) ---
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.overcommit_memory = 1

# --- Watchdog ---
kernel.panic = 10
kernel.panic_on_oops = 1

# --- File descriptor limits ---
fs.file-max = 65536
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
SYSCTL

# ---------------------------------------------------------------------------
# Swap — disable (SD card wear protection)
# ---------------------------------------------------------------------------
echo "[01] Disabling swap..."
systemctl disable dphys-swapfile 2>/dev/null || true
systemctl mask dphys-swapfile 2>/dev/null || true
# Remove swap file if it exists
rm -f /var/swap

# ---------------------------------------------------------------------------
# SSH hardening
# ---------------------------------------------------------------------------
echo "[01] Hardening SSH..."
mkdir -p /etc/ssh/sshd_config.d

cat > /etc/ssh/sshd_config.d/99-cubeos.conf << 'SSHD'
# CubeOS SSH Hardening
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
SSHD

# Create authorized_keys skeleton for cubeos user
mkdir -p /home/cubeos/.ssh
chmod 700 /home/cubeos/.ssh
touch /home/cubeos/.ssh/authorized_keys
chmod 600 /home/cubeos/.ssh/authorized_keys
chown -R cubeos:cubeos /home/cubeos/.ssh

# ---------------------------------------------------------------------------
# Journald — write to volatile storage (RAM, protect SD card)
# ---------------------------------------------------------------------------
echo "[01] Configuring journald for volatile storage..."
mkdir -p /etc/systemd/journald.conf.d

cat > /etc/systemd/journald.conf.d/99-cubeos.conf << 'JOURNALD'
[Journal]
Storage=volatile
RuntimeMaxUse=50M
RuntimeMaxFileSize=10M
ForwardToSyslog=no
MaxRetentionSec=2day
JOURNALD

# ---------------------------------------------------------------------------
# Watchdog — hardware watchdog (Pi 4/5 BCM2835 WDT)
# ---------------------------------------------------------------------------
echo "[01] Configuring hardware watchdog..."
cat > /etc/watchdog.conf << 'WATCHDOG'
# CubeOS Hardware Watchdog
watchdog-device = /dev/watchdog
watchdog-timeout = 15
max-load-1 = 24
interval = 10
WATCHDOG

mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-watchdog.conf << 'SYSTEMD_WDT'
[Manager]
RuntimeWatchdogSec=15
RebootWatchdogSec=10min
SYSTEMD_WDT

systemctl enable watchdog 2>/dev/null || true

# ---------------------------------------------------------------------------
# Fail2ban — basic config
# ---------------------------------------------------------------------------
echo "[01] Configuring fail2ban..."
cat > /etc/fail2ban/jail.d/cubeos.conf << 'FAIL2BAN'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
findtime = 600
FAIL2BAN

systemctl enable fail2ban 2>/dev/null || true

# ---------------------------------------------------------------------------
# Hostname
# ---------------------------------------------------------------------------
echo "cubeos" > /etc/hostname
sed -i 's/127.0.1.1.*/127.0.1.1\tcubeos/' /etc/hosts

# Add cubeos.cube to /etc/hosts
if ! grep -q "cubeos.cube" /etc/hosts; then
    echo "10.42.24.1  cubeos.cube cubeos" >> /etc/hosts
fi

# ---------------------------------------------------------------------------
# Locale — ensure en_US.UTF-8
# ---------------------------------------------------------------------------
echo "[01] Setting locale..."
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8 || true

echo "[01] Base setup complete."
