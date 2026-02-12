#!/bin/bash
# =============================================================================
# 02-networking.sh — Network stack configuration (Ubuntu 24.04)
# =============================================================================
# Configures Netplan (static wlan0, DHCP eth0), hostapd template,
# iptables NAT rules, and cloud-init for Raspberry Pi Imager support.
#
# Ubuntu 24.04 uses Netplan + systemd-networkd (NOT dhcpcd like Pi OS).
# This matches the CubeOS production environment.
# =============================================================================
set -euo pipefail

echo "=== [02] Network Configuration (Ubuntu) ==="

# ---------------------------------------------------------------------------
# Disable services that conflict with our stack
# ---------------------------------------------------------------------------
echo "[02] Disabling conflicting services..."

# hostapd — we enable it ourselves during first boot
systemctl unmask hostapd 2>/dev/null || true
systemctl disable hostapd 2>/dev/null || true

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
echo "[02] Configuring Netplan..."

# Remove any existing Ubuntu default netplan configs
rm -f /etc/netplan/50-cloud-init.yaml
rm -f /etc/netplan/99-default.yaml

cat > /etc/netplan/01-cubeos.yaml << 'NETPLAN'
# =============================================================================
# CubeOS Network Configuration (Netplan / systemd-networkd)
# =============================================================================
# wlan0: Static IP for Access Point mode (managed by hostapd)
# eth0:  DHCP client for upstream internet (ONLINE_ETH mode)
# wlan1: Reserved for USB WiFi dongle client (ONLINE_WIFI mode)

network:
  version: 2
  renderer: networkd

  ethernets:
    eth0:
      dhcp4: true
      optional: true

  wifis:
    wlan0:
      addresses:
        - 10.42.24.1/24
      # No gateway — this is the AP interface, not a client
      # No DNS — Pi-hole handles DNS on this subnet
      # No DHCP — static only
      optional: true
NETPLAN

chmod 600 /etc/netplan/01-cubeos.yaml
echo "[02]   Netplan configured (wlan0=10.42.24.1, eth0=DHCP)"

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

# Country code — set to regulatory domain
# Users can change this via wizard
country_code=US

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

# Enable IP forwarding (should already be set via sysctl)
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
# Unblock WiFi radio
# ---------------------------------------------------------------------------
echo "[02] Ensuring WiFi radio is unblocked..."
rfkill unblock wifi 2>/dev/null || true

# Ensure rfkill unblock persists on boot
cat > /etc/rc.local << 'RCLOCAL'
#!/bin/bash
rfkill unblock wifi 2>/dev/null || true
exit 0
RCLOCAL
chmod +x /etc/rc.local

# ---------------------------------------------------------------------------
# Cloud-init — configure for Raspberry Pi Imager support
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

# Preserve our hostname setup
preserve_hostname: true
CLOUDINIT

# Enable cloud-init for first boot only
systemctl enable cloud-init 2>/dev/null || true

echo "[02] Network configuration complete."
