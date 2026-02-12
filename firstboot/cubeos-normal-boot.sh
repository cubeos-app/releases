#!/bin/bash
# =============================================================================
# cubeos-normal-boot.sh — CubeOS Normal Boot (v2 - hardened)
# =============================================================================
# On normal boots, Docker Swarm auto-reconciles all stacks. This script
# verifies critical services and applies the saved network mode.
#
# v2 CHANGES:
#   - Explicit wlan0 IP verification (same fix as first boot)
#   - DNS resolver fallback (prevents NPM crash loop)
#   - Multi-attempt Swarm recovery
#   - Secrets recreation after Swarm recovery
# =============================================================================
set -euo pipefail

LOG_FILE="/var/log/cubeos-boot.log"
exec 1> >(tee -a "$LOG_FILE") 2>&1

GATEWAY_IP="10.42.24.1"
CONFIG_DIR="/cubeos/config"
COREAPPS_DIR="/cubeos/coreapps"
SWAP_FILE="/var/swap.cubeos"

echo "============================================================"
echo "  CubeOS Normal Boot — $(date)"
echo "============================================================"

BOOT_START=$(date +%s)

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------
wait_for() {
    local name="$1" check_cmd="$2" timeout="${3:-60}" interval="${4:-2}" elapsed=0
    echo -n "[BOOT] Waiting for ${name}..."
    while [ $elapsed -lt $timeout ]; do
        if eval "$check_cmd" &>/dev/null; then echo " OK (${elapsed}s)"; return 0; fi
        sleep "$interval"; elapsed=$((elapsed + interval)); echo -n "."
    done
    echo " TIMEOUT (${timeout}s)"; return 1
}

# =========================================================================
# Swap + Watchdog
# =========================================================================
echo "[BOOT] Enabling swap and watchdog..."
if [ -f "$SWAP_FILE" ] && ! swapon --show | grep -q "$SWAP_FILE"; then
    swapon "$SWAP_FILE" 2>/dev/null || true
fi
[ -e /dev/watchdog ] && systemctl start watchdog 2>/dev/null || true

# =========================================================================
# Ensure wlan0 has our IP (same fix as first boot — netplan can be slow)
# =========================================================================
echo "[BOOT] Ensuring wlan0 has ${GATEWAY_IP}..."
ip link set wlan0 up 2>/dev/null || true
ip addr add "${GATEWAY_IP}/24" dev wlan0 2>/dev/null || true
netplan apply 2>/dev/null || true

# =========================================================================
# Docker
# =========================================================================
wait_for "Docker" "docker info" 60 || {
    echo "[BOOT] Docker not starting — restarting daemon..."
    systemctl restart docker
    wait_for "Docker" "docker info" 30 || exit 1
}

# =========================================================================
# Swarm (verify or recover with multi-attempt)
# =========================================================================
if ! docker info 2>/dev/null | grep -q "Swarm: active"; then
    echo "[BOOT] Swarm not active! Recovering..."

    docker swarm init \
        --advertise-addr "$GATEWAY_IP" \
        --listen-addr "0.0.0.0:2377" \
        --force-new-cluster \
        --task-history-limit 1 2>&1 || \
    docker swarm init \
        --listen-addr "0.0.0.0:2377" \
        --task-history-limit 1 2>&1 || \
    echo "[BOOT] WARNING: Swarm recovery failed — stacks may not work"

    # Recreate secrets after Swarm recovery
    if docker info 2>/dev/null | grep -q "Swarm: active"; then
        echo "[BOOT] Recreating Docker secrets after Swarm recovery..."
        source "${CONFIG_DIR}/secrets.env" 2>/dev/null || true
        if [ -n "${CUBEOS_JWT_SECRET:-}" ]; then
            echo -n "$CUBEOS_JWT_SECRET" | docker secret create jwt_secret - 2>/dev/null || true
            echo -n "$CUBEOS_API_SECRET" | docker secret create api_secret - 2>/dev/null || true
        fi
    fi
fi

# =========================================================================
# Compose services (Pi-hole, NPM, HAL)
# =========================================================================
echo "[BOOT] Starting compose services..."
for svc_dir in pihole npm cubeos-hal; do
    COMPOSE_FILE="${COREAPPS_DIR}/${svc_dir}/appconfig/docker-compose.yml"
    [ -f "$COMPOSE_FILE" ] && \
        docker compose -f "$COMPOSE_FILE" up -d --pull never 2>/dev/null || true
done

# Wait for DNS (faster port-based check)
wait_for "Pi-hole DNS" "dig @127.0.0.1 localhost +short +timeout=1 +tries=1" 60 1 || true

# =========================================================================
# DNS resolver fallback (prevents NPM crash loop after reboot)
# =========================================================================
if ! grep -q "^nameserver" /etc/resolv.conf 2>/dev/null; then
    echo "[BOOT] Fixing /etc/resolv.conf (no nameserver)"
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
fi

# =========================================================================
# WiFi AP
# =========================================================================
echo "[BOOT] Starting WiFi Access Point..."
rfkill unblock wifi 2>/dev/null || true
systemctl start hostapd 2>/dev/null || echo "[BOOT]   WARNING: hostapd failed"

# =========================================================================
# Swarm stacks (auto-reconcile — redeploy if missing)
# =========================================================================
if docker info 2>/dev/null | grep -q "Swarm: active"; then
    echo "[BOOT] Verifying Swarm stacks..."
    for stack in cubeos-api cubeos-dashboard; do
        if docker stack ls 2>/dev/null | grep -q "^${stack} "; then
            echo "[BOOT]   Stack ${stack}: present (Swarm will reconcile)"
        else
            echo "[BOOT]   Stack ${stack}: MISSING — redeploying..."
            COMPOSE_FILE="${COREAPPS_DIR}/${stack}/appconfig/docker-compose.yml"
            [ -f "$COMPOSE_FILE" ] && \
                docker stack deploy -c "$COMPOSE_FILE" --resolve-image never "$stack" 2>/dev/null || true
        fi
    done
fi

wait_for "API" "curl -sf http://127.0.0.1:6010/health" 60 || true

# =========================================================================
# Network mode
# =========================================================================
echo "[BOOT] Applying network mode..."
source "${CONFIG_DIR}/defaults.env" 2>/dev/null || true

case "${CUBEOS_NETWORK_MODE:-OFFLINE}" in
    ONLINE_ETH)
        echo "[BOOT]   Mode: ONLINE_ETH — NAT via eth0"
        /usr/local/lib/cubeos/nat-enable.sh eth0 2>/dev/null || true
        ;;
    ONLINE_WIFI)
        echo "[BOOT]   Mode: ONLINE_WIFI — NAT via wlan1"
        /usr/local/lib/cubeos/nat-enable.sh wlan1 2>/dev/null || true
        ;;
    OFFLINE|*)
        echo "[BOOT]   Mode: OFFLINE"
        ;;
esac

# =========================================================================
# Done
# =========================================================================
BOOT_END=$(date +%s)
echo ""
echo "============================================================"
echo "  CubeOS Boot Complete ($((BOOT_END - BOOT_START))s)"
echo "  Dashboard: http://cubeos.cube"
echo "============================================================"
