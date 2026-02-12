#!/bin/bash
# =============================================================================
# cubeos-deploy-stacks.sh — Deploy/redeploy Swarm stacks
# =============================================================================
# Manual recovery helper for when first boot partially failed.
# Ensures IP, Swarm, secrets, overlay network, then deploys stacks.
#
# Usage: cubeos-deploy-stacks.sh
# =============================================================================
set -euo pipefail

GATEWAY_IP="10.42.24.1"
CONFIG_DIR="/cubeos/config"
COREAPPS_DIR="/cubeos/coreapps"

echo "=== CubeOS Stack Recovery ==="
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
    docker swarm init \
        --advertise-addr "$GATEWAY_IP" \
        --listen-addr "0.0.0.0:2377" \
        --task-history-limit 1 2>&1 || \
    docker swarm init \
        --listen-addr "0.0.0.0:2377" \
        --task-history-limit 1 2>&1 || {
        echo "FATAL: Cannot initialize Swarm."
        exit 1
    }
fi
echo "[RECOVER] Swarm active."

# ── Ensure overlay network ───────────────────────────────────────────
if ! docker network ls --format '{{.Name}}' | grep -q "^cubeos$"; then
    echo "[RECOVER] Creating cubeos overlay network..."
    docker network create --driver overlay --attachable --subnet 172.20.0.0/24 cubeos 2>/dev/null || true
fi

# ── Ensure secrets ───────────────────────────────────────────────────
if [ ! -f "${CONFIG_DIR}/secrets.env" ]; then
    echo "FATAL: ${CONFIG_DIR}/secrets.env not found! Run cubeos-generate-secrets.sh first."
    exit 1
fi

source "${CONFIG_DIR}/secrets.env"

echo "[RECOVER] Creating Docker secrets..."
echo -n "$CUBEOS_JWT_SECRET" | docker secret create jwt_secret - 2>/dev/null && \
    echo "  Created jwt_secret" || echo "  jwt_secret already exists"
echo -n "$CUBEOS_API_SECRET" | docker secret create api_secret - 2>/dev/null && \
    echo "  Created api_secret" || echo "  api_secret already exists"

# ── Deploy stacks ────────────────────────────────────────────────────
for stack in cubeos-api cubeos-dashboard; do
    COMPOSE_FILE="${COREAPPS_DIR}/${stack}/appconfig/docker-compose.yml"
    if [ -f "$COMPOSE_FILE" ]; then
        echo "[RECOVER] Deploying ${stack}..."
        docker stack deploy -c "$COMPOSE_FILE" --resolve-image never "$stack" 2>&1 || \
            echo "[RECOVER] WARNING: ${stack} deploy failed"
    else
        echo "[RECOVER] WARNING: ${COMPOSE_FILE} not found!"
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
