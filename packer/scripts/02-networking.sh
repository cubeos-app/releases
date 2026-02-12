#!/bin/bash
# =============================================================================
# 02-networking.sh — Network stack configuration
# =============================================================================
# Configures hostapd (template), static IP for wlan0, DHCP fallback for eth0,
# iptables NAT rules template, and dnsmasq as a lightweight backup DHCP.
#
# NOTE: Raspberry Pi OS Bookworm uses dhcpcd, NOT netplan.
# We configure dhcpcd for static wlan0 IP + DHCP on eth0.
# =============================================================================
set -euo pipefail

echo "=== [02] Network Configuration ==="

# ---------------------------------------------------------------------------
# Disable services that conflict with our stack
# ---------------------------------------------------------------------------
echo "[02] Disabling conflicting services..."

# hostapd — we enable it ourselves during first boot
systemctl unmask hostapd 2>/dev/null || true
systemctl disable hostapd 2>/dev/null || true

# dnsmasq — Pi-hole replaces this for DNS/DHCP, but we keep the package
# for potential fallback. Disable the daemon.
systemctl disable dnsmasq 2>/dev/null || true
systemctl mask dnsmasq 2>/dev/null || true

# wpa_supplicant on wlan0 — conflicts with hostapd AP mode
# We'll manage this selectively per-interface
systemctl disable wpa_supplicant 2>/dev/null || true

# ---------------------------------------------------------------------------
# dhcpcd — static IP for wlan0, DHCP for eth0
# ---------------------------------------------------------------------------
echo "[02] Configuring dhcpcd..."

# Raspberry Pi OS Bookworm uses dhcpcd (not NetworkManager or netplan)
cat > /etc/dhcpcd.conf << 'DHCPCD'
# =============================================================================
# CubeOS Network Configuration (dhcpcd)
# =============================================================================
# wlan0: Static IP for Access Point mode
# eth0:  DHCP client for upstream internet (ONLINE_ETH mode)

# Reduce timeout for faster boot when no ethernet
timeout 10

# Disable IPv6 router solicitation (we manage this ourselves)
noipv6rs

# ─── wlan0: Access Point (always static) ─────────────────────
interface wlan0
    static ip_address=10.42.24.1/24
    nohook wpa_supplicant

# ─── eth0: DHCP client (upstream internet) ───────────────────
interface eth0
    # DHCP by default — gets IP from upstream router
    # Gateway and DNS come from DHCP
DHCPCD

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
# hw_mode=a enables 5GHz on Pi 5 (wifi 5), falls back to 2.4 on Pi 4
# We use hw_mode=g (2.4GHz) for maximum compatibility across all clients
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
# Unblock WiFi radio (some Pi configurations have it blocked by default)
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
# Cloud-init — configure NoCloud datasource for Raspberry Pi Imager support
# ---------------------------------------------------------------------------
echo "[02] Configuring cloud-init..."
mkdir -p /etc/cloud/cloud.cfg.d

cat > /etc/cloud/cloud.cfg.d/99-cubeos.cfg << 'CLOUDINIT'
# CubeOS cloud-init config
# Supports Raspberry Pi Imager customization (hostname, SSH keys)
datasource_list: [NoCloud]
datasource:
  NoCloud:
    fs_label: bootfs

# Preserve our networking — don't let cloud-init override dhcpcd
network:
  config: disabled

# Preserve our hostname setup
preserve_hostname: true
CLOUDINIT

# Enable cloud-init for first boot only
systemctl enable cloud-init 2>/dev/null || true

echo "[02] Network configuration complete."
