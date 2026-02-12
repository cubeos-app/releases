#!/bin/bash
# =============================================================================
# cubeos-first-boot.sh — CubeOS First Boot Orchestrator
# =============================================================================
# Runs ONCE on the very first power-on of a new CubeOS device.
# Brings the system from a blank SD card image to a fully functional
# WiFi access point with all core services running.
#
# DESIGN PRINCIPLES:
#   1. WiFi AP starts EARLY — user sees SSID within 30s, even before
#      all services are up. Gives visual feedback that boot is working.
#   2. All docker commands use --pull never / pull_policy: never —
#      we are offline-first, never try to reach the internet.
#   3. Missing images are loaded from /var/cache/cubeos-images/ if
#      the preload service didn't finish (e.g., timeout on slow SD).
#   4. Every step is non-fatal (|| true) — partial boot is better
#      than no boot. The watchdog timer will heal remaining issues.
#   5. Swap is enabled before any heavy Docker operations.
#
# After this script completes:
#   - WiFi AP broadcasting CubeOS-XXYYZZ (from MAC)
#   - Pi-hole serving DNS/DHCP
#   - NPM reverse proxy running
#   - HAL providing hardware abstraction
#   - API running with fresh database (setup_complete = false)
#   - Dashboard showing setup wizard at http://cubeos.cube
# =============================================================================
set -euo pipefail

LOG_FILE="/var/log/cubeos-first-boot.log"
exec 1> >(tee -a "$LOG_FILE") 2>&1

CUBEOS_VERSION="0.1.0-alpha"
GATEWAY_IP="10.42.24.1"
SUBNET="10.42.24.0/24"
CONFIG_DIR="/cubeos/config"
COREAPPS_DIR="/cubeos/coreapps"
DATA_DIR="/cubeos/data"
CACHE_DIR="/var/cache/cubeos-images"
SWAP_FILE="/var/swap.cubeos"

echo "============================================================"
echo "  CubeOS First Boot — v${CUBEOS_VERSION}"
echo "  $(date)"
echo "============================================================"
echo ""

BOOT_START=$(date +%s)

# ---------------------------------------------------------------------------
# Helper: wait for a service to become healthy
# ---------------------------------------------------------------------------
wait_for_service() {
    local name="$1"
    local check_cmd="$2"
    local timeout="${3:-60}"
    local elapsed=0

    echo -n "[BOOT] Waiting for ${name}..."
    while [ $elapsed -lt $timeout ]; do
        if eval "$check_cmd" &>/dev/null; then
            echo " OK (${elapsed}s)"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        echo -n "."
    done
    echo " TIMEOUT (${timeout}s)"
    echo "[BOOT] WARNING: ${name} did not become healthy in ${timeout}s"
    return 1
}

# ---------------------------------------------------------------------------
# Helper: ensure a Docker image is loaded (from cache if needed)
# ---------------------------------------------------------------------------
ensure_image_loaded() {
    local image_ref="$1"
    local cache_name="$2"

    if docker image inspect "$image_ref" &>/dev/null; then
        return 0
    fi

    # Try loading from cache
    local tarball="${CACHE_DIR}/${cache_name}.tar"
    if [ -f "$tarball" ]; then
        echo "[BOOT]   Image ${image_ref} missing — loading from cache..."
        if docker load < "$tarball" 2>&1; then
            echo "[BOOT]   Loaded ${cache_name} from cache."
            return 0
        else
            echo "[BOOT]   FAILED to load ${cache_name} from cache."
            return 1
        fi
    fi

    echo "[BOOT]   Image ${image_ref} not available and no cached tarball."
    return 1
}

# ---------------------------------------------------------------------------
# Step 1: Enable swap (BEFORE any heavy operations)
# ---------------------------------------------------------------------------
echo "[BOOT] Step 1/9: Enabling swap and hardware watchdog..."

# Detect device RAM for swap sizing
RAM_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
DESIRED_MB=${RAM_MB:-2048}
[ "$DESIRED_MB" -lt 1024 ] 2>/dev/null && DESIRED_MB=1024
[ "$DESIRED_MB" -gt 4096 ] 2>/dev/null && DESIRED_MB=4096

if [ -f "$SWAP_FILE" ] && ! swapon --show | grep -q "$SWAP_FILE"; then
    swapon "$SWAP_FILE" 2>/dev/null && \
        echo "[BOOT]   Swap enabled ($(du -h $SWAP_FILE | cut -f1))" || \
        echo "[BOOT]   Swap enable failed (non-fatal)"
elif swapon --show | grep -q "$SWAP_FILE"; then
    echo "[BOOT]   Swap already active"
else
    echo "[BOOT]   No swap file found — creating ${DESIRED_MB}MB swap (matching ${RAM_MB}MB RAM)..."
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$DESIRED_MB" 2>/dev/null && \
        chmod 600 "$SWAP_FILE" && \
        mkswap "$SWAP_FILE" && \
        swapon "$SWAP_FILE" && \
        echo "[BOOT]   Swap created and enabled (${DESIRED_MB}MB)" || \
        echo "[BOOT]   Swap creation failed (non-fatal, but large images may be slow)"
fi

if [ -e /dev/watchdog ]; then
    systemctl start watchdog 2>/dev/null || true
    echo "[BOOT]   Watchdog enabled (15s timeout)"
else
    echo "[BOOT]   No watchdog device found"
fi

echo "[BOOT]   Memory: $(free -h | awk '/^Mem:/{printf "total=%s used=%s avail=%s", $2, $3, $7}') Swap: $(free -h | awk '/^Swap:/{printf "total=%s used=%s", $2, $3}')"

# ---------------------------------------------------------------------------
# Step 2: Generate AP credentials from MAC address
# ---------------------------------------------------------------------------
echo "[BOOT] Step 2/9: Generating WiFi AP credentials..."
/usr/local/bin/cubeos-generate-ap-creds.sh

source "${CONFIG_DIR}/ap.env" 2>/dev/null || true
echo "[BOOT]   SSID: ${CUBEOS_AP_SSID:-CubeOS-Setup}"
echo "[BOOT]   Key:  ${CUBEOS_AP_KEY:-cubeos-setup}"

# ---------------------------------------------------------------------------
# Step 3: Start WiFi Access Point EARLY (user feedback!)
# ---------------------------------------------------------------------------
echo "[BOOT] Step 3/9: Starting WiFi Access Point..."

rfkill unblock wifi 2>/dev/null || true
netplan apply 2>/dev/null || true
sleep 2

systemctl unmask hostapd 2>/dev/null || true
systemctl start hostapd 2>/dev/null && {
    echo "[BOOT]   AP started: ${CUBEOS_AP_SSID:-CubeOS-Setup}"
    echo "[BOOT]   Users can connect to WiFi now (services still loading)"
} || {
    echo "[BOOT]   WARNING: hostapd failed to start"
    echo "[BOOT]   Users can connect via ethernet to ${GATEWAY_IP}"
}

# ---------------------------------------------------------------------------
# Step 4: Generate secrets
# ---------------------------------------------------------------------------
echo "[BOOT] Step 4/9: Generating device secrets..."
/usr/local/bin/cubeos-generate-secrets.sh

# ---------------------------------------------------------------------------
# Step 5: Wait for Docker, initialize Swarm
# ---------------------------------------------------------------------------
echo "[BOOT] Step 5/9: Initializing Docker Swarm..."

wait_for_service "Docker" "docker info" 120 || {
    echo "[BOOT] FATAL: Docker failed to start. Cannot continue."
    exit 1
}

if docker info 2>/dev/null | grep -q "Swarm: active"; then
    echo "[BOOT]   Swarm already active."
else
    echo "[BOOT]   Initializing Swarm..."
    docker swarm init \
        --advertise-addr "$GATEWAY_IP" \
        --task-history-limit 1 \
        2>&1 || {
        echo "[BOOT] WARNING: Swarm init failed. Trying force-new-cluster..."
        docker swarm init \
            --advertise-addr "$GATEWAY_IP" \
            --force-new-cluster \
            --task-history-limit 1 \
            2>&1 || true
    }
fi

# Create overlay network
if ! docker network ls --format '{{.Name}}' | grep -q "^cubeos$"; then
    echo "[BOOT]   Creating cubeos overlay network..."
    docker network create \
        --driver overlay \
        --attachable \
        --subnet 172.20.0.0/24 \
        cubeos 2>/dev/null || true
fi

# Create Docker Swarm secrets
source "${CONFIG_DIR}/secrets.env" 2>/dev/null || true
if [ -n "${CUBEOS_JWT_SECRET:-}" ]; then
    echo -n "$CUBEOS_JWT_SECRET" | docker secret create jwt_secret - 2>/dev/null || true
    echo -n "$CUBEOS_API_SECRET" | docker secret create api_secret - 2>/dev/null || true
fi

echo "[BOOT]   Swarm initialized."

# ---------------------------------------------------------------------------
# Step 6: Deploy infrastructure layer (Pi-hole + NPM)
# ---------------------------------------------------------------------------
echo "[BOOT] Step 6/9: Deploying infrastructure..."

# ─── Pi-hole (Docker Compose, host network) ──────────────────
echo "[BOOT]   Deploying Pi-hole..."
ensure_image_loaded "pihole/pihole:latest" "pihole" || true

source "${CONFIG_DIR}/defaults.env" 2>/dev/null || true
DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose \
    -f "${COREAPPS_DIR}/pihole/appconfig/docker-compose.yml" \
    --env-file "${COREAPPS_DIR}/pihole/appconfig/.env" \
    up -d --pull never 2>&1 || echo "[BOOT]   WARNING: Pi-hole deploy failed"

wait_for_service "Pi-hole" "curl -sf http://127.0.0.1:6001/admin/" 90 || true

# Seed custom DNS entries
PIHOLE_HOSTS="/cubeos/coreapps/pihole/appdata/etc-pihole/hosts/custom.list"
mkdir -p "$(dirname "$PIHOLE_HOSTS")"
cat > "$PIHOLE_HOSTS" << EOF
${GATEWAY_IP} cubeos.cube
${GATEWAY_IP} api.cubeos.cube
${GATEWAY_IP} npm.cubeos.cube
EOF
docker exec cubeos-pihole pihole reloaddns 2>/dev/null || true

# ─── NPM (Docker Compose, host network) ─────────────────────
echo "[BOOT]   Deploying NPM..."
ensure_image_loaded "jc21/nginx-proxy-manager:latest" "npm" || true

DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose \
    -f "${COREAPPS_DIR}/npm/appconfig/docker-compose.yml" \
    up -d --pull never 2>&1 || echo "[BOOT]   WARNING: NPM deploy failed"

wait_for_service "NPM" "curl -sf http://127.0.0.1:81/api/" 90 || true

# ---------------------------------------------------------------------------
# Step 7: Deploy HAL (hardware abstraction)
# ---------------------------------------------------------------------------
echo "[BOOT] Step 7/9: Deploying HAL..."
ensure_image_loaded "ghcr.io/cubeos-app/hal:latest" "cubeos-hal" || true

DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose \
    -f "${COREAPPS_DIR}/cubeos-hal/appconfig/docker-compose.yml" \
    up -d --pull never 2>&1 || echo "[BOOT]   WARNING: HAL deploy failed"

wait_for_service "HAL" "curl -sf http://127.0.0.1:6013/health" 30 || true

# ---------------------------------------------------------------------------
# Step 8: Deploy platform layer (API + Dashboard as Swarm stacks)
# ---------------------------------------------------------------------------
echo "[BOOT] Step 8/9: Deploying platform services..."

# ─── CubeOS API ─────────────────────────────────────────────
echo "[BOOT]   Deploying cubeos-api stack..."
ensure_image_loaded "ghcr.io/cubeos-app/api:latest" "cubeos-api" || true

docker stack deploy \
    -c "${COREAPPS_DIR}/cubeos-api/appconfig/docker-compose.yml" \
    --resolve-image never \
    cubeos-api 2>&1 || echo "[BOOT]   WARNING: API stack deploy failed"

wait_for_service "API" "curl -sf http://127.0.0.1:6010/health" 120 || true

# ─── CubeOS Dashboard ───────────────────────────────────────
echo "[BOOT]   Deploying cubeos-dashboard stack..."
ensure_image_loaded "ghcr.io/cubeos-app/dashboard:latest" "cubeos-dashboard" || true

docker stack deploy \
    -c "${COREAPPS_DIR}/cubeos-dashboard/appconfig/docker-compose.yml" \
    --resolve-image never \
    cubeos-dashboard 2>&1 || echo "[BOOT]   WARNING: Dashboard stack deploy failed"

wait_for_service "Dashboard" "curl -sf http://127.0.0.1:6011/" 60 || true

# ---------------------------------------------------------------------------
# Step 9: Post-deploy verification and console output
# ---------------------------------------------------------------------------
echo "[BOOT] Step 9/9: Verification..."

BOOT_END=$(date +%s)
BOOT_DURATION=$((BOOT_END - BOOT_START))

echo ""
echo "============================================================"
echo "  CubeOS First Boot Complete!"
echo "  Duration: ${BOOT_DURATION}s"
echo "============================================================"
echo ""

# Service status summary
echo "  Service Status:"
echo "  ─────────────────────────────────────────"

check_status() {
    local name="$1"
    local cmd="$2"
    if eval "$cmd" &>/dev/null; then
        echo "  [OK]  ${name}"
    else
        echo "  [!!]  ${name}"
    fi
}

check_status "hostapd (WiFi AP)           " "systemctl is-active hostapd"
check_status "Pi-hole (DNS/DHCP)     :6001" "curl -sf http://127.0.0.1:6001/admin/"
check_status "NPM (Reverse Proxy)    :81  " "curl -sf http://127.0.0.1:81/api/"
check_status "HAL (Hardware)         :6013" "curl -sf http://127.0.0.1:6013/health"
check_status "API (Backend)          :6010" "curl -sf http://127.0.0.1:6010/health"
check_status "Dashboard (Frontend)   :6011" "curl -sf http://127.0.0.1:6011/"

echo ""
echo "  ─────────────────────────────────────────"
echo ""
echo "  WiFi Access Point:"
echo "    SSID:     ${CUBEOS_AP_SSID:-CubeOS-Setup}"
echo "    Password: ${CUBEOS_AP_KEY:-cubeos-setup}"
echo ""
echo "  Dashboard:"
echo "    http://cubeos.cube  or  http://${GATEWAY_IP}"
echo ""
echo "  Default Login:"
echo "    Username: admin"
echo "    Password: cubeos"
echo ""
echo "  Connect to the WiFi network and open the URL above"
echo "  to complete setup via the web wizard."
echo ""
echo "============================================================"
