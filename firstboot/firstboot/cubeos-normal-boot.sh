#!/bin/bash
# =============================================================================
# cubeos-normal-boot.sh — CubeOS Normal Boot (v8 - Alpha.12)
# =============================================================================
# On normal boots, Docker Swarm auto-reconciles all stacks. This script
# verifies critical services and applies the saved network mode.
#
# v8 — ALPHA.12 FIXES:
#   1. watchdog start --no-block (prevents boot hang on slow hardware init)
#   2. Compose services: check-only loop (skip up -d if already running)
#   3. Log truncation at script start (prevents unbounded growth)
#   4. Reduced timeouts: Docker/API wait from 60s → 30s
#   5. Pi-hole health: DNS check (dig) instead of HTTP check
#   6. Unicode → ASCII markers (OK:/WARN: instead of checkmark/warning)
#   7. Version header updated to v8
#
# v6 — ALPHA.11 FIXES:
#   1. Removed netplan apply (deadlocks against Docker bridges + hostapd)
#   2. Added overlay network verify loop (race condition fix)
#   3. Pre-deploy network existence check before stack redeploy
#
# v5 — ALPHA.10 FIXES:
#   1. B19: Set regulatory domain (iw reg set) before hostapd start
#   2. WiFi AP verification with automatic restart fallback
#   3. Version banner reads from CUBEOS_VERSION env var
#
# v4 — ALPHA.6 FIXES:
#   1. Network name: cubeos-network (was cubeos)
#   2. Overlay subnet: 10.42.25.0/24 (was 172.20.0.0/24)
#   3. HAL port: 6005 (was 6013)
#   4. Deploys ALL stacks on recovery (registry, api, dashboard, docsindex, ollama, chromadb)
#   5. Compose services include HAL on port 6005
#   6. No Docker secrets — API uses env_file
# =============================================================================
set -uo pipefail

LOG_FILE="/var/log/cubeos-boot.log"
GATEWAY_IP="10.42.24.1"
OVERLAY_SUBNET="10.42.25.0/24"
NETWORK_NAME="cubeos-network"
CONFIG_DIR="/cubeos/config"
COREAPPS_DIR="/cubeos/coreapps"
BOOT_START=$(date +%s)

# v8: Truncate log at start of each boot (prevents unbounded growth)
: > "$LOG_FILE"

# ── Logging ───────────────────────────────────────────────────────────
log() {
    local msg
    msg="$(date '+%H:%M:%S') $*"
    echo "$msg" >> "$LOG_FILE"
    echo "$msg" >&2
}

# v8: ASCII markers instead of Unicode
log_ok() { log "[BOOT]   OK: $*"; }
log_warn() { log "[BOOT]   WARN: $*"; }

# ── Helpers ───────────────────────────────────────────────────────────
wait_for() {
    # v8: Default max_wait reduced from 60s to 30s
    local name="$1" check_cmd="$2" max_wait="${3:-30}" interval="${4:-2}" elapsed=0
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

# v8: Helper to check if a container is running (used by compose check-only loop)
container_running() {
    docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null | grep -q true
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
    swapon --show 2>/dev/null | grep -q zram && log_ok "ZRAM swap started" || log_warn "ZRAM swap not available"
fi
# v8: --no-block prevents boot hang if watchdog hardware init is slow
[ -e /dev/watchdog ] && systemctl start watchdog --no-block 2>/dev/null || true

# ── wlan0 IP ──────────────────────────────────────────────────────────
log "[BOOT] Ensuring wlan0 has ${GATEWAY_IP}..."
ip link set wlan0 up 2>/dev/null || true
ip addr add "${GATEWAY_IP}/24" dev wlan0 2>/dev/null || true
# NOTE: netplan apply deliberately omitted — deadlocks against Docker bridges + hostapd.
# The ip link set + ip addr add above already configure wlan0.

# ── Docker ────────────────────────────────────────────────────────────
# v8: Reduced timeout from 60s → 30s
wait_for "Docker" "docker info" 30 || {
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

    SWARM_OUTPUT=$(docker swarm init \
        --advertise-addr "$GATEWAY_IP" \
        --listen-addr "0.0.0.0:2377" \
        --force-new-cluster \
        --task-history-limit 1 2>&1) && {
        log_ok "Swarm recovered (force-new-cluster)"
    } || {
        log "[BOOT]   Attempt 1 failed: ${SWARM_OUTPUT}"
        SWARM_OUTPUT=$(docker swarm init \
            --listen-addr "0.0.0.0:2377" \
            --task-history-limit 1 2>&1) && {
            log_ok "Swarm recovered (auto-addr)"
        } || {
            log_warn "Swarm recovery failed: ${SWARM_OUTPUT}"
        }
    }

    # Recreate overlay network after Swarm recovery
    if docker info 2>/dev/null | grep -q "Swarm: active"; then
        docker network create --driver overlay --attachable \
            --subnet "$OVERLAY_SUBNET" "$NETWORK_NAME" 2>/dev/null || true
        # Verify overlay is ready (swarm scope)
        for i in $(seq 1 30); do
            if docker network inspect "$NETWORK_NAME" --format '{{.Scope}}' 2>/dev/null | grep -q swarm; then
                log_ok "Swarm recovered + overlay verified (${i}s)"
                break
            fi
            sleep 1
        done
    fi
fi

# ── Compose services ──────────────────────────────────────────────────
# v8: Check-only loop — skip docker compose up if container is already running.
# This avoids unnecessary restarts and speeds up normal boots.
log "[BOOT] Checking compose services..."
for svc_dir in pihole npm cubeos-hal; do
    CONTAINER="cubeos-${svc_dir}"
    if container_running "$CONTAINER"; then
        log_ok "${svc_dir}: running"
    else
        COMPOSE_FILE="${COREAPPS_DIR}/${svc_dir}/appconfig/docker-compose.yml"
        if [ -f "$COMPOSE_FILE" ]; then
            log "[BOOT]   ${svc_dir}: not running — starting..."
            DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose -f "$COMPOSE_FILE" up -d --pull never 2>/dev/null || \
                log_warn "${svc_dir} start failed"
        fi
    fi
done

# v8: Pi-hole health via DNS check instead of HTTP (more reliable, tests actual functionality)
wait_for "Pi-hole DNS" "dig cubeos.cube @127.0.0.1 +short +time=2 +tries=1" 30 1 || true

# ── DNS resolver fallback ─────────────────────────────────────────────
if ! grep -q "^nameserver" /etc/resolv.conf 2>/dev/null; then
    log "[BOOT] Fixing /etc/resolv.conf (no nameserver)"
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
fi

# ── WiFi AP ───────────────────────────────────────────────────────────
log "[BOOT] Setting regulatory domain..."
COUNTRY_CODE="${CUBEOS_COUNTRY_CODE:-US}"
iw reg set "$COUNTRY_CODE" 2>/dev/null || true
sleep 2  # Give kernel time to apply regulatory domain

log "[BOOT] Starting WiFi Access Point..."
rfkill unblock wifi 2>/dev/null || true
systemctl start hostapd 2>/dev/null || log_warn "hostapd failed"

# Verify AP is broadcasting
sleep 3
if iw dev wlan0 info 2>/dev/null | grep -q "type AP"; then
    log_ok "WiFi AP broadcasting (country: $COUNTRY_CODE)"
else
    log_warn "WiFi AP not broadcasting — restarting hostapd..."
    iw reg set "$COUNTRY_CODE" 2>/dev/null || true
    sleep 1
    systemctl restart hostapd 2>/dev/null || true
    sleep 2
    if iw dev wlan0 info 2>/dev/null | grep -q "type AP"; then
        log_ok "WiFi AP recovered after restart"
    else
        log_warn "WiFi AP STILL not broadcasting — manual intervention needed"
    fi
fi

# ── Swarm stacks ──────────────────────────────────────────────────────
if docker info 2>/dev/null | grep -q "Swarm: active"; then
    log "[BOOT] Verifying Swarm stacks..."

    # ALL stacks that should be running (matching Pi 5 production)
    STACKS="registry cubeos-api cubeos-dashboard cubeos-docsindex ollama chromadb"

    for stack in $STACKS; do
        if docker stack ls 2>/dev/null | grep -q "^${stack} "; then
            log_ok "Stack ${stack}: present (Swarm will reconcile)"
        else
            log_warn "Stack ${stack}: MISSING — redeploying..."
            # Verify network before redeploy
            if ! docker network inspect "$NETWORK_NAME" &>/dev/null; then
                log_warn "Network ${NETWORK_NAME} gone — recreating"
                docker network create --driver overlay --attachable \
                    --subnet "$OVERLAY_SUBNET" "$NETWORK_NAME" 2>/dev/null || true
                sleep 5
            fi
            COMPOSE_FILE="${COREAPPS_DIR}/${stack}/appconfig/docker-compose.yml"
            [ -f "$COMPOSE_FILE" ] && \
                docker stack deploy -c "$COMPOSE_FILE" --resolve-image never "$stack" 2>/dev/null || true
        fi
    done
fi

# v8: Reduced timeout from 60s → 30s
wait_for "API" "curl -sf http://127.0.0.1:6010/health" 30 || true

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
