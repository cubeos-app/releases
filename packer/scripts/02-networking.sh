#!/bin/bash
# =============================================================================
# 02-networking.sh — Network stack configuration (Ubuntu 24.04)
# =============================================================================
# Configures Netplan (static wlan0, DHCP eth0), hostapd template,
# iptables NAT rules, and cloud-init for Raspberry Pi Imager support.
#
# Ubuntu 24.04 uses Netplan + systemd-networkd (NOT dhcpcd like Pi OS).
# This matches the CubeOS production environment (nllei01mule01).
#
# ALPHA.7 CHANGES (from alpha.6):
#   - eth0: dhcp-identifier=mac, use-dns=false, nameserver=10.42.24.1
#     (prevents upstream DHCP from overriding Pi-hole as resolver)
#   - systemd-resolved: DNS=127.0.0.1, Domains=cubeos.cube
#     (host can resolve *.cubeos.cube via Pi-hole)
#   - /etc/hosts fallback for hostname resolution before Pi-hole starts
#
# CRITICAL DESIGN DECISIONS:
#   - wlan0 is under 'ethernets' (NOT 'wifis') because hostapd manages it
#     as an AP interface. If placed under 'wifis', Netplan spawns
#     wpa_supplicant which fights hostapd for control of the interface.
#   - systemd-resolved stub listener is disabled to prevent port 53
#     conflict with Pi-hole's dnsmasq.
#   - IP forwarding is enabled persistently via sysctl for NAT.
# =============================================================================
set -euo pipefail

echo "=== [02] Network Configuration (Ubuntu) ==="

# ---------------------------------------------------------------------------
# Disable services that conflict with our stack
# ---------------------------------------------------------------------------
echo "[02] Disabling conflicting services..."

# hostapd — unmask but do NOT enable. Boot scripts manage hostapd via
# configure_wifi_ap() in cubeos-boot-lib.sh. The previous systemd drop-in
# (cubeos-after-init.conf) created a circular dependency causing deadlocks (B54).
systemctl unmask hostapd 2>/dev/null || true
systemctl disable hostapd 2>/dev/null || true
echo "[02]   hostapd: disabled at boot (boot scripts manage startup)"

# dnsmasq — Pi-hole replaces this for DNS/DHCP
systemctl disable dnsmasq 2>/dev/null || true
systemctl mask dnsmasq 2>/dev/null || true

# wpa_supplicant on wlan0 — conflicts with hostapd AP mode
systemctl disable wpa_supplicant 2>/dev/null || true

# NetworkManager — use systemd-networkd instead (lighter, server-appropriate)
systemctl disable NetworkManager 2>/dev/null || true
systemctl mask NetworkManager 2>/dev/null || true
systemctl enable systemd-networkd 2>/dev/null || true

echo "[02]   Conflicting services disabled"

# ---------------------------------------------------------------------------
# Netplan — static IP for wlan0 (AP), DHCP for eth0 (upstream)
# ---------------------------------------------------------------------------
# IMPORTANT: wlan0 MUST be under 'ethernets', NOT 'wifis'.
# When under 'wifis', Netplan spawns wpa_supplicant to manage the interface,
# which fights with hostapd for control. Under 'ethernets', Netplan only
# assigns the IP address and leaves the radio management to hostapd.
# ---------------------------------------------------------------------------
echo "[02] Configuring Netplan..."

# Remove any existing Ubuntu default netplan configs
rm -f /etc/netplan/50-cloud-init.yaml
rm -f /etc/netplan/99-default.yaml

cat > /etc/netplan/01-cubeos.yaml << 'NETPLAN'
# =============================================================================
# CubeOS Network Configuration — Default: OFFLINE Mode
# =============================================================================
# Default netplan baked into the image. Matches OFFLINE mode where wlan0
# serves the 10.42.24.0/24 subnet as the Access Point.
#
# wlan0: Static IP for Access Point mode (managed by hostapd)
#        MUST be under 'ethernets' — NOT 'wifis' — to prevent Netplan
#        from spawning wpa_supplicant which conflicts with hostapd.
# eth0:  No address in OFFLINE mode. Previous dual-IP assignment caused
#        ARP conflicts (B92). eth0 gets an address only in ONLINE_ETH or
#        SERVER_ETH modes via write_netplan_for_mode().

network:
  version: 2
  renderer: networkd

  ethernets:
    eth0:
      link-local: []
      optional: true

    # wlan0 is intentionally here, not under 'wifis:'
    # hostapd handles all radio/association; we just need the IP.
    wlan0:
      addresses:
        - 10.42.24.1/24
      link-local: []
      optional: true
NETPLAN

chmod 600 /etc/netplan/01-cubeos.yaml
echo "[02]   Netplan configured (OFFLINE default: wlan0=10.42.24.1, eth0=no address)"

# ---------------------------------------------------------------------------
# systemd-resolved — disable stub listener + point to Pi-hole
# ---------------------------------------------------------------------------
# By default, systemd-resolved listens on 127.0.0.53:53 which blocks
# Pi-hole's dnsmasq from binding to port 53 on all interfaces.
# Also configure the host to use Pi-hole for DNS resolution, including
# *.cubeos.cube local domain.
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
# Ensures 'sudo' and other tools can resolve the hostname even when
# Pi-hole is not yet running (e.g., early in boot sequence).
# ---------------------------------------------------------------------------
echo "[02] Configuring /etc/hosts fallback..."
if ! grep -q "cubeos" /etc/hosts 2>/dev/null; then
    echo "127.0.1.1 cubeos" >> /etc/hosts
fi
echo "[02]   /etc/hosts fallback configured"

# ---------------------------------------------------------------------------
# sysctl — IP forwarding is already enabled in golden base image
# ---------------------------------------------------------------------------
echo "[02]   IP forwarding: already configured in base image"

# ---------------------------------------------------------------------------
# hostapd — template config (SSID/key filled on first boot from MAC)
# ---------------------------------------------------------------------------
echo "[02] Writing hostapd template..."
mkdir -p /etc/hostapd

cat > /etc/hostapd/hostapd.conf << 'HOSTAPD'
# =============================================================================
# CubeOS WiFi Access Point Configuration
# =============================================================================
# SSID and WPA key are set on first boot from wlan0 MAC address.
# After setup wizard, user-chosen values replace these.
#
# Defaults (set by first-boot script):
#   SSID:     CubeOS-XXYYZZ   (last 6 hex of MAC)
#   WPA Key:  cubeos-XXYYZZ   (last 6 hex of MAC)
# =============================================================================

interface=wlan0
driver=nl80211

# ─── SSID (placeholder — replaced on first boot) ────────────
ssid=CubeOS-Setup

# ─── Radio settings ─────────────────────────────────────────
# hw_mode=g (2.4GHz) for maximum compatibility across all clients
hw_mode=g
channel=6
ieee80211n=1
ieee80211ac=0

# Regulatory domain is handled by cfg80211 modprobe config, not hostapd.
# See cfg80211.conf section below.

# ─── Security ───────────────────────────────────────────────
wpa=2
wpa_passphrase=cubeos-setup
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP

# ─── General ────────────────────────────────────────────────
wmm_enabled=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
max_num_sta=32

# ─── Logging ────────────────────────────────────────────────
logger_syslog=-1
logger_syslog_level=2
logger_stdout=-1
logger_stdout_level=2
HOSTAPD

chmod 600 /etc/hostapd/hostapd.conf

# Point hostapd to our config
echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' > /etc/default/hostapd

# ---------------------------------------------------------------------------
# cfg80211 — regulatory domain via modprobe (replaces hostapd country_code)
# ---------------------------------------------------------------------------
# Setting regulatory domain via cfg80211 kernel module is more reliable than
# hostapd's country_code directive, which can be ignored on some drivers.
# TODO: Parameterize country code via first-boot wizard (default US, updated by user)
# ---------------------------------------------------------------------------
echo "[02] Setting cfg80211 regulatory domain..."
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/cfg80211.conf << 'CFG80211'
options cfg80211 ieee80211_regdom=NL
CFG80211
echo "[02]   cfg80211 regulatory domain set to NL"

# ---------------------------------------------------------------------------
# iptables NAT rules script (called on boot for ONLINE modes)
# ---------------------------------------------------------------------------
echo "[02] Writing NAT rules scripts..."
mkdir -p /usr/local/lib/cubeos

cat > /usr/local/lib/cubeos/nat-enable.sh << 'NAT_ON'
#!/bin/bash
# =============================================================================
# Enable NAT forwarding from AP (wlan0) to upstream interface
# Usage: nat-enable.sh <upstream_interface>
#   upstream_interface: eth0 (ethernet) or wlan1 (USB WiFi dongle)
# =============================================================================
set -euo pipefail

UPSTREAM="${1:-eth0}"
AP_IFACE="wlan0"
SUBNET="10.42.24.0/24"

echo "[NAT] Enabling NAT: ${AP_IFACE} -> ${UPSTREAM}"

# IP forwarding is already enabled via sysctl.d/99-cubeos-forwarding.conf
# but ensure it's active right now
echo 1 > /proc/sys/net/ipv4/ip_forward

# Flush existing NAT rules
iptables -t nat -F POSTROUTING 2>/dev/null || true

# Masquerade outgoing traffic from AP subnet
iptables -t nat -A POSTROUTING -s ${SUBNET} -o ${UPSTREAM} -j MASQUERADE

# Allow forwarding between interfaces
iptables -A FORWARD -i ${AP_IFACE} -o ${UPSTREAM} -j ACCEPT
iptables -A FORWARD -i ${UPSTREAM} -o ${AP_IFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "[NAT] NAT enabled: ${SUBNET} via ${UPSTREAM}"
NAT_ON

cat > /usr/local/lib/cubeos/nat-disable.sh << 'NAT_OFF'
#!/bin/bash
# =============================================================================
# Disable NAT forwarding (return to OFFLINE mode)
# =============================================================================
set -euo pipefail

echo "[NAT] Disabling NAT rules..."

# Flush NAT and forwarding rules
iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true

# Keep IP forwarding enabled (Docker needs it)
echo "[NAT] NAT disabled."
NAT_OFF

chmod +x /usr/local/lib/cubeos/nat-enable.sh
chmod +x /usr/local/lib/cubeos/nat-disable.sh

# ---------------------------------------------------------------------------
# Unblock WiFi radio — systemd oneshot (replaces deprecated rc.local)
# ---------------------------------------------------------------------------
echo "[02] Installing WiFi rfkill unblock service..."

cat > /etc/systemd/system/cubeos-rfkill-unblock.service << 'RFKILL'
[Unit]
Description=CubeOS WiFi Radio Unblock
Before=hostapd.service
After=sys-subsystem-net-devices-wlan0.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/rfkill unblock wifi

[Install]
WantedBy=multi-user.target
RFKILL

systemctl enable cubeos-rfkill-unblock.service 2>/dev/null || true

# Also unblock now during image build (in case hostapd tests are run)
rfkill unblock wifi 2>/dev/null || true

# ---------------------------------------------------------------------------
# T05 (Network Modes Batch 1): networkd-dispatcher auto-detection REMOVED
# ---------------------------------------------------------------------------
# Previously, networkd-dispatcher scripts auto-enabled NAT when eth0 became
# routable in OFFLINE mode. This is removed because:
#   - It created implicit mode changes (OFFLINE silently gained internet)
#   - It conflicted with the explicit 5-mode model
#   - The API now manages mode transitions with full Pi-hole DHCP + netplan
# The explicit mode-switch flow (dashboard/console → API → netplan + DHCP)
# replaces this auto-detection entirely.
# ---------------------------------------------------------------------------
echo "[02] networkd-dispatcher auto-online scripts: REMOVED (explicit mode-switch only)"

# Clean up any existing scripts from previous builds
rm -f /etc/networkd-dispatcher/routable.d/50-cubeos-eth-online
rm -f /etc/networkd-dispatcher/no-carrier.d/50-cubeos-eth-offline
rm -f /etc/networkd-dispatcher/off.d/50-cubeos-eth-offline

# ---------------------------------------------------------------------------
# T03 (Network Modes Batch 1): udev rule for USB WiFi dongle → wlan1
# ---------------------------------------------------------------------------
# Ensures any USB WiFi adapter is consistently named 'wlan1' regardless of
# chipset. This is critical for ONLINE_WIFI mode where wlan0 is the AP and
# wlan1 is the upstream WiFi client via USB dongle.
#
# Rule matches: any USB wireless device (type 1 = ARPHRD_ETHER on wireless).
# The built-in WiFi (wlan0) is on the platform bus, not USB, so this rule
# won't match it.
# ---------------------------------------------------------------------------
echo "[02] Installing udev rule for USB WiFi → wlan1..."

cat > /etc/udev/rules.d/70-cubeos-usb-wifi.rules << 'UDEV_WIFI'
# =============================================================================
# CubeOS: Force USB WiFi adapters to wlan1
# =============================================================================
# Any USB wireless NIC gets named wlan1. The built-in WiFi (platform bus) is
# wlan0 and managed by hostapd as the AP interface.
# This ensures ONLINE_WIFI mode can reliably reference wlan1 as the upstream
# WiFi client interface.
# =============================================================================
SUBSYSTEM=="net", ACTION=="add", ENV{ID_BUS}=="usb", ATTR{type}=="1", KERNEL=="wl*", NAME="wlan1"
UDEV_WIFI

echo "[02]   udev rule installed: /etc/udev/rules.d/70-cubeos-usb-wifi.rules"

# ---------------------------------------------------------------------------
# B61 FIX: Create cubeos user EXPLICITLY (no cloud-init dependency)
# ---------------------------------------------------------------------------
# The stock Ubuntu ARM64 image ships with the 'ubuntu' user created by
# cloud-init. Previous releases relied on cloud-init's 99-cubeos.cfg to
# rename/create the cubeos user and set its password at boot time. This
# failed catastrophically when cloud-init-local.service failed (machine-id
# issue after cloud-init clean), leaving the system with NO usable login.
#
# Fix: Create the user and set its password directly during the Packer build.
# This bakes a working login into the image itself. Cloud-init config below
# is kept for Pi Imager support (SSH keys, hostname override) but is no
# longer the ONLY path to a working user.
# ---------------------------------------------------------------------------
echo "[02] Creating cubeos user (B61 fix — no cloud-init dependency)..."

# Create the i2c group if it doesn't exist (needed for UPS/sensor access)
getent group i2c >/dev/null 2>&1 || groupadd -r i2c

if id cubeos &>/dev/null; then
    echo "[02]   cubeos user already exists"
else
    # Check if ubuntu user exists (stock Ubuntu image default)
    if id ubuntu &>/dev/null; then
        echo "[02]   Renaming ubuntu → cubeos..."
        usermod -l cubeos -d /home/cubeos -m ubuntu 2>/dev/null || true
        groupmod -n cubeos ubuntu 2>/dev/null || true
    else
        echo "[02]   Creating cubeos user from scratch..."
        useradd -m -s /bin/bash -G sudo,adm cubeos
    fi
fi

# Ensure all required groups (idempotent — no error if already member)
for grp in sudo docker adm i2c; do
    getent group "$grp" >/dev/null 2>&1 && usermod -aG "$grp" cubeos 2>/dev/null || true
done

# Set password directly — THE critical B61 fix
echo "cubeos:cubeos" | chpasswd
echo "[02]   cubeos password set via chpasswd (B61 fix)"

# Ensure passwordless sudo
echo "cubeos ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/cubeos
chmod 440 /etc/sudoers.d/cubeos

# Ensure home directory exists with correct ownership
mkdir -p /home/cubeos
chown cubeos:cubeos /home/cubeos
chmod 750 /home/cubeos

# Remove lock_passwd flag if set (cloud-init sometimes locks the password)
passwd -u cubeos 2>/dev/null || true

echo "[02]   cubeos user ready (groups: $(id -nG cubeos 2>/dev/null))"

# ---------------------------------------------------------------------------
# PAM: Remove deprecated pam_lastlog.so reference (Ubuntu 24.04)
# ---------------------------------------------------------------------------
# pam_lastlog was removed from libpam-modules in 24.04. The reference in
# /etc/pam.d/login generates a "cannot open shared object" warning on every
# login, which is confusing and may interfere with SSH auth debugging.
# ---------------------------------------------------------------------------
if grep -q "pam_lastlog" /etc/pam.d/login 2>/dev/null; then
    sed -i '/pam_lastlog/d' /etc/pam.d/login
    echo "[02]   Removed deprecated pam_lastlog from /etc/pam.d/login"
fi

# ---------------------------------------------------------------------------
# Cloud-init — configure for Raspberry Pi Imager support
# ---------------------------------------------------------------------------
# Cloud-init is now a SECONDARY mechanism. The cubeos user and password are
# already set above. Cloud-init handles: hostname customization, SSH key
# injection from Pi Imager, and partition expansion (growpart).
# If cloud-init fails entirely, the system still boots with a working login.
# ---------------------------------------------------------------------------
echo "[02] Configuring cloud-init..."
mkdir -p /etc/cloud/cloud.cfg.d

cat > /etc/cloud/cloud.cfg.d/99-cubeos.cfg << 'CLOUDINIT'
# CubeOS cloud-init config (SECONDARY — user already created by 02-networking.sh)
# Supports Raspberry Pi Imager customization (hostname, SSH keys)
datasource_list: [NoCloud]
datasource:
  NoCloud:
    fs_label: system-boot

# Preserve our networking — don't let cloud-init override Netplan
network:
  config: disabled

# Set hostname to cubeos
preserve_hostname: false
hostname: cubeos

# Override default user from ubuntu to cubeos
system_info:
  default_user:
    name: cubeos
    lock_passwd: false
    gecos: CubeOS Admin
    groups: [sudo, docker, adm, i2c]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash

# Set default password (user should change via wizard)
chpasswd:
  expire: false
  users:
    - name: cubeos
      password: cubeos
      type: text

# Disable creating the ubuntu user
users:
  - default
CLOUDINIT

# Also set hostname directly in the image (belt and suspenders)
echo "cubeos" > /etc/hostname
# Update /etc/hosts (may already have been added above, sed handles duplicates)
sed -i 's/127\.0\.1\.1.*/127.0.1.1\tcubeos/' /etc/hosts 2>/dev/null || true

# Enable cloud-init for first boot only
systemctl enable cloud-init 2>/dev/null || true

# ---------------------------------------------------------------------------
# SSH — enable password authentication for initial access
# ---------------------------------------------------------------------------
# B61: The cubeos user and password are set above. This ensures sshd accepts
# password auth so users can SSH in immediately after first boot.
# Cloud-init's 50-cloud-init.conf defaults to PasswordAuthentication no.
# Our 01-cubeos.conf loads first (first-match-wins in sshd_config.d/).
# ---------------------------------------------------------------------------
echo "[02] Enabling SSH password + pubkey authentication..."
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/01-cubeos.conf <<'SSHEOF'
PasswordAuthentication yes
PubkeyAuthentication yes
SSHEOF
# Cloud-init creates 50-cloud-init.conf with PasswordAuthentication no.
# OpenSSH uses first-match-wins in sshd_config.d/, so 01-* ensures we win
# even if cloud-init regenerates 50-cloud-init.conf on boot.
rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf
echo "[02]   SSH password + pubkey auth enabled (via sshd_config.d/01-cubeos.conf)"

# Prepare .ssh directory for post-flash key deployment (ssh-copy-id or Pi Imager)
mkdir -p /home/cubeos/.ssh
chmod 700 /home/cubeos/.ssh
chown cubeos:cubeos /home/cubeos/.ssh
echo "[02]   /home/cubeos/.ssh/ directory created (ready for authorized_keys)"

echo "[02] Network configuration complete."
