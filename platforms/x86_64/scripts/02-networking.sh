#!/bin/bash
# =============================================================================
# 02-networking.sh — Network stack configuration (x86_64)
# =============================================================================
# Configures networking for x86_64 CubeOS systems (PCs, NUCs, VMs).
#
# Key differences from Raspberry Pi:
#   - NO hostapd / WiFi AP (no wlan0 — wired Ethernet only)
#   - NO rfkill, cfg80211, or USB WiFi dongle naming
#   - Netplan matches all en*/eth* interfaces via wildcard
#   - Same: systemd-resolved stub disabled (Pi-hole needs port 53)
#   - Same: IP forwarding enabled (container NAT)
#   - Same: SSH hardening, cubeos user creation
#
# x86 systems use predictable interface names (ens*, enp*, eno*).
# The netplan config matches all Ethernet interfaces via "en*" + "eth*".
# =============================================================================
set -euo pipefail

echo "=== [02] Network Configuration (x86_64) ==="

# ---------------------------------------------------------------------------
# Disable services that conflict with our stack
# ---------------------------------------------------------------------------
echo "[02] Disabling conflicting services..."

# dnsmasq — Pi-hole replaces this for DNS/DHCP
systemctl disable dnsmasq 2>/dev/null || true
systemctl mask dnsmasq 2>/dev/null || true

# NetworkManager — use systemd-networkd instead (lighter, server-appropriate)
systemctl disable NetworkManager 2>/dev/null || true
systemctl mask NetworkManager 2>/dev/null || true
systemctl enable systemd-networkd 2>/dev/null || true

echo "[02]   Conflicting services disabled"

# ---------------------------------------------------------------------------
# Netplan — DHCP on all detected Ethernet interfaces
# ---------------------------------------------------------------------------
# x86 uses predictable names: ens* (virtio/hotplug), enp* (PCI), eno* (onboard).
# We match them all with wildcards. No wlan0 on x86 servers.
# ---------------------------------------------------------------------------
echo "[02] Configuring Netplan..."

# Remove any existing Ubuntu default netplan configs
rm -f /etc/netplan/50-cloud-init.yaml
rm -f /etc/netplan/99-default.yaml
rm -f /etc/netplan/00-installer-config.yaml

cat > /etc/netplan/01-cubeos.yaml << 'NETPLAN'
# =============================================================================
# CubeOS Network Configuration — x86_64
# =============================================================================
# DHCP on all Ethernet interfaces. No WiFi AP on x86 servers.
# DNS override: use Pi-hole (127.0.0.1) instead of upstream DHCP-provided DNS.

network:
  version: 2
  renderer: networkd

  ethernets:
    # Match all predictable-name interfaces (ens*, enp*, eno*)
    all-en:
      match:
        name: "en*"
      dhcp4: true
      dhcp4-overrides:
        use-dns: false
      nameservers:
        addresses: [127.0.0.1]
        search: [cubeos.cube]

    # Match legacy-name interfaces (eth0, eth1, etc.)
    all-eth:
      match:
        name: "eth*"
      dhcp4: true
      dhcp4-overrides:
        use-dns: false
      nameservers:
        addresses: [127.0.0.1]
        search: [cubeos.cube]
NETPLAN

chmod 600 /etc/netplan/01-cubeos.yaml
echo "[02]   Netplan configured (DHCP on all Ethernet, DNS=127.0.0.1)"

# ---------------------------------------------------------------------------
# systemd-resolved — disable stub listener + point to Pi-hole
# ---------------------------------------------------------------------------
# systemd-resolved listens on 127.0.0.53:53 which blocks Pi-hole's dnsmasq
# from binding to port 53 on all interfaces.
# ---------------------------------------------------------------------------
echo "[02] Configuring systemd-resolved..."
mkdir -p /etc/systemd/resolved.conf.d

cat > /etc/systemd/resolved.conf.d/cubeos.conf << 'RESOLVED'
# CubeOS: Disable stub listener (Pi-hole needs port 53) + use Pi-hole for DNS
[Resolve]
DNSStubListener=no
DNS=127.0.0.1
Domains=cubeos.cube
RESOLVED

# Point /etc/resolv.conf to the real resolved output (not the stub)
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || true

echo "[02]   systemd-resolved configured (stub disabled, DNS=127.0.0.1)"

# ---------------------------------------------------------------------------
# /etc/hosts fallback — hostname resolution before Pi-hole starts
# ---------------------------------------------------------------------------
echo "[02] Configuring /etc/hosts fallback..."
if ! grep -q "cubeos" /etc/hosts 2>/dev/null; then
    echo "127.0.1.1 cubeos" >> /etc/hosts
fi
echo "[02]   /etc/hosts fallback configured"

# ---------------------------------------------------------------------------
# sysctl — Enable IP forwarding (container NAT)
# ---------------------------------------------------------------------------
echo "[02] Configuring IP forwarding..."
cat > /etc/sysctl.d/99-cubeos-forwarding.conf << 'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
SYSCTL

echo "[02]   IP forwarding enabled"

# ---------------------------------------------------------------------------
# Disable cloud-init network config (we manage it via netplan)
# ---------------------------------------------------------------------------
echo "[02] Disabling cloud-init network config..."
mkdir -p /etc/cloud/cloud.cfg.d
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
echo "[02]   cloud-init network config disabled"

# ---------------------------------------------------------------------------
# cubeos user — ensure proper groups and password (matches Pi behavior)
# ---------------------------------------------------------------------------
echo "[02] Configuring cubeos user..."

# Create the i2c group if it doesn't exist (Pi compatibility — harmless on x86)
getent group i2c >/dev/null 2>&1 || groupadd -r i2c

if id cubeos &>/dev/null; then
    echo "[02]   cubeos user already exists"
else
    echo "[02]   Creating cubeos user..."
    useradd -m -s /bin/bash -G sudo,adm cubeos
fi

# Ensure all required groups (idempotent)
for grp in sudo docker adm i2c; do
    getent group "$grp" >/dev/null 2>&1 && usermod -aG "$grp" cubeos 2>/dev/null || true
done

# Set password directly
echo "cubeos:cubeos" | chpasswd
echo "[02]   cubeos password set via chpasswd"

# Ensure passwordless sudo
echo "cubeos ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/cubeos
chmod 440 /etc/sudoers.d/cubeos

# Ensure home directory exists with correct ownership
mkdir -p /home/cubeos
chown cubeos:cubeos /home/cubeos
chmod 750 /home/cubeos

# Remove lock_passwd flag if set
passwd -u cubeos 2>/dev/null || true

echo "[02]   cubeos user ready (groups: $(id -nG cubeos 2>/dev/null))"

# ---------------------------------------------------------------------------
# PAM: Remove deprecated pam_lastlog.so reference (Ubuntu 24.04)
# ---------------------------------------------------------------------------
if grep -q "pam_lastlog" /etc/pam.d/login 2>/dev/null; then
    sed -i '/pam_lastlog/d' /etc/pam.d/login
    echo "[02]   Removed deprecated pam_lastlog from /etc/pam.d/login"
fi

# ---------------------------------------------------------------------------
# Cloud-init — minimal config (autoinstall already handled user creation)
# ---------------------------------------------------------------------------
echo "[02] Configuring cloud-init..."
cat > /etc/cloud/cloud.cfg.d/99-cubeos.cfg << 'CLOUDINIT'
# CubeOS cloud-init config (x86_64)
# User already created by autoinstall + this script. Cloud-init is secondary.
datasource_list: [NoCloud, None]

network:
  config: disabled

preserve_hostname: false
hostname: cubeos

system_info:
  default_user:
    name: cubeos
    lock_passwd: false
    gecos: CubeOS Admin
    groups: [sudo, docker, adm, i2c]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash
CLOUDINIT

# Set hostname
echo "cubeos" > /etc/hostname
sed -i 's/127\.0\.1\.1.*/127.0.1.1\tcubeos/' /etc/hosts 2>/dev/null || true

echo "[02]   cloud-init configured"

# ---------------------------------------------------------------------------
# SSH — enable password authentication + hardening (same as Pi)
# ---------------------------------------------------------------------------
echo "[02] Enabling SSH password + pubkey authentication..."
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/01-cubeos.conf <<'SSHEOF'
PasswordAuthentication yes
PubkeyAuthentication yes
SSHEOF

rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf
echo "[02]   SSH password + pubkey auth enabled"

# SSH Hardening (same as Pi)
echo "[02] Applying SSH hardening..."
cat > /etc/ssh/sshd_config.d/99-cubeos-hardening.conf <<'SSHHARD'
# =============================================================================
# CubeOS SSH Hardening — same config as Raspberry Pi build
# =============================================================================
PermitRootLogin no
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 30

AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
GatewayPorts no
PermitUserEnvironment no
DisableForwarding yes

KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-512-cert-v01@openssh.com,rsa-sha2-256,rsa-sha2-256-cert-v01@openssh.com

LogLevel VERBOSE

ClientAliveInterval 300
ClientAliveCountMax 3

Banner none
SSHHARD

echo "[02]   SSH hardening applied"

# Prepare .ssh directory
mkdir -p /home/cubeos/.ssh
chmod 700 /home/cubeos/.ssh

# CI/CD deploy key (same as Pi)
cat > /home/cubeos/.ssh/authorized_keys << 'AUTH_KEYS'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEox5R6N6upResIpJg9gouLkSNvmAaoh3ocRPUP4sb/f cubeos-ci-deploy
AUTH_KEYS
chmod 600 /home/cubeos/.ssh/authorized_keys

chown -R cubeos:cubeos /home/cubeos/.ssh
echo "[02]   /home/cubeos/.ssh/ created with CI deploy key"

# ---------------------------------------------------------------------------
# Avahi / mDNS — cubeos.local discovery
# ---------------------------------------------------------------------------
echo "[02] Configuring avahi-daemon for mDNS (cubeos.local)..."
mkdir -p /etc/avahi
cat > /etc/avahi/avahi-daemon.conf << 'AVAHI_CONF'
[server]
host-name=cubeos
domain-name=local
use-ipv4=yes
use-ipv6=yes

[publish]
publish-addresses=yes
publish-hinfo=yes
publish-workstation=no
publish-domain=yes

[reflector]

[rlimits]
AVAHI_CONF

# x86: don't restrict to specific interfaces (no wlan0)
# Avahi disabled at boot — boot scripts start it when needed
systemctl disable avahi-daemon 2>/dev/null || true
echo "[02]   avahi-daemon configured (disabled at boot)"

echo "=== [02] x86_64 Network Configuration: DONE ==="
