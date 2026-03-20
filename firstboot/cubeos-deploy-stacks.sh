#!/bin/bash
# =============================================================================
# cubeos-deploy-stacks.sh — Deploy/redeploy Swarm stacks (v5 - Alpha.14)
# =============================================================================
# Manual recovery helper for when first boot partially failed.
# Ensures IP, Swarm, overlay network, then deploys ALL stacks.
#
# v5 — ALPHA.14:
#   - Sources defaults.env for version wiring (B59 fix)
#   - Removed ollama/chromadb from STACKS (4 stacks)
#   - 7 services total (3 compose + 4 swarm)
#
# Usage: cubeos-deploy-stacks.sh
# =============================================================================
set -euo pipefail

GATEWAY_IP="10.42.24.1"
OVERLAY_SUBNET="10.42.25.0/24"
NETWORK_NAME="cubeos-network"
HAL_OVERLAY_SUBNET="10.42.26.0/24"
HAL_NETWORK_NAME="hal-internal"
CONFIG_DIR="/cubeos/config"
COREAPPS_DIR="/cubeos/coreapps"

echo "=== CubeOS Stack Recovery (alpha.14) ==="
echo "$(date)"
echo ""

# ── Source defaults.env for version and config (B59 fix) ──────────────
source /cubeos/config/defaults.env 2>/dev/null || true
source /cubeos/coreapps/image-versions.env 2>/dev/null || true

# ── Ensure AP interface has our IP ─────────────────────────────────────
# Source detected interface names if available, fall back to wlan0
source /cubeos/config/interfaces.env 2>/dev/null || true
AP_IFACE="${CUBEOS_AP_IFACE:-wlan0}"

echo "[RECOVER] Ensuring ${AP_IFACE} has ${GATEWAY_IP}..."
ip link set "${AP_IFACE}" up 2>/dev/null || true
ip addr add "${GATEWAY_IP}/24" dev "${AP_IFACE}" 2>/dev/null || true

if ! ip addr show "${AP_IFACE}" 2>/dev/null | grep -q "$GATEWAY_IP"; then
    echo "[RECOVER] WARNING: ${AP_IFACE} still doesn't have ${GATEWAY_IP}"
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

# ── Detect docker_gwbridge gateway (runtime) ──────────────────────────
# docker_gwbridge subnet is assigned by Docker at Swarm init and is NOT
# predictable — it depends on daemon.json address pools.  Detect the
# actual gateway so compose variable substitution resolves correctly.
DETECTED_GW=$(docker network inspect docker_gwbridge \
    --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null) || true
if [ -n "$DETECTED_GW" ]; then
    export DOCKER_HOST_GW="$DETECTED_GW"
    echo "[RECOVER] Docker host gateway (detected): ${DOCKER_HOST_GW}"
else
    export DOCKER_HOST_GW="${DOCKER_HOST_GW:-172.16.1.1}"
    echo "[RECOVER] Docker host gateway (fallback): ${DOCKER_HOST_GW}"
fi

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

# Verify overlay network is ready (swarm scope)
for i in $(seq 1 30); do
    if docker network inspect "$NETWORK_NAME" --format '{{.Scope}}' 2>/dev/null | grep -q swarm; then
        echo "[RECOVER] ${NETWORK_NAME} overlay verified (${i}s)"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "[RECOVER] WARNING: ${NETWORK_NAME} not verified after 30s"
    fi
    sleep 1
done
echo "[RECOVER] ${NETWORK_NAME} overlay ready."

# ── Ensure hal-internal overlay network ────────────────────────────────
HAL_NET_EXISTS=$(docker network ls --format '{{.Name}}' | grep -c "^${HAL_NETWORK_NAME}$" || true)
if [ "$HAL_NET_EXISTS" -eq 0 ]; then
    echo "[RECOVER] Creating ${HAL_NETWORK_NAME} overlay network..."
    docker network create --driver overlay --attachable \
        --subnet "$HAL_OVERLAY_SUBNET" "$HAL_NETWORK_NAME" 2>/dev/null || true
fi
echo "[RECOVER] ${HAL_NETWORK_NAME} overlay ready."

# ── Ensure compose services ─────────────────────────────────────────
echo "[RECOVER] Ensuring compose services..."
for svc_dir in pihole npm cubeos-hal terminal; do
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

STACKS="registry cubeos-api cubeos-docsindex dozzle cubeos-dashboard kiwix"

for stack in $STACKS; do
    COMPOSE_FILE="${COREAPPS_DIR}/${stack}/appconfig/docker-compose.yml"
    if [ -f "$COMPOSE_FILE" ]; then
        # Verify network still exists before each deploy
        if ! docker network inspect "$NETWORK_NAME" &>/dev/null; then
            echo "[RECOVER] Network ${NETWORK_NAME} gone — recreating..."
            docker network create --driver overlay --attachable \
                --subnet "$OVERLAY_SUBNET" "$NETWORK_NAME" 2>/dev/null || true
            sleep 5
        fi
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
