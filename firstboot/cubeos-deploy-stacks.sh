#!/bin/bash
# =============================================================================
# cubeos-deploy-stacks.sh — Deploy/redeploy Swarm stacks (v4 - Alpha.6)
# =============================================================================
# Manual recovery helper for when first boot partially failed.
# Ensures IP, Swarm, overlay network, then deploys ALL stacks.
#
# v4 — ALPHA.6 FIXES:
#   1. Network name: cubeos-network (was cubeos)
#   2. Overlay subnet: 10.42.25.0/24 (was 172.20.0.0/24)
#   3. Deploys ALL stacks (was only api + dashboard)
#   4. No Docker secrets — API uses env_file
#   5. Swarm init captures stderr
#
# Usage: cubeos-deploy-stacks.sh
# =============================================================================
set -euo pipefail

GATEWAY_IP="10.42.24.1"
OVERLAY_SUBNET="10.42.25.0/24"
NETWORK_NAME="cubeos-network"
CONFIG_DIR="/cubeos/config"
COREAPPS_DIR="/cubeos/coreapps"

echo "=== CubeOS Stack Recovery (alpha.6) ==="
echo "$(date)"
echo ""

# ── Ensure wlan0 has our IP ──────────────────────────────────────────
echo "[RECOVER] Ensuring wlan0 has ${GATEWAY_IP}..."
ip link set wlan0 up 2>/dev/null || true
ip addr add "${GATEWAY_IP}/24" dev wlan0 2>/dev/null || true

if ! ip addr show wlan0 2>/dev/null | grep -q "$GATEWAY_IP"; then
    echo "[RECOVER] WARNING: wlan0 still doesn't have ${GATEWAY_IP}"
fi

# ── Ensure Docker ────────────────────────────────────────────────────
if ! docker info &>/dev/null; then
    echo "[RECOVER] Docker not running. Starting..."
    systemctl start docker
    sleep 5
    docker info &>/dev/null || { echo "FATAL: Docker won't start."; exit 1; }
fi

# ── Ensure Swarm ─────────────────────────────────────────────────────
if ! docker info 2>/dev/null | grep -q "Swarm: active"; then
    echo "[RECOVER] Initializing Swarm..."
    SWARM_OUTPUT=$(docker swarm init \
        --advertise-addr "$GATEWAY_IP" \
        --listen-addr "0.0.0.0:2377" \
        --task-history-limit 1 2>&1) || {
        echo "[RECOVER] Attempt 1 failed: ${SWARM_OUTPUT}"
        SWARM_OUTPUT=$(docker swarm init \
            --listen-addr "0.0.0.0:2377" \
            --task-history-limit 1 2>&1) || {
            echo "FATAL: Cannot initialize Swarm: ${SWARM_OUTPUT}"
            exit 1
        }
    }
fi
echo "[RECOVER] Swarm active."

# ── Ensure overlay network ───────────────────────────────────────────
NETWORK_EXISTS=$(docker network ls --format '{{.Name}}' | grep -c "^${NETWORK_NAME}$" || true)
if [ "$NETWORK_EXISTS" -eq 0 ]; then
    echo "[RECOVER] Creating ${NETWORK_NAME} overlay network..."
    docker network create --driver overlay --attachable \
        --subnet "$OVERLAY_SUBNET" "$NETWORK_NAME" 2>/dev/null || true
fi

# Also remove old 'cubeos' network if it exists (alpha.5 leftover)
if docker network ls --format '{{.Name}}' | grep -q "^cubeos$"; then
    echo "[RECOVER] Removing old 'cubeos' network (alpha.5 leftover)..."
    docker network rm cubeos 2>/dev/null || true
fi
echo "[RECOVER] ${NETWORK_NAME} overlay ready."

# ── Ensure compose services ─────────────────────────────────────────
echo "[RECOVER] Ensuring compose services..."
for svc_dir in pihole npm cubeos-hal; do
    COMPOSE_FILE="${COREAPPS_DIR}/${svc_dir}/appconfig/docker-compose.yml"
    if [ -f "$COMPOSE_FILE" ]; then
        DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose -f "$COMPOSE_FILE" up -d --pull never 2>/dev/null && \
            echo "  [OK] ${svc_dir}" || echo "  [!!] ${svc_dir} failed"
    else
        echo "  [--] ${svc_dir}: no compose file"
    fi
done

# ── Deploy ALL Swarm stacks ──────────────────────────────────────────
echo ""
echo "[RECOVER] Deploying Swarm stacks..."

STACKS="registry cubeos-api cubeos-dashboard dozzle ollama chromadb"

for stack in $STACKS; do
    COMPOSE_FILE="${COREAPPS_DIR}/${stack}/appconfig/docker-compose.yml"
    if [ -f "$COMPOSE_FILE" ]; then
        echo "[RECOVER] Deploying ${stack}..."
        docker stack deploy -c "$COMPOSE_FILE" --resolve-image never "$stack" 2>&1 || \
            echo "[RECOVER] WARNING: ${stack} deploy failed"
    else
        echo "[RECOVER] SKIP: ${COMPOSE_FILE} not found"
    fi
done

# ── Wait for API health ─────────────────────────────────────────────
echo ""
echo "[RECOVER] Waiting for API to become healthy..."
for i in $(seq 1 60); do
    if curl -sf http://127.0.0.1:6010/health &>/dev/null; then
        echo "[RECOVER] API healthy! (${i}s)"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "[RECOVER] API still not healthy after 60s."
        echo "[RECOVER] Check: docker service logs cubeos-api_cubeos-api"
    fi
    sleep 2
done

echo ""
echo "=== Service Status ==="
docker service ls 2>/dev/null || true
echo ""
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
