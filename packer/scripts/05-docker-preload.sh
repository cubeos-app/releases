#!/bin/bash
# =============================================================================
# 05-docker-preload.sh — Docker image tarball preload setup
# =============================================================================
# Creates a systemd service that loads pre-baked Docker image tarballs on
# first boot. Images are loaded in SIZE ORDER (smallest first) so that
# critical small images (pihole, api, dashboard) are available even if the
# large npm image is slow on memory-constrained devices (Pi 4B 2GB).
#
# v3: NO swap file — ZRAM is configured in golden base v1.1.0+
#     NO exec/tee — logging via function (prevents systemd deadlock)
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
# NO swap file configuration
# ---------------------------------------------------------------------------
# Golden base v1.1.0+ uses ZRAM for swap (2x RAM, lz4 compression).
# SD card swap files are harmful: slow, wear out the SD card, and
# the 2-4GB file wastes precious disk space.
#
# If /var/swap.cubeos exists in fstab from a previous build, REMOVE it.
# ---------------------------------------------------------------------------
if grep -q "/var/swap.cubeos" /etc/fstab 2>/dev/null; then
    echo "[05] Removing obsolete /var/swap.cubeos from fstab (ZRAM handles swap now)"
    sed -i '\|/var/swap.cubeos|d' /etc/fstab
fi
# Also remove the file itself if it somehow exists
rm -f /var/swap.cubeos

# ---------------------------------------------------------------------------
# Create the preload script (runs on real Pi hardware, native speed)
# ---------------------------------------------------------------------------
cat > /usr/local/bin/cubeos-docker-preload.sh << 'PRELOAD'
#!/bin/bash
# =============================================================================
# CubeOS Docker Image Preload — loads cached tarballs into Docker Engine
# =============================================================================
# - Loads images in SIZE ORDER (smallest first) for fastest availability
# - Idempotent: skips images already present in Docker
# - Uses ZRAM swap (no SD card swap files)
# - Cleans cache only after ALL images successfully loaded
# - Self-disables after successful completion
#
# v3: NO exec/tee (prevents systemd deadlock), logging via function
# =============================================================================
set -uo pipefail

CACHE_DIR="/var/cache/cubeos-images"
LOG="/var/log/cubeos-docker-preload.log"

# Logging — write to file AND stderr (journalctl captures stderr)
log() {
    local msg
    msg="$(date '+%H:%M:%S') $*"
    echo "$msg" >> "$LOG"
    echo "$msg" >&2
}

log "=== CubeOS Docker Image Preload ==="
log "Started at: $(date)"
log "Device RAM: $(free -h | awk '/^Mem:/{print $2}')"

if [ ! -d "$CACHE_DIR" ] || [ -z "$(ls -A $CACHE_DIR/*.tar 2>/dev/null)" ]; then
    log "No cached image tarballs found. Skipping preload."
    exit 0
fi

# ── Verify ZRAM swap is active ─────────────────────────────────────────
if swapon --show 2>/dev/null | grep -q zram; then
    log "ZRAM swap: active"
else
    log "ZRAM swap not active — starting..."
    systemctl start systemd-zram-setup@zram0.service 2>/dev/null || true
    sleep 2
    if swapon --show 2>/dev/null | grep -q zram; then
        log "ZRAM swap: started"
    else
        log "WARNING: ZRAM swap not available — large images may OOM on 2GB devices"
    fi
fi
log "Memory status:"
free -h >> "$LOG" 2>&1
free -h >&2

# ── Wait for Docker ────────────────────────────────────────────────────
log "Waiting for Docker daemon..."
for i in $(seq 1 120); do
    if docker info &>/dev/null; then
        log "Docker is ready (${i}s)."
        break
    fi
    if [ "$i" -eq 120 ]; then
        log "ERROR: Docker not ready after 120s. Aborting preload."
        exit 1
    fi
    sleep 1
done

# ── Sort tarballs by size (smallest first) ─────────────────────────────
log ""
log "Sorting images by size (smallest first)..."
SORTED_TARBALLS=$(ls -S -r "$CACHE_DIR"/*.tar 2>/dev/null)

TOTAL=$(echo "$SORTED_TARBALLS" | wc -l)
LOADED=0
SKIPPED=0
FAILED=0
COUNT=0

for tarball in $SORTED_TARBALLS; do
    [ -f "$tarball" ] || continue
    COUNT=$((COUNT + 1))
    NAME=$(basename "$tarball" .tar)
    SIZE=$(du -h "$tarball" | cut -f1)

    # Check if image is already loaded in Docker (makes this idempotent)
    IMAGE_REF=$(tar -xf "$tarball" -O manifest.json 2>/dev/null | \
        python3 -c "import sys,json; m=json.load(sys.stdin); print(m[0].get('RepoTags',[''])[0])" 2>/dev/null || echo "")

    if [ -n "$IMAGE_REF" ] && docker image inspect "$IMAGE_REF" &>/dev/null; then
        log "[${COUNT}/${TOTAL}] SKIP: ${NAME} (${SIZE}) — already loaded"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    log "[${COUNT}/${TOTAL}] Loading: ${NAME} (${SIZE})..."
    LOAD_START=$(date +%s)

    if docker load < "$tarball" 2>&1; then
        LOAD_END=$(date +%s)
        LOAD_TIME=$((LOAD_END - LOAD_START))
        log "  OK: ${NAME} (${LOAD_TIME}s)"
        LOADED=$((LOADED + 1))
    else
        log "  FAILED: ${NAME}"
        FAILED=$((FAILED + 1))
    fi

    # Log memory after each load
    log "  Memory: $(free -h | awk '/^Mem:/{printf "used=%s free=%s avail=%s", $3, $4, $7}')"
done

log ""
log "Preload complete: ${LOADED} loaded, ${SKIPPED} skipped, ${FAILED} failed (of ${TOTAL} total)"
log "Finished at: $(date)"

# ── Clean up cache ONLY if all images are accounted for ────────────────
if [ "$FAILED" -eq 0 ]; then
    log "All images loaded successfully. Cleaning up cache..."
    rm -rf "$CACHE_DIR"
    systemctl disable cubeos-docker-preload.service 2>/dev/null || true
    log "Preload service disabled. Cache removed."
else
    log "WARNING: ${FAILED} images failed to load. Keeping cache for retry."
    log "Run 'sudo systemctl restart cubeos-docker-preload' to retry."
fi

log ""
log "Docker images now available:"
docker images --format "  {{.Repository}}:{{.Tag}} ({{.Size}})" >> "$LOG" 2>&1
docker images --format "  {{.Repository}}:{{.Tag}} ({{.Size}})" >&2
PRELOAD

chmod +x /usr/local/bin/cubeos-docker-preload.sh

# ---------------------------------------------------------------------------
# Create systemd service
# ---------------------------------------------------------------------------
# TimeoutStartSec=infinity — the script has its own internal checks.
# On a 2GB Pi with SD card, npm alone can take 5-8 minutes to docker load.
# Killing mid-load corrupts nothing but wastes all the time spent.
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
TimeoutStartSec=infinity
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl enable cubeos-docker-preload.service 2>/dev/null || true

echo "[05] Docker preload service installed (timeout=infinity, size-ordered loading)."
echo "[05] Swap: ZRAM only (no SD card swap file)."
