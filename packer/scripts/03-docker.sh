#!/bin/bash
# =============================================================================
# 03-docker.sh — Docker Engine installation and configuration
# =============================================================================
# Installs Docker CE from official repo, configures daemon for Pi optimization,
# prepares Swarm settings. Docker daemon is NOT started (no daemon in chroot).
# =============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "=== [03] Docker Installation ==="

# ---------------------------------------------------------------------------
# Install Docker CE from official repository
# ---------------------------------------------------------------------------
echo "[03] Adding Docker GPG key and repository..."

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

echo "[03] Docker packages installed."

# ---------------------------------------------------------------------------
# Docker daemon configuration
# ---------------------------------------------------------------------------
echo "[03] Writing Docker daemon config..."
mkdir -p /etc/docker

cat > /etc/docker/daemon.json << 'DOCKERD'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "live-restore": true,
    "default-address-pools": [
        {
            "base": "172.20.0.0/16",
            "size": 24
        }
    ],
    "dns": ["10.42.24.1"],
    "metrics-addr": "0.0.0.0:9323",
    "experimental": false,
    "features": {
        "buildkit": true
    }
}
DOCKERD

# ---------------------------------------------------------------------------
# Docker systemd override — resource limits for Pi
# ---------------------------------------------------------------------------
echo "[03] Writing Docker systemd override..."
mkdir -p /etc/systemd/system/docker.service.d

cat > /etc/systemd/system/docker.service.d/cubeos.conf << 'DOCKERSD'
[Service]
# Limit Docker daemon memory to prevent runaway on low-RAM Pi
MemoryMax=256M
# Restart on failure
Restart=always
RestartSec=5
DOCKERSD

# ---------------------------------------------------------------------------
# Enable Docker to start on boot
# ---------------------------------------------------------------------------
systemctl enable docker 2>/dev/null || true
systemctl enable containerd 2>/dev/null || true

# ---------------------------------------------------------------------------
# Add cubeos user to docker group
# ---------------------------------------------------------------------------
usermod -aG docker cubeos 2>/dev/null || true

echo "[03] Docker installation complete."
