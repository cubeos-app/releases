#!/bin/bash
# =============================================================================
# 02-networking.sh — BPI-M4 Zero network stack (Armbian Noble, Allwinner H618)
# =============================================================================
# Full network configuration for BananaPi BPI-M4 Zero:
#   - systemd-networkd (replaces Armbian's NetworkManager)
#   - hostapd AP template for RTL8821CS WiFi (SSID/key set on first boot)
#   - systemd-resolved stub disabled (port 53 for Pi-hole)
#   - NAT rules for online modes
#   - cubeos user + SSH (same as Pi, adapted for Armbian)
#
# Armbian differences from Ubuntu for Pi:
#   - Ships with NetworkManager (not networkd) — we switch
#   - May have cloud-init — we disable its network config
#   - Ethernet interface may be eth0 or end0 (Armbian predictable naming)
#   - WiFi is RTL8821CS (SDIO, built-in) — driver is nl80211
#   - No separate FAT boot partition
#   - Default user is root or armbian (not ubuntu)
#
# RTL8821CS hostapd notes:
#   - AP mode support depends on in-kernel rtw88 driver (Armbian 6.12+)
#   - HT capabilities differ from BCM4345 — HT40 may work on RTL8821CS
#   - If hostapd fails on hardware, fallback to wired-only (eth_client mode)
# =============================================================================
set -euo pipefail

echo "=== [02] Network Configuration (BPI-M4 Zero / Armbian) ==="

# ---------------------------------------------------------------------------
# Disable services that conflict with our stack
# ---------------------------------------------------------------------------
echo "[02] Disabling conflicting services..."

# hostapd — unmask but do NOT enable at boot. Boot scripts manage via
# configure_wifi_ap() in cubeos-boot-lib.sh.
systemctl unmask hostapd 2>/dev/null || true
systemctl disable hostapd 2>/dev/null || true
echo "[02]   hostapd: disabled at boot (boot scripts manage startup)"

# dnsmasq — Pi-hole replaces this for DNS/DHCP
systemctl disable dnsmasq 2>/dev/null || true
systemctl mask dnsmasq 2>/dev/null || true

# wpa_supplicant on wlan0 — conflicts with hostapd AP mode
systemctl disable wpa_supplicant 2>/dev/null || true

# NetworkManager — Armbian ships with this; switch to systemd-networkd
systemctl disable NetworkManager 2>/dev/null || true
systemctl mask NetworkManager 2>/dev/null || true
systemctl enable systemd-networkd 2>/dev/null || true

echo "[02]   Conflicting services disabled"

# ---------------------------------------------------------------------------
# Netplan — static IP for wlan0 (AP), DHCP for ethernet
# ---------------------------------------------------------------------------
# IMPORTANT: wlan0 MUST be under 'ethernets', NOT 'wifis'.
# Under 'wifis', Netplan spawns wpa_supplicant which fights hostapd.
#
# Armbian may name ethernet as eth0 or end0 (predictable naming).
# We use a match pattern to catch both.
# ---------------------------------------------------------------------------
echo "[02] Configuring Netplan..."

# Remove Armbian default netplan configs
rm -f /etc/netplan/50-cloud-init.yaml
rm -f /etc/netplan/99-default.yaml
rm -f /etc/netplan/10-dhcp-all-interfaces.yaml
rm -f /etc/netplan/armbian-default.yaml

cat > /etc/netplan/01-cubeos.yaml << 'NETPLAN'
# =============================================================================
# CubeOS Network Configuration — Default: OFFLINE Mode (BPI-M4 Zero)
# =============================================================================
# wlan0: Static IP for Access Point mode (managed by hostapd)
#        MUST be under 'ethernets' — NOT 'wifis' — to prevent wpa_supplicant.
# eth0/end0: No address in OFFLINE mode. Gets DHCP in ONLINE modes.

network:
  version: 2
  renderer: networkd

  ethernets:
    all-eth:
      match:
        name: "e*"
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
echo "[02]   Netplan configured (OFFLINE default: wlan0=10.42.24.1, e*=no address)"

# ---------------------------------------------------------------------------
# systemd-resolved — disable stub listener + point to Pi-hole
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
# sysctl — IP forwarding
# ---------------------------------------------------------------------------
echo "[02] Configuring IP forwarding..."
cat > /etc/sysctl.d/99-cubeos-forwarding.conf << 'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
SYSCTL
echo "[02]   IP forwarding configured"

# ---------------------------------------------------------------------------
# hostapd — template config (SSID/key filled on first boot from MAC)
# ---------------------------------------------------------------------------
# RTL8821CS differences from BCM4345 (Pi):
#   - Uses nl80211 driver (same as Pi)
#   - May support HT40 on 2.4GHz (BCM4345 does not)
#   - We use HT20 only as safe default until tested on hardware
#   - 5GHz (hw_mode=a) possible but 2.4GHz has better range for AP
# ---------------------------------------------------------------------------
echo "[02] Writing hostapd template..."
mkdir -p /etc/hostapd

cat > /etc/hostapd/hostapd.conf << 'HOSTAPD'
# =============================================================================
# CubeOS WiFi Access Point Configuration (BPI-M4 Zero / RTL8821CS)
# =============================================================================
# SSID and WPA key are set on first boot from wlan0 MAC address.
# After setup wizard, user-chosen values replace these.
# =============================================================================

interface=wlan0
driver=nl80211

# ─── SSID (placeholder — replaced on first boot) ────────────
ssid=CubeOS-Setup

# ─── Radio settings ─────────────────────────────────────────
# hw_mode=g (2.4GHz) for maximum compatibility across all clients.
# RTL8821CS supports both 2.4/5GHz but 2.4GHz has better range for AP.
hw_mode=g
channel=6
# Regulatory domain — set via both hostapd AND cfg80211 modprobe.
country_code=NL
ieee80211n=1
ieee80211ac=0
# HT capabilities: HT20 + SHORT-GI-20 only (safe default).
# RTL8821CS may support HT40 — test on hardware before enabling.
ht_capab=[SHORT-GI-20]

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

# ─── Control interface (for hostapd_cli management) ────────
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0

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
# cfg80211 — regulatory domain via modprobe
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
# Enable NAT forwarding from AP (wlan0) to upstream interface
# Usage: nat-enable.sh <upstream_interface>
set -euo pipefail

UPSTREAM="${1:-eth0}"
AP_IFACE="${CUBEOS_AP_IFACE:-wlan0}"
SUBNET="10.42.24.0/24"

echo "[NAT] Enabling NAT: ${AP_IFACE} -> ${UPSTREAM}"

echo 1 > /proc/sys/net/ipv4/ip_forward

# Flush existing NAT rules
iptables -t nat -F POSTROUTING 2>/dev/null || true

# Masquerade outgoing traffic from AP subnet
iptables -t nat -A POSTROUTING -s ${SUBNET} -o ${UPSTREAM} -j MASQUERADE

# Masquerade Docker Swarm containers (docker_gwbridge)
DOCKER_GW_SUBNET=$(docker network inspect docker_gwbridge --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || echo "172.16.1.0/24")
if [ -n "${DOCKER_GW_SUBNET}" ]; then
  iptables -t nat -A POSTROUTING -s ${DOCKER_GW_SUBNET} -o ${UPSTREAM} -j MASQUERADE
  echo "[NAT] Docker Swarm NAT: ${DOCKER_GW_SUBNET} via ${UPSTREAM}"
fi

# Allow forwarding between interfaces
iptables -A FORWARD -i ${AP_IFACE} -o ${UPSTREAM} -j ACCEPT
iptables -A FORWARD -i ${UPSTREAM} -o ${AP_IFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "[NAT] NAT enabled: ${SUBNET} via ${UPSTREAM}"
NAT_ON

cat > /usr/local/lib/cubeos/nat-disable.sh << 'NAT_OFF'
#!/bin/bash
# Disable NAT forwarding (return to OFFLINE mode)
set -euo pipefail

echo "[NAT] Disabling NAT rules..."
iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true
echo "[NAT] NAT disabled."
NAT_OFF

chmod +x /usr/local/lib/cubeos/nat-enable.sh
chmod +x /usr/local/lib/cubeos/nat-disable.sh

# ---------------------------------------------------------------------------
# Unblock WiFi radio — systemd oneshot
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
rfkill unblock wifi 2>/dev/null || true

# ---------------------------------------------------------------------------
# USB WiFi dongle → wlan1 naming (for ONLINE_WIFI mode)
# ---------------------------------------------------------------------------
echo "[02] Installing systemd .link for USB WiFi → wlan1..."

rm -f /etc/udev/rules.d/70-cubeos-usb-wifi.rules

cat > /etc/systemd/network/10-cubeos-usb-wifi.link << 'LINK_WIFI'
# CubeOS: Force USB WiFi adapters to wlan1
# wlan0 = built-in RTL8821CS (SDIO, AP mode via hostapd)
# wlan1 = USB WiFi dongle (upstream client for ONLINE_WIFI mode)
[Match]
Type=wlan
Path=*-usb-*

[Link]
Name=wlan1
LINK_WIFI

echo "[02]   systemd .link installed"

# ---------------------------------------------------------------------------
# cubeos user — create directly (no cloud-init dependency)
# ---------------------------------------------------------------------------
# Armbian ships with root login or 'armbian' user. We create 'cubeos' user
# directly in the image so the system always has a working non-root login.
# ---------------------------------------------------------------------------
echo "[02] Creating cubeos user..."

getent group i2c >/dev/null 2>&1 || groupadd -r i2c

if id cubeos &>/dev/null; then
    echo "[02]   cubeos user already exists"
else
    # Armbian may have 'armbian' or 'ubuntu' default user
    if id armbian &>/dev/null; then
        echo "[02]   Renaming armbian → cubeos..."
        usermod -l cubeos -d /home/cubeos -m armbian 2>/dev/null || true
        groupmod -n cubeos armbian 2>/dev/null || true
    elif id ubuntu &>/dev/null; then
        echo "[02]   Renaming ubuntu → cubeos..."
        usermod -l cubeos -d /home/cubeos -m ubuntu 2>/dev/null || true
        groupmod -n cubeos ubuntu 2>/dev/null || true
    else
        echo "[02]   Creating cubeos user from scratch..."
        useradd -m -s /bin/bash -G sudo,adm cubeos
    fi
fi

for grp in sudo docker adm i2c; do
    getent group "$grp" >/dev/null 2>&1 && usermod -aG "$grp" cubeos 2>/dev/null || true
done

echo "cubeos:cubeos" | chpasswd
echo "[02]   cubeos password set"

echo "cubeos ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/cubeos
chmod 440 /etc/sudoers.d/cubeos

mkdir -p /home/cubeos
chown cubeos:cubeos /home/cubeos
chmod 750 /home/cubeos

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
# Cloud-init — disable network config, set hostname
# ---------------------------------------------------------------------------
echo "[02] Configuring cloud-init..."
mkdir -p /etc/cloud/cloud.cfg.d

cat > /etc/cloud/cloud.cfg.d/99-cubeos.cfg << 'CLOUDINIT'
# CubeOS cloud-init config (SECONDARY — user already created by 02-networking.sh)
datasource_list: [NoCloud]

# Preserve our networking — don't let cloud-init override Netplan
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

chpasswd:
  expire: false
  users:
    - name: cubeos
      password: cubeos
      type: text

users:
  - default
CLOUDINIT

echo "cubeos" > /etc/hostname
sed -i 's/127\.0\.1\.1.*/127.0.1.1\tcubeos/' /etc/hosts 2>/dev/null || true

systemctl enable cloud-init 2>/dev/null || true

# ---------------------------------------------------------------------------
# SSH — enable password authentication for initial access
# ---------------------------------------------------------------------------
echo "[02] Enabling SSH password + pubkey authentication..."
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/01-cubeos.conf <<'SSHEOF'
PasswordAuthentication yes
PubkeyAuthentication yes
SSHEOF
rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf

# SSH hardening
echo "[02] Applying SSH hardening..."
cat > /etc/ssh/sshd_config.d/99-cubeos-hardening.conf <<'SSHHARD'
# CubeOS SSH Hardening
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

mkdir -p /home/cubeos/.ssh
chmod 700 /home/cubeos/.ssh

# CI/CD deploy key
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
if ! command -v avahi-daemon &>/dev/null; then
    echo "[02]   WARNING: avahi-daemon not found — mDNS will not work"
    echo "[02]   Install avahi-daemon avahi-utils in the Armbian base image"
fi

mkdir -p /etc/avahi
cat > /etc/avahi/avahi-daemon.conf << 'AVAHI_CONF'
[server]
host-name=cubeos
domain-name=local
use-ipv4=yes
use-ipv6=yes
allow-interfaces=wlan0,eth0,end0

[publish]
publish-addresses=yes
publish-hinfo=yes
publish-workstation=no
publish-domain=yes

[reflector]

[rlimits]
AVAHI_CONF

# Avahi started by boot scripts in client modes only
systemctl disable avahi-daemon 2>/dev/null || true
echo "[02]   avahi-daemon configured (disabled at boot)"

echo "[02] Network configuration complete."
