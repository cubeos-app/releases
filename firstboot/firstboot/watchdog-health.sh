#!/bin/bash
# =============================================================================
# watchdog-health.sh — CubeOS Watchdog Health Check (V4 - Alpha.6)
# =============================================================================
# Runs every 60s via systemd timer. Ensures all services are running.
# Matches Pi 5 production configuration.
#
# V4 — ALPHA.6:
#   - Hybrid checks: compose services (pihole, npm, hal) + swarm stacks
#   - Network name: cubeos-network
#   - HAL port: 6005
#   - Structured logging to /cubeos/data/watchdog/
#   - Disk cleanup and Docker task pruning
#   - hostapd monitoring
# =============================================================================
set -uo pipefail

LOG_DIR="/cubeos/data/watchdog"
LOG_FILE="${LOG_DIR}/watchdog.log"
ALERT_DIR="/cubeos/alerts"
GATEWAY_IP="10.42.24.1"
OVERLAY_SUBNET="10.42.25.0/24"
NETWORK_NAME="cubeos-network"
COREAPPS_DIR="/cubeos/coreapps"
CONFIG_DIR="/cubeos/config"

mkdir -p "$LOG_DIR" "$ALERT_DIR"

# ── Logging ───────────────────────────────────────────────────────────
TS=$(date '+%Y-%m-%d %H:%M:%S')

log() {
    echo "${TS} [WATCHDOG] $*" >> "$LOG_FILE"
}

log_ok() { log "  ✓ $*"; }
log_warn() { log "  ⚠ $*"; }
log_fix() { log "  🔧 $*"; }

ISSUES=0
FIXES=0

# ── Rotate log (keep under 1MB) ──────────────────────────────────────
if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

log "─── Health check started ───"

# ── Docker daemon ─────────────────────────────────────────────────────
if ! docker info &>/dev/null; then
    log_warn "Docker daemon not running!"
    ISSUES=$((ISSUES + 1))
    systemctl restart docker 2>/dev/null || true
    sleep 10
    if docker info &>/dev/null; then
        log_fix "Docker restarted"
        FIXES=$((FIXES + 1))
    else
        log_warn "Docker restart failed — aborting"
        exit 1
    fi
fi

# ── Swarm ─────────────────────────────────────────────────────────────
if ! docker info 2>/dev/null | grep -q "Swarm: active"; then
    log_warn "Swarm not active!"
    ISSUES=$((ISSUES + 1))

    SWARM_OUTPUT=$(docker swarm init \
        --advertise-addr "$GATEWAY_IP" \
        --listen-addr "0.0.0.0:2377" \
        --force-new-cluster \
        --task-history-limit 1 2>&1) && {
        log_fix "Swarm recovered: ${SWARM_OUTPUT}"
        FIXES=$((FIXES + 1))
        # Recreate overlay
        docker network create --driver overlay --attachable \
            --subnet "$OVERLAY_SUBNET" "$NETWORK_NAME" 2>/dev/null || true
    } || {
        log_warn "Swarm recovery failed: ${SWARM_OUTPUT}"
    }
fi

# ── Overlay network ──────────────────────────────────────────────────
if ! docker network ls --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
    log_warn "${NETWORK_NAME} overlay missing!"
    ISSUES=$((ISSUES + 1))
    docker network create --driver overlay --attachable \
        --subnet "$OVERLAY_SUBNET" "$NETWORK_NAME" 2>/dev/null && {
        log_fix "Recreated ${NETWORK_NAME}"
        FIXES=$((FIXES + 1))
    } || log_warn "Failed to recreate ${NETWORK_NAME}"
fi

# ── Compose services (pihole, npm, hal) ──────────────────────────────
check_compose() {
    local name="$1" container="$2" health_cmd="$3" compose_dir="$4"
    local compose_file="${COREAPPS_DIR}/${compose_dir}/appconfig/docker-compose.yml"

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        log_warn "${name}: container not running"
        ISSUES=$((ISSUES + 1))
        if [ -f "$compose_file" ]; then
            DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose -f "$compose_file" up -d --pull never 2>/dev/null && {
                log_fix "${name}: restarted"
                FIXES=$((FIXES + 1))
            } || log_warn "${name}: restart failed"
        fi
        return
    fi

    if ! eval "$health_cmd" &>/dev/null; then
        log_warn "${name}: unhealthy"
        ISSUES=$((ISSUES + 1))
        docker restart "$container" 2>/dev/null && {
            log_fix "${name}: container restarted"
            FIXES=$((FIXES + 1))
        } || log_warn "${name}: restart failed"
    else
        log_ok "${name}"
    fi
}

check_compose "Pi-hole"  "cubeos-pihole" "curl -sf --max-time 5 http://127.0.0.1:6001/admin/" "pihole"
check_compose "NPM"      "cubeos-npm"    "curl -sf --max-time 5 http://127.0.0.1:81/api/"     "npm"
check_compose "HAL"      "cubeos-hal"    "curl -sf --max-time 5 http://127.0.0.1:6005/health"  "cubeos-hal"

# ── Swarm stacks ─────────────────────────────────────────────────────
check_stack() {
    local name="$1" health_cmd="${2:-}"
    local compose_file="${COREAPPS_DIR}/${name}/appconfig/docker-compose.yml"

    if ! docker stack ls 2>/dev/null | grep -q "^${name} "; then
        log_warn "Stack ${name}: missing"
        ISSUES=$((ISSUES + 1))
        if [ -f "$compose_file" ]; then
            docker stack deploy -c "$compose_file" --resolve-image never "$name" 2>/dev/null && {
                log_fix "Stack ${name}: redeployed"
                FIXES=$((FIXES + 1))
            } || log_warn "Stack ${name}: redeploy failed"
        fi
        return
    fi

    # Check replicas
    local replicas
    replicas=$(docker service ls --filter "label=com.docker.stack.namespace=${name}" \
        --format '{{.Replicas}}' 2>/dev/null | head -1)

    if [ -n "$replicas" ] && ! echo "$replicas" | grep -qE "^[1-9][0-9]*/[1-9]"; then
        log_warn "Stack ${name}: replicas=${replicas}"
        ISSUES=$((ISSUES + 1))
        docker stack deploy -c "$compose_file" --resolve-image never "$name" 2>/dev/null && {
            log_fix "Stack ${name}: redeployed"
            FIXES=$((FIXES + 1))
        } || true
        return
    fi

    # Health endpoint check (if provided)
    if [ -n "$health_cmd" ]; then
        if eval "$health_cmd" &>/dev/null; then
            log_ok "Stack ${name}"
        else
            log_warn "Stack ${name}: health check failed"
            ISSUES=$((ISSUES + 1))
        fi
    else
        log_ok "Stack ${name}"
    fi
}

check_stack "registry"
check_stack "cubeos-api"       "curl -sf --max-time 5 http://127.0.0.1:6010/health"
check_stack "cubeos-dashboard" "curl -sf --max-time 5 http://127.0.0.1:6011/"
check_stack "cubeos-docsindex" "curl -sf --max-time 5 http://127.0.0.1:6032/health"
check_stack "ollama"
check_stack "chromadb"

# ── hostapd ───────────────────────────────────────────────────────────
if ! systemctl is-active --quiet hostapd 2>/dev/null; then
    log_warn "hostapd not running"
    ISSUES=$((ISSUES + 1))
    rfkill unblock wifi 2>/dev/null || true
    systemctl start hostapd 2>/dev/null && {
        log_fix "hostapd restarted"
        FIXES=$((FIXES + 1))
    } || log_warn "hostapd restart failed"
else
    log_ok "hostapd"
fi

# ── DNS resolver ──────────────────────────────────────────────────────
if ! grep -q "^nameserver" /etc/resolv.conf 2>/dev/null; then
    log_warn "/etc/resolv.conf missing nameserver"
    ISSUES=$((ISSUES + 1))
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    log_fix "Added nameserver 127.0.0.1"
    FIXES=$((FIXES + 1))
fi

# ── Disk cleanup ──────────────────────────────────────────────────────
DISK_PCT=$(df / | awk 'NR==2{gsub(/%/,""); print $5}')
if [ "${DISK_PCT:-0}" -gt 85 ]; then
    log_warn "Disk usage: ${DISK_PCT}% — running cleanup"
    ISSUES=$((ISSUES + 1))
    docker system prune -f --filter "until=24h" 2>/dev/null || true
    journalctl --vacuum-size=50M 2>/dev/null || true
    log_fix "Cleanup complete"
    FIXES=$((FIXES + 1))
fi

# ── Prune old Swarm tasks ────────────────────────────────────────────
docker container prune -f --filter "label=com.docker.swarm.task" \
    --filter "until=1h" 2>/dev/null | grep -q "Total" && log "Pruned old tasks" || true

# ── Summary ───────────────────────────────────────────────────────────
if [ "$ISSUES" -eq 0 ]; then
    log "─── All healthy ───"
else
    log "─── ${ISSUES} issues found, ${FIXES} fixed ───"
    # Write alert file for dashboard to read
    echo "${TS} issues=${ISSUES} fixes=${FIXES}" >> "${ALERT_DIR}/watchdog.alert"
fi

exit 0
