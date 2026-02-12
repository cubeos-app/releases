#!/bin/bash
# =============================================================================
# cubeos-first-boot.sh — CubeOS First Boot Orchestrator
# =============================================================================
# Runs ONCE on the very first power-on of a new CubeOS device.
# Brings the system from a blank SD card image to a fully functional
# WiFi access point with all 5 core services running and the setup
# wizard ready for the user.
#
# Timeline target: ~60-90 seconds on Pi 5 (with pre-loaded images)
#
# After this script completes:
#   - WiFi AP broadcasting CubeOS-XXYYZZ (from MAC)
#   - Pi-hole serving DNS/DHCP
#   - NPM reverse proxy running
#   - HAL providing hardware abstraction
#   - API running with fresh database (setup_complete = false)
#   - Dashboard showing setup wizard at http://cubeos.cube
#
# The user then connects to the AP, opens the browser, completes
# the wizard, which customizes the system to their preferences.
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

echo "============================================================"
echo "  CubeOS First Boot — v${CUBEOS_VERSION}"
echo "  $(date)"
echo "============================================================"
echo ""

# Track timing
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
# Step 1: Hardware watchdog
# ---------------------------------------------------------------------------
echo "[BOOT] Step 1/9: Enabling hardware watchdog..."
if [ -e /dev/watchdog ]; then
    systemctl start watchdog 2>/dev/null || true
    echo "[BOOT]   Watchdog enabled (15s timeout)"
else
    echo "[BOOT]   No watchdog device found (VM or non-Pi hardware?)"
fi

# ---------------------------------------------------------------------------
# Step 2: Generate AP credentials from MAC address
# ---------------------------------------------------------------------------
echo "[BOOT] Step 2/9: Generating WiFi AP credentials..."
/usr/local/bin/cubeos-generate-ap-creds.sh

# Source the generated credentials
source "${CONFIG_DIR}/ap.env" 2>/dev/null || true
echo "[BOOT]   SSID: ${CUBEOS_AP_SSID:-CubeOS-Setup}"
echo "[BOOT]   Key:  ${CUBEOS_AP_KEY:-cubeos-setup}"

# ---------------------------------------------------------------------------
# Step 3: Generate secrets
# ---------------------------------------------------------------------------
echo "[BOOT] Step 3/9: Generating device secrets..."
/usr/local/bin/cubeos-generate-secrets.sh

# ---------------------------------------------------------------------------
# Step 4: Wait for Docker, initialize Swarm
# ---------------------------------------------------------------------------
echo "[BOOT] Step 4/9: Initializing Docker Swarm..."

wait_for_service "Docker" "docker info" 60 || {
    echo "[BOOT] FATAL: Docker failed to start. Cannot continue."
    exit 1
}

if docker info 2>/dev/null | grep -q "Swarm: active"; then
    echo "[BOOT]   Swarm already active (unexpected on first boot)."
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

# Create overlay network for Swarm services
if ! docker network ls --format '{{.Name}}' | grep -q "^cubeos$"; then
    echo "[BOOT]   Creating cubeos overlay network..."
    docker network create \
        --driver overlay \
        --attachable \
        --subnet 172.20.0.0/24 \
        cubeos 2>/dev/null || true
fi

# Create Docker Swarm secrets from secrets.env
source "${CONFIG_DIR}/secrets.env" 2>/dev/null || true
if [ -n "${CUBEOS_JWT_SECRET:-}" ]; then
    echo -n "$CUBEOS_JWT_SECRET" | docker secret create jwt_secret - 2>/dev/null || true
    echo -n "$CUBEOS_API_SECRET" | docker secret create api_secret - 2>/dev/null || true
fi

echo "[BOOT]   Swarm initialized."

# ---------------------------------------------------------------------------
# Step 5: Deploy infrastructure layer (Pi-hole + NPM)
# ---------------------------------------------------------------------------
echo "[BOOT] Step 5/9: Deploying infrastructure..."

# ─── Pi-hole (Docker Compose, host network) ──────────────────
echo "[BOOT]   Deploying Pi-hole..."
source "${CONFIG_DIR}/defaults.env" 2>/dev/null || true
docker compose \
    -f "${COREAPPS_DIR}/pihole/appconfig/docker-compose.yml" \
    --env-file "${COREAPPS_DIR}/pihole/appconfig/.env" \
    up -d 2>&1 || echo "[BOOT]   WARNING: Pi-hole deploy failed"

wait_for_service "Pi-hole" "curl -sf http://127.0.0.1:6001/admin/" 60 || true

# Seed custom DNS entries for cubeos.cube
PIHOLE_HOSTS="/cubeos/coreapps/pihole/appdata/etc-pihole/hosts/custom.list"
mkdir -p "$(dirname "$PIHOLE_HOSTS")"
echo "${GATEWAY_IP} cubeos.cube" > "$PIHOLE_HOSTS"
echo "${GATEWAY_IP} api.cubeos.cube" >> "$PIHOLE_HOSTS"
echo "${GATEWAY_IP} npm.cubeos.cube" >> "$PIHOLE_HOSTS"

# Reload Pi-hole DNS if it's running
docker exec cubeos-pihole pihole restartdns 2>/dev/null || true

# ─── NPM (Docker Compose, host network) ─────────────────────
echo "[BOOT]   Deploying NPM..."
docker compose \
    -f "${COREAPPS_DIR}/npm/appconfig/docker-compose.yml" \
    up -d 2>&1 || echo "[BOOT]   WARNING: NPM deploy failed"

wait_for_service "NPM" "curl -sf http://127.0.0.1:81/api/" 60 || true

# ---------------------------------------------------------------------------
# Step 6: Start WiFi Access Point
# ---------------------------------------------------------------------------
echo "[BOOT] Step 6/9: Starting WiFi Access Point..."

# Ensure WiFi radio is unblocked
rfkill unblock wifi 2>/dev/null || true

# Apply Netplan to ensure static IP on wlan0
netplan apply 2>/dev/null || true
sleep 2

# Start hostapd
systemctl unmask hostapd 2>/dev/null || true
systemctl start hostapd 2>/dev/null && {
    echo "[BOOT]   AP started: ${CUBEOS_AP_SSID:-CubeOS-Setup}"
} || {
    echo "[BOOT]   WARNING: hostapd failed to start"
    echo "[BOOT]   Users can still connect via ethernet to ${GATEWAY_IP}"
}

# ---------------------------------------------------------------------------
# Step 7: Deploy HAL (hardware abstraction)
# ---------------------------------------------------------------------------
echo "[BOOT] Step 7/9: Deploying HAL..."

docker compose \
    -f "${COREAPPS_DIR}/cubeos-hal/appconfig/docker-compose.yml" \
    up -d 2>&1 || echo "[BOOT]   WARNING: HAL deploy failed"

wait_for_service "HAL" "curl -sf http://127.0.0.1:6013/health" 30 || true

# ---------------------------------------------------------------------------
# Step 8: Deploy platform layer (API + Dashboard as Swarm stacks)
# ---------------------------------------------------------------------------
echo "[BOOT] Step 8/9: Deploying platform services..."

# ─── CubeOS API ─────────────────────────────────────────────
echo "[BOOT]   Deploying cubeos-api stack..."
docker stack deploy \
    -c "${COREAPPS_DIR}/cubeos-api/appconfig/docker-compose.yml" \
    --resolve-image never \
    cubeos-api 2>&1 || echo "[BOOT]   WARNING: API stack deploy failed"

wait_for_service "API" "curl -sf http://127.0.0.1:6010/health" 90 || true

# ─── CubeOS Dashboard ───────────────────────────────────────
echo "[BOOT]   Deploying cubeos-dashboard stack..."
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
        echo "  ✓  ${name}"
    else
        echo "  ✗  ${name}"
    fi
}

check_status "Pi-hole (DNS/DHCP)     :6001" "curl -sf http://127.0.0.1:6001/admin/"
check_status "NPM (Reverse Proxy)    :81  " "curl -sf http://127.0.0.1:81/api/"
check_status "HAL (Hardware)         :6013" "curl -sf http://127.0.0.1:6013/health"
check_status "API (Backend)          :6010" "curl -sf http://127.0.0.1:6010/health"
check_status "Dashboard (Frontend)   :6011" "curl -sf http://127.0.0.1:6011/"
check_status "hostapd (WiFi AP)           " "systemctl is-active hostapd"

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
