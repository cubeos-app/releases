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
# CubeOS Network Configuration (Netplan / systemd-networkd)
# =============================================================================
# wlan0: Static IP for Access Point mode (managed by hostapd)
#        MUST be under 'ethernets' — NOT 'wifis' — to prevent Netplan
#        from spawning wpa_supplicant which conflicts with hostapd.
# eth0:  DHCP client for upstream internet (ONLINE_ETH mode)
# wlan1: Reserved for USB WiFi dongle client (ONLINE_WIFI mode)

network:
  version: 2
  renderer: networkd

  ethernets:
    eth0:
      dhcp4: true
      dhcp-identifier: mac
      optional: true
      dhcp4-overrides:
        use-dns: false
      nameservers:
        addresses:
          - 10.42.24.1

    # wlan0 is intentionally here, not under 'wifis:'
    # hostapd handles all radio/association; we just need the IP.
    wlan0:
      addresses:
        - 10.42.24.1/24
      link-local: []
      optional: true
NETPLAN

chmod 600 /etc/netplan/01-cubeos.yaml
echo "[02]   Netplan configured (wlan0=10.42.24.1, eth0=DHCP+Pi-hole DNS)"

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
# networkd-dispatcher — auto-detect eth0 carrier for seamless ONLINE_ETH
# ---------------------------------------------------------------------------
# When eth0 becomes routable (cable plugged + DHCP acquired) and the system
# is in OFFLINE mode, automatically enable NAT so AP clients get internet
# without needing a manual mode switch. The reverse: when eth0 loses carrier,
# disable NAT (return to effective OFFLINE).
#
# This is runtime-only — it does NOT change the persisted mode in SQLite.
# The user can still set explicit modes via the dashboard for permanent changes.
#
# networkd-dispatcher is pre-installed on Ubuntu 24.04 Server.
# Scripts receive $IFACE and $AdministrativeState / $OperationalState.
# ---------------------------------------------------------------------------
echo "[02] Installing networkd-dispatcher auto-online scripts..."

# Ensure networkd-dispatcher is installed and directories exist
apt-get install -y networkd-dispatcher 2>/dev/null || true
mkdir -p /etc/networkd-dispatcher/routable.d
mkdir -p /etc/networkd-dispatcher/no-carrier.d
mkdir -p /etc/networkd-dispatcher/off.d

cat > /etc/networkd-dispatcher/routable.d/50-cubeos-eth-online << 'ETH_ONLINE'
#!/bin/bash
# =============================================================================
# Auto-enable NAT when eth0 becomes routable (has DHCP IP).
# Only activates if current mode is OFFLINE (don't interfere with explicit modes).
# Runtime-only — does not change persisted mode in SQLite.
# =============================================================================
[ "$IFACE" = "eth0" ] || exit 0

DATA_DIR="/cubeos/data"
DB_PATH="${DATA_DIR}/cubeos.db"

# Read current mode from SQLite
MODE=""
if [ -f "$DB_PATH" ]; then
    MODE=$(python3 -c "
import sqlite3
try:
    conn = sqlite3.connect('${DB_PATH}')
    row = conn.execute('SELECT mode FROM network_config WHERE id = 1').fetchone()
    print(row[0] if row else '')
    conn.close()
except: pass
" 2>/dev/null) || true
fi

# Only auto-enable NAT for OFFLINE mode (or if mode is unset/first-boot)
case "${MODE:-offline}" in
    offline|"")
        logger -t cubeos-net "eth0 routable in OFFLINE mode — auto-enabling NAT"
        /usr/local/lib/cubeos/nat-enable.sh eth0 2>/dev/null || true
        ;;
    *)
        # Mode is already set to something explicit — don't interfere
        ;;
esac
ETH_ONLINE

cat > /etc/networkd-dispatcher/no-carrier.d/50-cubeos-eth-offline << 'ETH_OFFLINE'
#!/bin/bash
# =============================================================================
# Auto-disable NAT when eth0 loses carrier (cable unplugged).
# Only deactivates if current mode is OFFLINE (auto-online was runtime-only).
# =============================================================================
[ "$IFACE" = "eth0" ] || exit 0

DATA_DIR="/cubeos/data"
DB_PATH="${DATA_DIR}/cubeos.db"

MODE=""
if [ -f "$DB_PATH" ]; then
    MODE=$(python3 -c "
import sqlite3
try:
    conn = sqlite3.connect('${DB_PATH}')
    row = conn.execute('SELECT mode FROM network_config WHERE id = 1').fetchone()
    print(row[0] if row else '')
    conn.close()
except: pass
" 2>/dev/null) || true
fi

# Only auto-disable NAT for OFFLINE mode (runtime auto-online was temporary)
case "${MODE:-offline}" in
    offline|"")
        logger -t cubeos-net "eth0 lost carrier in OFFLINE mode — disabling NAT"
        /usr/local/lib/cubeos/nat-disable.sh 2>/dev/null || true
        ;;
    *)
        # Explicit mode set — don't touch NAT
        ;;
esac
ETH_OFFLINE

# Copy the no-carrier script to off.d as well (interface fully down)
cp /etc/networkd-dispatcher/no-carrier.d/50-cubeos-eth-offline \
   /etc/networkd-dispatcher/off.d/50-cubeos-eth-offline

chmod +x /etc/networkd-dispatcher/routable.d/50-cubeos-eth-online
chmod +x /etc/networkd-dispatcher/no-carrier.d/50-cubeos-eth-offline
chmod +x /etc/networkd-dispatcher/off.d/50-cubeos-eth-offline

# Ensure networkd-dispatcher is enabled
systemctl enable networkd-dispatcher 2>/dev/null || true
echo "[02]   networkd-dispatcher auto-online scripts installed"

# ---------------------------------------------------------------------------
# Cloud-init — configure for Raspberry Pi Imager support
# ---------------------------------------------------------------------------
# CRITICAL: Must set default_user to cubeos, otherwise Ubuntu cloud-init
# creates 'ubuntu' user and ignores the cubeos user from golden base.
# Must set hostname to cubeos, otherwise it stays 'ubuntu'.
# ---------------------------------------------------------------------------
echo "[02] Configuring cloud-init..."
mkdir -p /etc/cloud/cloud.cfg.d

cat > /etc/cloud/cloud.cfg.d/99-cubeos.cfg << 'CLOUDINIT'
# CubeOS cloud-init config
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
# Cloud-init defaults to publickey-only. Users need password auth to connect
# via ssh cubeos@10.42.24.1 on first setup. They can add keys later.
# ---------------------------------------------------------------------------
echo "[02] Enabling SSH password authentication..."
mkdir -p /etc/ssh/sshd_config.d
echo "PasswordAuthentication yes" > /etc/ssh/sshd_config.d/01-cubeos.conf
# Cloud-init creates 50-cloud-init.conf with PasswordAuthentication no.
# OpenSSH uses first-match-wins in sshd_config.d/, so 01-* ensures we win
# even if cloud-init regenerates 50-cloud-init.conf on boot.
rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf
echo "[02]   SSH password auth enabled (via sshd_config.d/01-cubeos.conf)"

echo "[02] Network configuration complete."
