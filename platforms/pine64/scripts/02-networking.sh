#!/bin/bash
# =============================================================================
# Pine64 networking — Armbian base, DHCP on eth0/end0, no AP
# =============================================================================
# Armbian may ship with NetworkManager — we switch to systemd-networkd
# for consistency with other CubeOS platforms. No WiFi AP on Pine64
# (no reliable onboard WiFi), so this is wired-only like x86_64.
#
# NOTE: Kept as a separate copy from bananapi/02-networking.sh to allow
# per-board divergence as support matures.
# =============================================================================
set -euo pipefail
echo "=== [02] Network Configuration (Pine64/Armbian) ==="

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

echo "=== [02] Pine64 Network Configuration: DONE ==="
