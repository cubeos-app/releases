#!/bin/bash
# =============================================================================
# Quartz64 Model B networking — Armbian base, DHCP on Ethernet, no AP (yet)
# =============================================================================
# Armbian may ship with NetworkManager — we switch to systemd-networkd
# for consistency with other CubeOS platforms.
#
# NOTE: Quartz64 Model B has built-in WiFi (802.11 b/g/n/ac) — AP mode
# support can be added in future using hostapd, similar to Raspberry Pi.
# For now, this is wired-only to keep the initial bring-up simple.
#
# TODO: Add WiFi AP mode support (wlan0 interface available at runtime)
# =============================================================================
set -euo pipefail
echo "=== [02] Network Configuration (Quartz64 Model B/Armbian) ==="

# Armbian may use NetworkManager — disable it, use networkd
systemctl disable NetworkManager 2>/dev/null || true
systemctl enable systemd-networkd 2>/dev/null || true

# Disable systemd-resolved stub listener (port 53 needed for Pi-hole)
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/cubeos.conf << 'EOF'
[Resolve]
DNSStubListener=no
DNS=127.0.0.1
Domains=cubeos.cube
EOF
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

# Enable IP forwarding
cat > /etc/sysctl.d/99-cubeos-forwarding.conf << 'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

# Netplan — Armbian interfaces are usually eth0 or end0
cat > /etc/netplan/01-cubeos.yaml << 'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    all-eth:
      match:
        name: "e*"
      dhcp4: true
      dhcp4-overrides:
        use-dns: false
      nameservers:
        addresses: [127.0.0.1]
        search: [cubeos.cube]
EOF

# Disable cloud-init network config (Armbian may include cloud-init)
mkdir -p /etc/cloud/cloud.cfg.d
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

echo "=== [02] Quartz64 Model B Network Configuration: DONE ==="
