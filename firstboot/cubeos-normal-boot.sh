#!/bin/bash
# =============================================================================
# cubeos-normal-boot.sh — CubeOS Normal Boot (v9 - Alpha.13)
# =============================================================================
# On normal boots, Docker Swarm auto-reconciles all stacks. This script
# verifies critical services and applies the saved network mode.
#
# v9 — ALPHA.13:
#   1. Sources cubeos-boot-lib.sh (shared functions, constants)
#   2. All shared logic now in lib (wait_for, container_running, WiFi, etc.)
#   3. Consistent ASCII markers with first-boot
#   4. Consistent timeouts with first-boot
#   5. Uses shared SWARM_STACKS and COMPOSE_SERVICES lists
#
# v8 — ALPHA.12 FIXES:
#   1. watchdog start --no-block (prevents boot hang on slow hardware init)
#   2. Compose services: check-only loop (skip up -d if already running)
#   3. Log truncation at script start (prevents unbounded growth)
#   4. Reduced timeouts: Docker/API wait from 60s → 30s
#   5. Pi-hole health: DNS check (dig) instead of HTTP check
#   6. Unicode → ASCII markers (OK:/WARN: instead of checkmark/warning)
#
# v6 — ALPHA.11 FIXES:
#   1. Removed netplan apply (deadlocks against Docker bridges + hostapd)
#   2. Added overlay network verify loop (race condition fix)
#   3. Pre-deploy network existence check before stack redeploy
# =============================================================================
set -uo pipefail

# ── Source shared library ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_PATH="${SCRIPT_DIR}/cubeos-boot-lib.sh"
[ -f "$LIB_PATH" ] || LIB_PATH="/usr/local/bin/cubeos-boot-lib.sh"
if [ ! -f "$LIB_PATH" ]; then
    echo "FATAL: cubeos-boot-lib.sh not found" >&2
    exit 1
fi
source "$LIB_PATH"

# ── Normal-boot specific overrides ──────────────────────────────────
LOG_FILE="/var/log/cubeos-boot.log"
FAILURES=0
BOOT_START=$(date +%s)

# v8/v9: Truncate log at start of each boot (prevents unbounded growth)
: > "$LOG_FILE"

# Alpha.17: Boot metadata for boot page (cubeos-boot.html)
cat > /var/log/cubeos-boot-meta.json << EOF
{
  "boot_type": "normal",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "version": "${CUBEOS_VERSION:-unknown}"
}
EOF

# Alpha.17: Predictable symlink for nginx log serving
ln -sf "$(basename "$LOG_FILE")" /var/log/cubeos-current-boot.log

# =============================================================================
source "${CONFIG_DIR}/defaults.env" 2>/dev/null || true

log "============================================================"
log "  CubeOS Normal Boot -- v${CUBEOS_VERSION:-unknown}"
log "  $(date)"
log "============================================================"

# ── ZRAM Swap + Watchdog ──────────────────────────────────────────────
log "Verifying ZRAM swap and watchdog..."
ensure_zram
start_watchdog

# ── wlan0 IP ──────────────────────────────────────────────────────────
log "Ensuring wlan0 has ${GATEWAY_IP}..."
ip link set wlan0 up 2>/dev/null || true
ip addr add "${GATEWAY_IP}/24" dev wlan0 2>/dev/null || true
# NOTE: netplan apply deliberately omitted — deadlocks against Docker bridges + hostapd.

# ── Docker ────────────────────────────────────────────────────────────
wait_for "Docker" "docker info" 30 || {
    log "Docker not starting -- restarting daemon..."
    systemctl restart docker 2>/dev/null || true
    wait_for "Docker" "docker info" 30 || {
        log "FATAL: Docker failed. Exiting."
        exit 1
    }
}

# ── Swarm recovery ────────────────────────────────────────────────────
if ! docker info 2>/dev/null | grep -q "Swarm: active"; then
    recover_swarm

    # Recreate overlay network after Swarm recovery
    if docker info 2>/dev/null | grep -q "Swarm: active"; then
        ensure_overlay_network
    fi
fi

# ── Compose services ──────────────────────────────────────────────────
# Check-only loop — skip docker compose up if container is already running.
# HAL must be running before Swarm stacks (API depends on it).
log "Checking compose services..."
for svc_dir in $COMPOSE_SERVICES; do
    CONTAINER="cubeos-${svc_dir}"
    if container_running "$CONTAINER"; then
        log_ok "${svc_dir}: running"
    else
        COMPOSE_FILE="${COREAPPS_DIR}/${svc_dir}/appconfig/docker-compose.yml"
        if [ -f "$COMPOSE_FILE" ]; then
            log "${svc_dir}: not running -- starting..."
            DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose -f "$COMPOSE_FILE" up -d --pull never 2>/dev/null || \
                log_warn "${svc_dir} start failed"
        fi
    fi
done

# Explicit HAL verification (T09: restart policy may not trigger after clean shutdown)
if ! container_running "cubeos-hal"; then
    log "HAL still not running after compose check -- forcing start..."
    DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose \
        -f "${COREAPPS_DIR}/cubeos-hal/appconfig/docker-compose.yml" \
        up -d --pull never 2>/dev/null || log_warn "HAL force-start failed"
fi

# Pi-hole health via DNS check (more reliable, tests actual functionality)
wait_for "Pi-hole DNS" "dig cubeos.cube @127.0.0.1 +short +time=2 +tries=1" 30 1 || true

# ── DNS resolver fallback ─────────────────────────────────────────────
ensure_dns_resolver

# ── WiFi AP ───────────────────────────────────────────────────────────
log "Starting WiFi Access Point..."
source "${CONFIG_DIR}/ap.env" 2>/dev/null || true
configure_wifi_ap

# ── Swarm stacks ──────────────────────────────────────────────────────
if docker info 2>/dev/null | grep -q "Swarm: active"; then
    log "Verifying Swarm stacks..."

    # T07: Ensure overlay network exists before checking stacks
    # Network can be GC'd if no services reference it after reboot
    ensure_overlay_network

    for stack in $SWARM_STACKS; do
        if docker stack ls 2>/dev/null | grep -q "^${stack} "; then
            log_ok "Stack ${stack}: present (Swarm will reconcile)"
        else
            log_warn "Stack ${stack}: MISSING -- redeploying..."
            deploy_stack "$stack" || true
        fi
    done
fi

wait_for "API" "curl -sf http://127.0.0.1:6010/health" 30 || true

# ── Network mode ──────────────────────────────────────────────────────
apply_network_mode

# ── Done ──────────────────────────────────────────────────────────────
BOOT_END=$(date +%s)
log ""
log "============================================================"
log "  CubeOS Boot Complete ($((BOOT_END - BOOT_START))s)"
log "  Dashboard: http://cubeos.cube"
log "============================================================"

exit 0
