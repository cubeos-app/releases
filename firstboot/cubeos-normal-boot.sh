#!/bin/bash
# =============================================================================
# cubeos-normal-boot.sh — CubeOS Normal Boot (every boot after first)
# =============================================================================
# On normal boots, Docker Swarm auto-reconciles all stacks. This script
# just verifies critical services and applies the saved network mode.
# Most of the work is done by Docker's own restart policies.
#
# Timeline target: ~30-40 seconds to fully operational.
# =============================================================================
set -euo pipefail

LOG_FILE="/var/log/cubeos-boot.log"
exec 1> >(tee -a "$LOG_FILE") 2>&1

GATEWAY_IP="10.42.24.1"
CONFIG_DIR="/cubeos/config"
COREAPPS_DIR="/cubeos/coreapps"

echo "============================================================"
echo "  CubeOS Normal Boot"
echo "  $(date)"
echo "============================================================"

BOOT_START=$(date +%s)

# ---------------------------------------------------------------------------
# Helper
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
    done
    echo " TIMEOUT"
    return 1
}

# ---------------------------------------------------------------------------
# Watchdog
# ---------------------------------------------------------------------------
echo "[BOOT] Enabling watchdog..."
if [ -e /dev/watchdog ]; then
    systemctl start watchdog 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Wait for Docker
# ---------------------------------------------------------------------------
wait_for_service "Docker" "docker info" 60 || {
    echo "[BOOT] FATAL: Docker not starting. Attempting restart..."
    systemctl restart docker
    wait_for_service "Docker" "docker info" 30 || exit 1
}

# ---------------------------------------------------------------------------
# Verify Swarm is active
# ---------------------------------------------------------------------------
if ! docker info 2>/dev/null | grep -q "Swarm: active"; then
    echo "[BOOT] WARNING: Swarm not active! Re-initializing..."
    docker swarm init \
        --advertise-addr "$GATEWAY_IP" \
        --force-new-cluster \
        --task-history-limit 1 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Compose services: Pi-hole, NPM, HAL (not managed by Swarm)
# ---------------------------------------------------------------------------
echo "[BOOT] Ensuring compose services are running..."

for svc_dir in pihole npm cubeos-hal; do
    COMPOSE_FILE="${COREAPPS_DIR}/${svc_dir}/appconfig/docker-compose.yml"
    if [ -f "$COMPOSE_FILE" ]; then
        docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null || \
            echo "[BOOT]   WARNING: Failed to start ${svc_dir}"
    fi
done

# Wait for DNS (critical for everything else)
wait_for_service "Pi-hole" "curl -sf http://127.0.0.1:6001/admin/" 60 || true

# ---------------------------------------------------------------------------
# Start WiFi AP
# ---------------------------------------------------------------------------
echo "[BOOT] Starting WiFi Access Point..."
rfkill unblock wifi 2>/dev/null || true
systemctl restart dhcpcd 2>/dev/null || true
sleep 1
systemctl start hostapd 2>/dev/null || \
    echo "[BOOT]   WARNING: hostapd failed"

# ---------------------------------------------------------------------------
# Swarm stacks auto-reconcile — just verify they exist
# ---------------------------------------------------------------------------
echo "[BOOT] Verifying Swarm stacks..."

for stack in cubeos-api dashboard; do
    if docker stack ls 2>/dev/null | grep -q "^${stack} "; then
        echo "[BOOT]   Stack ${stack}: present (Swarm will reconcile)"
    else
        echo "[BOOT]   Stack ${stack}: MISSING — redeploying..."
        COMPOSE_FILE="${COREAPPS_DIR}/${stack}/appconfig/docker-compose.yml"
        [ -f "$COMPOSE_FILE" ] && \
            docker stack deploy -c "$COMPOSE_FILE" --resolve-image never "$stack" 2>/dev/null || true
    fi
done

# ---------------------------------------------------------------------------
# Wait for API to be healthy
# ---------------------------------------------------------------------------
wait_for_service "API" "curl -sf http://127.0.0.1:6010/health" 60 || true

# ---------------------------------------------------------------------------
# Apply saved network mode (NAT if ONLINE_ETH or ONLINE_WIFI)
# ---------------------------------------------------------------------------
echo "[BOOT] Applying network mode..."

# Source defaults to get saved network mode
source "${CONFIG_DIR}/defaults.env" 2>/dev/null || true
NETWORK_MODE="${CUBEOS_NETWORK_MODE:-OFFLINE}"

case "$NETWORK_MODE" in
    ONLINE_ETH)
        echo "[BOOT]   Mode: ONLINE_ETH — enabling NAT via eth0"
        /usr/local/lib/cubeos/nat-enable.sh eth0
        ;;
    ONLINE_WIFI)
        echo "[BOOT]   Mode: ONLINE_WIFI — enabling NAT via wlan1"
        /usr/local/lib/cubeos/nat-enable.sh wlan1
        ;;
    OFFLINE|*)
        echo "[BOOT]   Mode: OFFLINE — no NAT"
        ;;
esac

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
BOOT_END=$(date +%s)
BOOT_DURATION=$((BOOT_END - BOOT_START))

echo ""
echo "============================================================"
echo "  CubeOS Boot Complete (${BOOT_DURATION}s)"
echo "  Dashboard: http://cubeos.cube"
echo "============================================================"
