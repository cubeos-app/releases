#!/bin/bash
# =============================================================================
# CubeOS Watchdog Health Check (v2 - hardened)
# =============================================================================
# Runs every 60s via cubeos-watchdog.timer. Self-heals critical services.
#
# v2 CHANGES:
#   - Recovers wlan0 IP if it vanishes
#   - Fixes /etc/resolv.conf (prevents NPM crash loop)
#   - Recovers Swarm + recreates secrets if Swarm died
#   - Works during first boot (removed setup_complete gate for compose services)
#   - Checks compose services always, not just after setup
# =============================================================================

GATEWAY_IP="10.42.24.1"
CONFIG_DIR="/cubeos/config"
COREAPPS_DIR="/cubeos/coreapps"

declare -A COMPOSE_SERVICES=(
    ["cubeos-pihole"]="pihole"
    ["cubeos-npm"]="npm"
    ["cubeos-hal"]="cubeos-hal"
)

declare -A SWARM_STACKS=(
    ["cubeos-api"]="cubeos-api"
    ["cubeos-dashboard"]="cubeos-dashboard"
)

# ── Docker daemon ────────────────────────────────────────────────────
if ! docker info &>/dev/null; then
    echo "[WATCHDOG] Docker is down! Restarting..."
    systemctl restart docker
    sleep 10
    docker info &>/dev/null || { echo "[WATCHDOG] Docker still down. Exiting."; exit 1; }
fi

# ── wlan0 IP check (can vanish after netplan changes or crashes) ────
if ! ip addr show wlan0 2>/dev/null | grep -q "$GATEWAY_IP"; then
    echo "[WATCHDOG] wlan0 missing ${GATEWAY_IP}! Re-adding..."
    ip link set wlan0 up 2>/dev/null || true
    ip addr add "${GATEWAY_IP}/24" dev wlan0 2>/dev/null || true
fi

# ── DNS resolver check (prevents NPM crash loop) ───────────────────
if ! grep -q "^nameserver" /etc/resolv.conf 2>/dev/null; then
    echo "[WATCHDOG] /etc/resolv.conf has no nameserver! Fixing..."
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
fi

# ── Compose services (always check, even before setup_complete) ─────
for svc in "${!COMPOSE_SERVICES[@]}"; do
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${svc}$"; then
        echo "[WATCHDOG] ${svc} not running. Restarting..."
        COMPOSE_FILE="${COREAPPS_DIR}/${COMPOSE_SERVICES[$svc]}/appconfig/docker-compose.yml"
        [ -f "$COMPOSE_FILE" ] && \
            docker compose -f "$COMPOSE_FILE" up -d --pull never 2>/dev/null || true
    fi
done

# ── Swarm health + recovery ─────────────────────────────────────────
if ! docker info 2>/dev/null | grep -q "Swarm: active"; then
    echo "[WATCHDOG] Swarm not active! Recovering..."

    # Multi-attempt recovery
    docker swarm init \
        --advertise-addr "$GATEWAY_IP" \
        --listen-addr "0.0.0.0:2377" \
        --force-new-cluster \
        --task-history-limit 1 2>/dev/null || \
    docker swarm init \
        --listen-addr "0.0.0.0:2377" \
        --task-history-limit 1 2>/dev/null || true

    # Recreate secrets after Swarm recovery
    if docker info 2>/dev/null | grep -q "Swarm: active"; then
        echo "[WATCHDOG] Swarm recovered. Recreating secrets..."
        source "${CONFIG_DIR}/secrets.env" 2>/dev/null || true
        if [ -n "${CUBEOS_JWT_SECRET:-}" ]; then
            echo -n "$CUBEOS_JWT_SECRET" | docker secret create jwt_secret - 2>/dev/null || true
            echo -n "$CUBEOS_API_SECRET" | docker secret create api_secret - 2>/dev/null || true
        fi
        # Recreate overlay network
        docker network create --driver overlay --attachable --subnet 172.20.0.0/24 cubeos 2>/dev/null || true
    fi
fi

# ── Swarm stacks (redeploy if missing) ──────────────────────────────
if docker info 2>/dev/null | grep -q "Swarm: active"; then
    for stack in "${!SWARM_STACKS[@]}"; do
        if ! docker stack ls 2>/dev/null | grep -q "^${stack} "; then
            echo "[WATCHDOG] Stack ${stack} missing. Re-deploying..."
            COMPOSE_FILE="${COREAPPS_DIR}/${SWARM_STACKS[$stack]}/appconfig/docker-compose.yml"
            [ -f "$COMPOSE_FILE" ] && \
                docker stack deploy -c "$COMPOSE_FILE" --resolve-image never "$stack" 2>/dev/null || true
        fi
    done
fi

# ── hostapd ─────────────────────────────────────────────────────────
if ! systemctl is-active --quiet hostapd; then
    echo "[WATCHDOG] hostapd is down! Restarting..."
    rfkill unblock wifi 2>/dev/null || true
    systemctl start hostapd 2>/dev/null || true
fi

# ── Swap ────────────────────────────────────────────────────────────
SWAP_FILE="/var/swap.cubeos"
if ! swapon --show | grep -q .; then
    [ -f "$SWAP_FILE" ] && swapon "$SWAP_FILE" 2>/dev/null || true
fi

# ── Disk space ──────────────────────────────────────────────────────
FREE_KB=$(df /cubeos/data 2>/dev/null | tail -1 | awk '{print $4}')
if [ -n "${FREE_KB:-}" ] && [ "$FREE_KB" -lt 512000 ]; then
    echo "[WATCHDOG] WARNING: Low disk space! ${FREE_KB}KB free on /cubeos/data"
fi
