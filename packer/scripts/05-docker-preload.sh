#!/bin/bash
# =============================================================================
# 05-docker-preload.sh — Docker image tarball preload setup
# =============================================================================
# Creates a systemd service that loads pre-baked Docker image tarballs on
# first boot. Images are loaded in SIZE ORDER (smallest first) so that
# critical small images (pihole, api, dashboard) are available even if the
# large npm image is slow on memory-constrained devices (Pi 4B 2GB).
#
# Also creates a swap file matching device RAM for low-memory devices —
# without swap, docker load of the 1.1GB npm tarball causes OOM on 2GB Pi.
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
# Configure swap (file created at RUNTIME, not build-time)
# ---------------------------------------------------------------------------
# The swap file cannot be created during Packer build because /proc/meminfo
# shows the build host's RAM (e.g. 32GB), not the target Pi's RAM (2-8GB).
# Creating a 4GB swap inside an 8GB image fills the disk.
#
# Instead: the runtime preload script creates the swap file on first boot
# using the actual device RAM. We just add the fstab entry here.
# ---------------------------------------------------------------------------
SWAP_FILE="/var/swap.cubeos"

if ! grep -q "$SWAP_FILE" /etc/fstab 2>/dev/null; then
    echo "$SWAP_FILE none swap sw,nofail 0 0" >> /etc/fstab
    echo "[05] Added swap to /etc/fstab (file created at first boot)"
fi

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
# - Enables swap before loading to prevent OOM on 2GB devices
# - Cleans cache only after ALL images successfully loaded
# - Self-disables after successful completion
# =============================================================================
set -euo pipefail

CACHE_DIR="/var/cache/cubeos-images"
LOG="/var/log/cubeos-docker-preload.log"
SWAP_FILE="/var/swap.cubeos"

exec 1> >(tee -a "$LOG") 2>&1

echo "=== CubeOS Docker Image Preload ==="
echo "Started at: $(date)"
echo "Device RAM: $(free -h | awk '/^Mem:/{print $2}')"

if [ ! -d "$CACHE_DIR" ] || [ -z "$(ls -A $CACHE_DIR/*.tar 2>/dev/null)" ]; then
    echo "No cached image tarballs found. Skipping preload."
    exit 0
fi

# ── Enable swap (size should match device RAM) ─────────────────────────
RAM_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
DESIRED_MB=${RAM_MB:-2048}
[ "$DESIRED_MB" -lt 1024 ] 2>/dev/null && DESIRED_MB=1024
[ "$DESIRED_MB" -gt 4096 ] 2>/dev/null && DESIRED_MB=4096
echo "Device RAM: ${RAM_MB}MB — desired swap: ${DESIRED_MB}MB"

# Create or resize swap file to match device RAM
if [ -f "$SWAP_FILE" ]; then
    CURRENT_MB=$(( $(stat -c%s "$SWAP_FILE" 2>/dev/null || echo 0) / 1048576 ))
    if [ "$CURRENT_MB" -ne "$DESIRED_MB" ]; then
        echo "Swap file is ${CURRENT_MB}MB but need ${DESIRED_MB}MB — resizing..."
        swapoff "$SWAP_FILE" 2>/dev/null || true
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$DESIRED_MB" 2>/dev/null
        chmod 600 "$SWAP_FILE"
        mkswap "$SWAP_FILE" >/dev/null
        echo "  Swap resized to ${DESIRED_MB}MB."
    fi
else
    echo "Creating ${DESIRED_MB}MB swap file (matching ${RAM_MB}MB RAM)..."
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$DESIRED_MB" 2>/dev/null
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" >/dev/null
    echo "  Swap file created (${DESIRED_MB}MB)."
fi

if [ -f "$SWAP_FILE" ] && ! swapon --show | grep -q "$SWAP_FILE"; then
    echo "Enabling swap ($SWAP_FILE)..."
    swapon "$SWAP_FILE" 2>/dev/null && echo "  Swap enabled." || echo "  Swap enable failed (non-fatal)."
fi
echo "Memory status:"
free -h

# ── Wait for Docker ────────────────────────────────────────────────────
echo "Waiting for Docker daemon..."
for i in $(seq 1 120); do
    if docker info &>/dev/null; then
        echo "Docker is ready (${i}s)."
        break
    fi
    if [ "$i" -eq 120 ]; then
        echo "ERROR: Docker not ready after 120s. Aborting preload."
        exit 1
    fi
    sleep 1
done

# ── Sort tarballs by size (smallest first) ─────────────────────────────
echo ""
echo "Sorting images by size (smallest first)..."
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
        echo "[${COUNT}/${TOTAL}] SKIP: ${NAME} (${SIZE}) — already loaded"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    echo "[${COUNT}/${TOTAL}] Loading: ${NAME} (${SIZE})..."
    LOAD_START=$(date +%s)

    if docker load < "$tarball" 2>&1; then
        LOAD_END=$(date +%s)
        LOAD_TIME=$((LOAD_END - LOAD_START))
        echo "  OK: ${NAME} (${LOAD_TIME}s)"
        LOADED=$((LOADED + 1))
    else
        echo "  FAILED: ${NAME}"
        FAILED=$((FAILED + 1))
    fi

    # Log memory after each load
    echo "  Memory: $(free -h | awk '/^Mem:/{printf "used=%s free=%s avail=%s", $3, $4, $7}')"
done

echo ""
echo "Preload complete: ${LOADED} loaded, ${SKIPPED} skipped, ${FAILED} failed (of ${TOTAL} total)"
echo "Finished at: $(date)"

# ── Clean up cache ONLY if all images are accounted for ────────────────
if [ "$FAILED" -eq 0 ]; then
    echo "All images loaded successfully. Cleaning up cache..."
    rm -rf "$CACHE_DIR"
    systemctl disable cubeos-docker-preload.service 2>/dev/null || true
    echo "Preload service disabled. Cache removed."
else
    echo "WARNING: ${FAILED} images failed to load. Keeping cache for retry."
    echo "Run 'sudo systemctl restart cubeos-docker-preload' to retry."
fi

echo ""
echo "Docker images now available:"
docker images --format "  {{.Repository}}:{{.Tag}} ({{.Size}})"
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
echo "[05] Swap configured in fstab (file created at first boot matching device RAM)."
