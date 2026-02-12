#!/bin/bash
# =============================================================================
# 05-docker-preload.sh — Docker image tarball preload setup
# =============================================================================
# The docker-images/ directory was copied to /var/cache/cubeos-images/ by
# the Packer file provisioner. This script creates a systemd oneshot service
# that loads them into Docker on first real boot (at native ARM64 speed).
#
# Images are loaded AFTER Docker starts but BEFORE cubeos-first-boot.sh
# deploys the stacks, ensuring images are available for immediate stack deploy.
# =============================================================================
set -euo pipefail

echo "=== [05] Docker Preload Setup ==="

# ---------------------------------------------------------------------------
# Verify tarballs were copied
# ---------------------------------------------------------------------------
CACHE_DIR="/var/cache/cubeos-images"

if [ ! -d "$CACHE_DIR" ] || [ -z "$(ls -A $CACHE_DIR 2>/dev/null)" ]; then
    echo "[05] WARNING: No Docker image tarballs found in $CACHE_DIR"
    echo "[05] Images will need to be pulled on first boot (requires internet)."
    exit 0
fi

echo "[05] Found Docker image tarballs:"
ls -lh "$CACHE_DIR"/*.tar 2>/dev/null || true

# ---------------------------------------------------------------------------
# Create the preload script (runs on real Pi hardware, native speed)
# ---------------------------------------------------------------------------
cat > /usr/local/bin/cubeos-docker-preload.sh << 'PRELOAD'
#!/bin/bash
# =============================================================================
# Load pre-baked Docker images from tarballs into Docker Engine
# Runs once on first boot, then self-disables.
# =============================================================================
set -euo pipefail

CACHE_DIR="/var/cache/cubeos-images"
LOG="/var/log/cubeos-docker-preload.log"

exec 1> >(tee -a "$LOG") 2>&1

echo "=== CubeOS Docker Image Preload ==="
echo "Started at: $(date)"

if [ ! -d "$CACHE_DIR" ] || [ -z "$(ls -A $CACHE_DIR 2>/dev/null)" ]; then
    echo "No cached images found. Skipping preload."
    exit 0
fi

# Wait for Docker daemon to be ready
echo "Waiting for Docker..."
for i in $(seq 1 60); do
    if docker info &>/dev/null; then
        echo "Docker is ready."
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "ERROR: Docker not ready after 60s. Aborting preload."
        exit 1
    fi
    sleep 1
done

# Load each tarball
LOADED=0
FAILED=0
for tarball in "$CACHE_DIR"/*.tar; do
    [ -f "$tarball" ] || continue
    NAME=$(basename "$tarball" .tar)
    echo "Loading: ${NAME}..."
    
    if docker load < "$tarball" 2>&1; then
        echo "  OK: ${NAME}"
        LOADED=$((LOADED + 1))
    else
        echo "  FAILED: ${NAME}"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "Preload complete: ${LOADED} loaded, ${FAILED} failed"
echo "Finished at: $(date)"

# Clean up cache to reclaim disk space
echo "Cleaning up image cache..."
rm -rf "$CACHE_DIR"

# Disable this service so it doesn't run again
systemctl disable cubeos-docker-preload.service 2>/dev/null || true

echo "Preload service disabled. Cache removed."
PRELOAD

chmod +x /usr/local/bin/cubeos-docker-preload.sh

# ---------------------------------------------------------------------------
# Create systemd service (oneshot, runs after Docker, before first-boot)
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/cubeos-docker-preload.service << 'SYSTEMD'
[Unit]
Description=CubeOS Docker Image Preload
Documentation=https://github.com/cubeos-app
After=docker.service
Requires=docker.service
Before=cubeos-init.service
ConditionPathExists=/var/cache/cubeos-images

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/cubeos-docker-preload.sh
TimeoutStartSec=300
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl enable cubeos-docker-preload.service 2>/dev/null || true

echo "[05] Docker preload service installed."
echo "[05] Images will be loaded on first boot at native ARM64 speed."
