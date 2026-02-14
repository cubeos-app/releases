#!/bin/bash
# =============================================================================
# 05-docker-preload.sh — Docker image preload configuration
# =============================================================================
# Alpha.9: Docker images are now pre-loaded into /var/lib/docker at CI build
# time (Phase 1b). This script only configures a fallback service that handles
# any tarballs manually placed in /var/cache/cubeos-images (e.g., sideloading).
#
# The primary preload is done by the CI pipeline AFTER Packer builds the image:
#   1. CI loop-mounts the .img root partition
#   2. Starts a temporary dockerd with --data-root on the mounted partition
#   3. docker load < each ARM64 tarball
#   4. Graceful shutdown → images baked into overlay2 storage
#   5. Pi boots with images already present — zero loading time
# =============================================================================
set -euo pipefail

echo "=== [05] Docker Preload Configuration (alpha.9 — CI pre-loaded) ==="

CACHE_DIR="/var/cache/cubeos-images"

# ---------------------------------------------------------------------------
# Verify Docker daemon.json is Swarm-compatible (set by 04-cubeos.sh)
# ---------------------------------------------------------------------------
if [ -f /etc/docker/daemon.json ]; then
    echo "[05] Docker daemon.json:"
    cat /etc/docker/daemon.json
    # Pin overlay2 to ensure compatibility with CI-preloaded storage
    if ! grep -q '"storage-driver"' /etc/docker/daemon.json; then
        echo "[05] Adding storage-driver: overlay2 to daemon.json"
        python3 -c "
import json
with open('/etc/docker/daemon.json') as f:
    cfg = json.load(f)
cfg['storage-driver'] = 'overlay2'
with open('/etc/docker/daemon.json', 'w') as f:
    json.dump(cfg, f, indent=2)
"
    fi
else
    echo "[05] WARNING: No daemon.json found"
fi

# ---------------------------------------------------------------------------
# Fallback preload service — only runs if tarballs exist at boot
# ---------------------------------------------------------------------------
# This is a safety net. In the normal Alpha.9 flow, /var/cache/cubeos-images
# is deleted by Phase 1b after loading images into overlay2. This service only
# activates if someone manually places tarballs there (e.g., adding new apps
# to an existing image via sideloading).
# ---------------------------------------------------------------------------
cat > /usr/local/bin/cubeos-docker-preload.sh << 'PRELOAD'
#!/bin/bash
# Fallback Docker image loader — only runs if cache dir has tarballs
set -uo pipefail

CACHE_DIR="/var/cache/cubeos-images"
LOG="/var/log/cubeos-docker-preload.log"

log() {
    local msg="$(date '+%H:%M:%S') $*"
    echo "$msg" >> "$LOG"
    echo "$msg" >&2
}

if [ ! -d "$CACHE_DIR" ] || [ -z "$(ls -A $CACHE_DIR/*.tar 2>/dev/null)" ]; then
    log "No cached tarballs found — images should be pre-loaded. Exiting."
    exit 0
fi

log "=== Fallback Docker Image Preload ==="
log "WARNING: Found tarballs in ${CACHE_DIR} — loading (this should not happen in normal Alpha.9 flow)"

for i in $(seq 1 120); do
    docker info &>/dev/null && break
    sleep 1
done

LOADED=0
FAILED=0
for tarball in $(ls -S -r "$CACHE_DIR"/*.tar 2>/dev/null); do
    [ -f "$tarball" ] || continue
    NAME=$(basename "$tarball" .tar)
    if docker load < "$tarball" 2>&1; then
        log "  OK: ${NAME}"
        LOADED=$((LOADED + 1))
    else
        log "  FAILED: ${NAME}"
        FAILED=$((FAILED + 1))
    fi
done

log "Fallback preload complete: ${LOADED} loaded, ${FAILED} failed"
if [ "$FAILED" -eq 0 ]; then
    rm -rf "$CACHE_DIR"
    systemctl disable cubeos-docker-preload.service 2>/dev/null || true
fi
PRELOAD
chmod +x /usr/local/bin/cubeos-docker-preload.sh

cat > /etc/systemd/system/cubeos-docker-preload.service << 'SYSTEMD'
[Unit]
Description=CubeOS Docker Image Preload (fallback)
After=docker.service
Requires=docker.service
Before=cubeos-init.service
ConditionPathExists=/var/cache/cubeos-images

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/cubeos-docker-preload.sh
TimeoutStartSec=infinity

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl enable cubeos-docker-preload.service 2>/dev/null || true

echo "[05] Docker preload: images will be baked in at CI time (Phase 1b)."
echo "[05] Fallback preload service installed (only activates if tarballs found)."
