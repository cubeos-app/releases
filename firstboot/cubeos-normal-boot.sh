#!/bin/bash
# =============================================================================
# cubeos-normal-boot.sh — CubeOS Normal Boot (v3 - Voyager)
# =============================================================================
# On normal boots, Docker Swarm auto-reconciles all stacks. This script
# verifies critical services and applies the saved network mode.
#
# v3 — VOYAGER EDITION:
#   - NO exec/tee — logging via function (no process substitution deadlock)
#   - NO set -e — explicit error handling, script never dies silently
#   - NO /var/swap.cubeos — ZRAM handles swap (golden base v1.1.0+)
#   - Multi-attempt Swarm recovery with secrets recreation
#   - DNS resolver fallback (prevents NPM crash loop)
# =============================================================================
set -uo pipefail

LOG_FILE="/var/log/cubeos-boot.log"
GATEWAY_IP="10.42.24.1"
CONFIG_DIR="/cubeos/config"
COREAPPS_DIR="/cubeos/coreapps"
BOOT_START=$(date +%s)

# ── Logging ───────────────────────────────────────────────────────────
log() {
    local msg
    msg="$(date '+%H:%M:%S') $*"
    echo "$msg" >> "$LOG_FILE"
    echo "$msg" >&2
}

log_ok() { log "[BOOT]   ✓ $*"; }
log_warn() { log "[BOOT]   ⚠ $*"; }

# ── Helpers ───────────────────────────────────────────────────────────
wait_for() {
    local name="$1" check_cmd="$2" max_wait="${3:-60}" interval="${4:-2}" elapsed=0
    log "[BOOT] Waiting for ${name}..."
    while [ $elapsed -lt $max_wait ]; do
        if eval "$check_cmd" &>/dev/null; then
            log_ok "${name} ready (${elapsed}s)"
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    log_warn "${name} not ready after ${max_wait}s"
    return 1
}

# =============================================================================
source "${CONFIG_DIR}/defaults.env" 2>/dev/null || true

log "============================================================"
log "  CubeOS Normal Boot — v${CUBEOS_VERSION:-unknown}"
log "  $(date)"
log "============================================================"

# ── ZRAM Swap + Watchdog ──────────────────────────────────────────────
log "[BOOT] Verifying ZRAM swap and watchdog..."
if swapon --show 2>/dev/null | grep -q zram; then
    log_ok "ZRAM swap active"
else
    systemctl start systemd-zram-setup@zram0.service 2>/dev/null || true
    sleep 2
    if swapon --show 2>/dev/null | grep -q zram; then
        log_ok "ZRAM swap started"
    else
        log_warn "ZRAM swap not available"
    fi
fi
[ -e /dev/watchdog ] && systemctl start watchdog 2>/dev/null || true

# ── wlan0 IP ──────────────────────────────────────────────────────────
log "[BOOT] Ensuring wlan0 has ${GATEWAY_IP}..."
ip link set wlan0 up 2>/dev/null || true
ip addr add "${GATEWAY_IP}/24" dev wlan0 2>/dev/null || true
netplan apply 2>/dev/null || true

# ── Docker ────────────────────────────────────────────────────────────
wait_for "Docker" "docker info" 60 || {
    log "[BOOT] Docker not starting — restarting daemon..."
    systemctl restart docker 2>/dev/null || true
    wait_for "Docker" "docker info" 30 || {
        log "[BOOT] FATAL: Docker failed. Exiting."
        exit 1
    }
}

# ── Swarm recovery ────────────────────────────────────────────────────
if ! docker info 2>/dev/null | grep -q "Swarm: active"; then
    log "[BOOT] Swarm not active! Recovering..."

    docker swarm init \
        --advertise-addr "$GATEWAY_IP" \
        --listen-addr "0.0.0.0:2377" \
        --force-new-cluster \
        --task-history-limit 1 2>&1 || \
    docker swarm init \
        --listen-addr "0.0.0.0:2377" \
        --task-history-limit 1 2>&1 || \
    log_warn "Swarm recovery failed — stacks may not work"

    # Recreate secrets after Swarm recovery
    if docker info 2>/dev/null | grep -q "Swarm: active"; then
        log "[BOOT] Recreating Docker secrets after Swarm recovery..."
        source "${CONFIG_DIR}/secrets.env" 2>/dev/null || true
        if [ -n "${CUBEOS_JWT_SECRET:-}" ]; then
            echo -n "$CUBEOS_JWT_SECRET" | docker secret create jwt_secret - 2>/dev/null || true
            echo -n "$CUBEOS_API_SECRET" | docker secret create api_secret - 2>/dev/null || true
        fi
        docker network create --driver overlay --attachable --subnet 172.20.0.0/24 cubeos 2>/dev/null || true
        log_ok "Swarm recovered + secrets recreated"
    fi
fi

# ── Compose services ──────────────────────────────────────────────────
log "[BOOT] Starting compose services..."
for svc_dir in pihole npm cubeos-hal; do
    COMPOSE_FILE="${COREAPPS_DIR}/${svc_dir}/appconfig/docker-compose.yml"
    if [ -f "$COMPOSE_FILE" ]; then
        DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose -f "$COMPOSE_FILE" up -d --pull never 2>/dev/null || \
            log_warn "${svc_dir} start failed"
    fi
done

wait_for "Pi-hole DNS" "dig @127.0.0.1 localhost +short +timeout=1 +tries=1" 60 1 || true

# ── DNS resolver fallback ─────────────────────────────────────────────
if ! grep -q "^nameserver" /etc/resolv.conf 2>/dev/null; then
    log "[BOOT] Fixing /etc/resolv.conf (no nameserver)"
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
fi

# ── WiFi AP ───────────────────────────────────────────────────────────
log "[BOOT] Starting WiFi Access Point..."
rfkill unblock wifi 2>/dev/null || true
systemctl start hostapd 2>/dev/null || log_warn "hostapd failed"

# ── Swarm stacks ──────────────────────────────────────────────────────
if docker info 2>/dev/null | grep -q "Swarm: active"; then
    log "[BOOT] Verifying Swarm stacks..."
    for stack in cubeos-api cubeos-dashboard; do
        if docker stack ls 2>/dev/null | grep -q "^${stack} "; then
            log_ok "Stack ${stack}: present (Swarm will reconcile)"
        else
            log_warn "Stack ${stack}: MISSING — redeploying..."
            COMPOSE_FILE="${COREAPPS_DIR}/${stack}/appconfig/docker-compose.yml"
            [ -f "$COMPOSE_FILE" ] && \
                docker stack deploy -c "$COMPOSE_FILE" --resolve-image never "$stack" 2>/dev/null || true
        fi
    done
fi

wait_for "API" "curl -sf http://127.0.0.1:6010/health" 60 || true

# ── Network mode ──────────────────────────────────────────────────────
log "[BOOT] Applying network mode..."
case "${CUBEOS_NETWORK_MODE:-OFFLINE}" in
    ONLINE_ETH)
        log_ok "Mode: ONLINE_ETH — NAT via eth0"
        /usr/local/lib/cubeos/nat-enable.sh eth0 2>/dev/null || true
        ;;
    ONLINE_WIFI)
        log_ok "Mode: ONLINE_WIFI — NAT via wlan1"
        /usr/local/lib/cubeos/nat-enable.sh wlan1 2>/dev/null || true
        ;;
    OFFLINE|*)
        log_ok "Mode: OFFLINE"
        ;;
esac

# ── Done ──────────────────────────────────────────────────────────────
BOOT_END=$(date +%s)
log ""
log "============================================================"
log "  CubeOS Boot Complete ($((BOOT_END - BOOT_START))s)"
log "  Dashboard: http://cubeos.cube"
log "============================================================"

exit 0
