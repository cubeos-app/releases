#!/bin/bash
# =============================================================================
# cubeos-first-boot.sh — CubeOS First Boot Orchestrator (v6 - Alpha.9)
# =============================================================================
# Runs ONCE on the very first power-on of a new CubeOS device.
#
# v6 — ALPHA.9 FIXES:
#   1. Docker images pre-loaded at CI time (Phase 1b) — no ensure_image_loaded waits
#   2. Image verification only — log presence, don't try to load from tarballs
#
# v5 — ALPHA.8 FIXES:
#   1. secrets.env permissions: 640 root:docker (CI redeploy fix)
#   2. Removed ensure_image_loaded placeholder guards (confusing error msgs)
#   3. Cloud-init disabled after first boot (air-gap timeout fix)
#
# v4 — ALPHA.6 FIXES:
#   1. Network name: cubeos-network (was cubeos) — matches all compose files
#   2. Overlay subnet: 10.42.25.0/24 (was 172.20.0.0/24) — matches Pi 5
#   3. Swarm init captures stderr (was silently swallowed)
#   4. HAL port: 6005 (was 6013) — matches production HAL
#   5. No Docker secrets — API uses env_file, not Swarm secrets
#   6. Deploys ALL stacks: registry, api, dashboard, dozzle, ollama, chromadb
#   7. Pi-hole v6 healthcheck (curl :6001/admin/)
#   8. Dead man's switch, per-step timeouts, heartbeat (from v3)
# =============================================================================
set -uo pipefail

# ── Paths ─────────────────────────────────────────────────────────────
LOG_FILE="/var/log/cubeos-first-boot.log"
HEARTBEAT="/tmp/cubeos-boot-heartbeat"
PROGRESS="/tmp/cubeos-boot-progress"
GATEWAY_IP="10.42.24.1"
SUBNET="10.42.24.0/24"
OVERLAY_SUBNET="10.42.25.0/24"
NETWORK_NAME="cubeos-network"
CONFIG_DIR="/cubeos/config"
COREAPPS_DIR="/cubeos/coreapps"
DATA_DIR="/cubeos/data"
CACHE_DIR="/var/cache/cubeos-images"
SETUP_FLAG="/cubeos/data/.setup_complete"

# ── State gates ───────────────────────────────────────────────────────
SWARM_READY=false
FAILURES=0
BOOT_START=$(date +%s)

# ── Logging ───────────────────────────────────────────────────────────
log() {
    local msg
    msg="$(date '+%H:%M:%S') $*"
    echo "$msg" >> "$LOG_FILE"
    echo "$msg" >&2
}

log_step() {
    log "[BOOT] $*"
    date +%s > "$HEARTBEAT"
}

log_ok() { log "[BOOT]   ✓ $*"; }
log_warn() { log "[BOOT]   ⚠ $*"; }
log_fail() { log "[BOOT]   ✗ $*"; FAILURES=$((FAILURES + 1)); }

# ── Dead Man's Switch ─────────────────────────────────────────────────
STALL_TIMEOUT=180
MAX_BOOT_TIME=900
BOOT_PID=$$

start_dead_mans_switch() {
    (
        while true; do
            sleep 15
            local now elapsed
            now=$(date +%s)
            elapsed=$((now - BOOT_START))
            if [ "$elapsed" -gt "$MAX_BOOT_TIME" ]; then
                echo "$(date '+%H:%M:%S') [DEADMAN] Boot exceeded ${MAX_BOOT_TIME}s — forcing reboot!" >> "$LOG_FILE"
                kill -9 "$BOOT_PID" 2>/dev/null
                sleep 2
                systemctl reboot
                exit
            fi
            if [ -f "$HEARTBEAT" ]; then
                local last_beat stale
                last_beat=$(cat "$HEARTBEAT" 2>/dev/null || echo "$now")
                stale=$((now - last_beat))
                if [ "$stale" -gt "$STALL_TIMEOUT" ]; then
                    echo "$(date '+%H:%M:%S') [DEADMAN] No heartbeat for ${stale}s — killing hung boot!" >> "$LOG_FILE"
                    pkill -P "$BOOT_PID" 2>/dev/null
                    kill -TERM "$BOOT_PID" 2>/dev/null
                    sleep 5
                    kill -9 "$BOOT_PID" 2>/dev/null
                    exit
                fi
            fi
            if ! kill -0 "$BOOT_PID" 2>/dev/null; then
                exit
            fi
        done
    ) &
    DEADMAN_PID=$!
    trap "kill $DEADMAN_PID 2>/dev/null; cleanup_and_exit" EXIT
}

cleanup_and_exit() {
    kill "$DEADMAN_PID" 2>/dev/null || true
    rm -f "$HEARTBEAT" "$PROGRESS" /tmp/cubeos-swarm-ready
}

# ── Helpers ───────────────────────────────────────────────────────────
wait_for() {
    local name="$1" check_cmd="$2" max_wait="${3:-60}" interval="${4:-2}" elapsed=0
    log_step "Waiting for ${name}..."
    while [ $elapsed -lt $max_wait ]; do
        if eval "$check_cmd" &>/dev/null; then
            log_ok "${name} ready (${elapsed}s)"
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        date +%s > "$HEARTBEAT"
    done
    log_warn "${name} not ready after ${max_wait}s"
    return 1
}

ensure_image_loaded() {
    local image_ref="$1" cache_name="$2"
    if docker image inspect "$image_ref" &>/dev/null; then
        return 0
    fi
    local tarball="${CACHE_DIR}/${cache_name}.tar"
    if [ -f "$tarball" ]; then
        log "[BOOT]   Loading ${cache_name} from cache..."
        if docker load < "$tarball" 2>&1; then
            log_ok "Loaded ${cache_name}"
            return 0
        else
            log_fail "Failed to load ${cache_name}"
            return 1
        fi
    fi
    log_warn "Image ${image_ref} not available (no tarball)"
    return 1
}

ensure_ip_on_interface() {
    local iface="$1" ip="$2" max_wait="${3:-15}"
    ip link set "$iface" up 2>/dev/null || true
    ip addr add "${ip}/24" dev "$iface" 2>/dev/null || true
    for i in $(seq 1 "$max_wait"); do
        if ip addr show "$iface" 2>/dev/null | grep -q "$ip"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

deploy_stack() {
    local name="$1"
    local compose_file="${COREAPPS_DIR}/${name}/appconfig/docker-compose.yml"
    if [ ! -f "$compose_file" ]; then
        log_warn "No compose file for stack ${name}"
        return 1
    fi
    log "[BOOT]   Deploying stack: ${name}..."
    if docker stack deploy -c "$compose_file" --resolve-image never "$name" 2>&1; then
        log_ok "Stack ${name} deployed"
        return 0
    else
        log_fail "Stack ${name} deploy failed"
        return 1
    fi
}

# =============================================================================
# Initialize
# =============================================================================
: > "$LOG_FILE"
date +%s > "$HEARTBEAT"

source "${CONFIG_DIR}/defaults.env" 2>/dev/null || true

log "============================================================"
log "  CubeOS First Boot — v${CUBEOS_VERSION:-unknown} (alpha.9)"
log "  $(date)"
log "============================================================"
log ""

start_dead_mans_switch

# =========================================================================
# Step 1/9: ZRAM Swap + Watchdog
# =========================================================================
log_step "Step 1/9: ZRAM swap and hardware watchdog..."
echo "1/9" > "$PROGRESS"

if swapon --show 2>/dev/null | grep -q zram; then
    log_ok "ZRAM swap active"
else
    systemctl start systemd-zram-setup@zram0.service 2>/dev/null || true
    sleep 2
    swapon --show 2>/dev/null | grep -q zram && log_ok "ZRAM swap started" || log_warn "ZRAM swap not available"
fi

[ -e /dev/watchdog ] && systemctl start watchdog 2>/dev/null && log_ok "Hardware watchdog enabled" || true

log "[BOOT]   $(free -h | awk '/^Mem:/{printf "RAM: total=%s avail=%s", $2, $7}') $(free -h | awk '/^Swap:/{printf "Swap: %s", $2}')"

# =========================================================================
# Step 2/9: Network interface
# =========================================================================
log_step "Step 2/9: Configuring network interface..."
echo "2/9" > "$PROGRESS"

netplan apply 2>/dev/null || true
if ensure_ip_on_interface wlan0 "$GATEWAY_IP" 10; then
    log_ok "wlan0 has ${GATEWAY_IP}"
else
    log_warn "Could not assign ${GATEWAY_IP} to wlan0 — Swarm will use fallback"
fi

# =========================================================================
# Step 3/9: AP credentials + secrets
# =========================================================================
log_step "Step 3/9: Generating credentials..."
echo "3/9" > "$PROGRESS"

/usr/local/bin/cubeos-generate-ap-creds.sh 2>/dev/null || log_warn "AP creds generation failed"
source "${CONFIG_DIR}/ap.env" 2>/dev/null || true
log_ok "SSID: ${CUBEOS_AP_SSID:-CubeOS-Setup}"
log_ok "Key:  ${CUBEOS_AP_KEY:-cubeos-setup}"

/usr/local/bin/cubeos-generate-secrets.sh 2>/dev/null || log_warn "Secrets generation failed"

# Ensure secrets.env is readable by docker group (needed for docker stack deploy env_file)
if [ -f "${CONFIG_DIR}/secrets.env" ]; then
    chmod 640 "${CONFIG_DIR}/secrets.env"
    chown root:docker "${CONFIG_DIR}/secrets.env"
fi

# =========================================================================
# Step 4/9: Docker + Swarm
# =========================================================================
log_step "Step 4/9: Docker and Swarm initialization..."
echo "4/9" > "$PROGRESS"

# Wait for Docker
docker_ok=false
for i in $(seq 1 120); do
    if docker info &>/dev/null; then
        docker_ok=true
        log_ok "Docker ready (${i}s)"
        break
    fi
    sleep 1
    date +%s > "$HEARTBEAT"
done

if [ "$docker_ok" = false ]; then
    log_fail "Docker not starting — attempting restart"
    systemctl restart docker 2>/dev/null || true
    sleep 10
    if docker info &>/dev/null; then
        log_ok "Docker recovered after restart"
    else
        log_fail "FATAL: Docker still not running"
    fi
fi

# Swarm init — CAPTURE STDERR (Bug #4 fix)
if docker info 2>/dev/null | grep -q "Swarm: active"; then
    log_ok "Swarm already active"
    SWARM_READY=true
else
    log "[BOOT]   Initializing Swarm..."

    SWARM_OUTPUT=$(docker swarm init \
        --advertise-addr "$GATEWAY_IP" \
        --listen-addr "0.0.0.0:2377" \
        --task-history-limit 1 2>&1) && {
        log_ok "Swarm initialized (attempt 1)"
        SWARM_READY=true
    } || {
        log "[BOOT]   Attempt 1 failed: ${SWARM_OUTPUT}"
        SWARM_OUTPUT=$(docker swarm init \
            --advertise-addr "$GATEWAY_IP" \
            --listen-addr "0.0.0.0:2377" \
            --force-new-cluster \
            --task-history-limit 1 2>&1) && {
            log_ok "Swarm initialized (attempt 2, force-new-cluster)"
            SWARM_READY=true
        } || {
            log "[BOOT]   Attempt 2 failed: ${SWARM_OUTPUT}"
            SWARM_OUTPUT=$(docker swarm init \
                --listen-addr "0.0.0.0:2377" \
                --task-history-limit 1 2>&1) && {
                log_ok "Swarm initialized (attempt 3, auto-addr)"
                SWARM_READY=true
            } || {
                log_fail "All Swarm init attempts failed: ${SWARM_OUTPUT}"
            }
        }
    }
fi
date +%s > "$HEARTBEAT"

# Create overlay network — CORRECT NAME AND SUBNET (Bug #2 fix)
if [ "$SWARM_READY" = true ]; then
    # Check if network exists with wrong scope
    NETWORK_SCOPE=$(docker network inspect "$NETWORK_NAME" --format '{{.Scope}}' 2>/dev/null || echo "none")
    if [ "$NETWORK_SCOPE" = "local" ]; then
        log "[BOOT]   Removing local ${NETWORK_NAME} (wrong scope)..."
        docker network rm "$NETWORK_NAME" 2>/dev/null || true
        NETWORK_SCOPE="none"
    fi
    if [ "$NETWORK_SCOPE" = "none" ]; then
        docker network create \
            --driver overlay --attachable \
            --subnet "$OVERLAY_SUBNET" \
            "$NETWORK_NAME" 2>/dev/null || true
    fi
    log_ok "${NETWORK_NAME} overlay network ready (${OVERLAY_SUBNET})"
fi

# =========================================================================
# Step 5/9: Pi-hole (DNS/DHCP first)
# =========================================================================
log_step "Step 5/9: Deploying infrastructure..."
echo "5/9" > "$PROGRESS"

if docker image inspect "pihole/pihole:latest" &>/dev/null; then
    log_ok "Pi-hole image present (pre-loaded)"
else
    log_warn "Pi-hole image not found — deploy may pull or fail"
fi

source "${CONFIG_DIR}/defaults.env" 2>/dev/null || true
DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose \
    -f "${COREAPPS_DIR}/pihole/appconfig/docker-compose.yml" \
    up -d --pull never 2>&1 || log_warn "Pi-hole deploy failed"

wait_for "Pi-hole" "curl -sf http://127.0.0.1:6001/admin/" 90 1 || log_warn "Pi-hole not responding"

# Seed custom DNS
PIHOLE_HOSTS="/cubeos/coreapps/pihole/appdata/etc-pihole/hosts/custom.list"
mkdir -p "$(dirname "$PIHOLE_HOSTS")"
cat > "$PIHOLE_HOSTS" << EOF
${GATEWAY_IP} cubeos.cube
${GATEWAY_IP} api.cubeos.cube
${GATEWAY_IP} npm.cubeos.cube
${GATEWAY_IP} pihole.cubeos.cube
${GATEWAY_IP} logs.cubeos.cube
${GATEWAY_IP} ollama.cubeos.cube
${GATEWAY_IP} registry.cubeos.cube
${GATEWAY_IP} docs.cubeos.cube
EOF
docker exec cubeos-pihole pihole reloaddns 2>/dev/null || true
log_ok "Pi-hole deployed + DNS seeded"

# =========================================================================
# Step 6/9: WiFi AP
# =========================================================================
log_step "Step 6/9: Starting WiFi Access Point..."
echo "6/9" > "$PROGRESS"

source "${CONFIG_DIR}/ap.env" 2>/dev/null || true
rfkill unblock wifi 2>/dev/null || true
systemctl unmask hostapd 2>/dev/null || true
if systemctl start hostapd 2>/dev/null; then
    log_ok "AP started: ${CUBEOS_AP_SSID:-CubeOS-Setup}"
else
    log_warn "hostapd failed — ethernet access only at ${GATEWAY_IP}"
fi

# =========================================================================
# Step 7/9: NPM + HAL
# =========================================================================
log_step "Step 7/9: Deploying NPM + HAL..."
echo "7/9" > "$PROGRESS"

# DNS resolver fallback
if ! grep -q "^nameserver" /etc/resolv.conf 2>/dev/null; then
    log "[BOOT]   Fixing /etc/resolv.conf"
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
fi

if docker image inspect "jc21/nginx-proxy-manager:latest" &>/dev/null; then
    log_ok "NPM image present (pre-loaded)"
else
    log_warn "NPM image not found — deploy may pull or fail"
fi
DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose \
    -f "${COREAPPS_DIR}/npm/appconfig/docker-compose.yml" \
    up -d --pull never 2>&1 || log_warn "NPM deploy failed"
wait_for "NPM" "curl -sf http://127.0.0.1:81/api/" 90 || log_warn "NPM not responding"

# HAL — port 6005 (NOT 6013!)
if docker image inspect "ghcr.io/cubeos-app/hal:latest" &>/dev/null; then
    log_ok "HAL image present (pre-loaded)"
else
    log_warn "HAL image not found — deploy may pull or fail"
fi
DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose \
    -f "${COREAPPS_DIR}/cubeos-hal/appconfig/docker-compose.yml" \
    up -d --pull never 2>&1 || log_warn "HAL deploy failed"
wait_for "HAL" "curl -sf http://127.0.0.1:6005/health" 30 || log_warn "HAL not responding"

# =========================================================================
# Step 8/9: Swarm stacks
# =========================================================================
log_step "Step 8/9: Deploying platform services..."
echo "8/9" > "$PROGRESS"

if [ "$SWARM_READY" = true ]; then
    # Deploy all stacks matching Pi 5 production
    # Images are pre-loaded into overlay2 at CI build time (Phase 1b)
    # --resolve-image=never in deploy_stack() means Swarm won't pull
    STACKS="registry cubeos-api cubeos-dashboard dozzle ollama chromadb"
    for stack in $STACKS; do
        deploy_stack "$stack" || true
        sleep 2
        date +%s > "$HEARTBEAT"
    done

    # Wait for critical services
    wait_for "API" "curl -sf http://127.0.0.1:6010/health" 120 || log_warn "API not healthy"
    wait_for "Dashboard" "curl -sf http://127.0.0.1:6011/" 60 || log_warn "Dashboard not healthy"
else
    log_warn "Stacks need Swarm. Run: cubeos-deploy-stacks.sh"
fi

# =========================================================================
# Step 9/9: Verification + setup flag
# =========================================================================
log_step "Step 9/9: Verification..."
echo "9/9" > "$PROGRESS"

BOOT_END=$(date +%s)
BOOT_DURATION=$((BOOT_END - BOOT_START))

log ""
log "============================================================"
log "  CubeOS First Boot Complete! (${BOOT_DURATION}s)"
log "============================================================"
log ""

check_status() {
    local name="$1" cmd="$2"
    if eval "$cmd" &>/dev/null; then
        log "  [OK]  ${name}"
    else
        log "  [!!]  ${name}"
        FAILURES=$((FAILURES + 1))
    fi
}

log "  Service Status:"
log "  ─────────────────────────────────────────"
check_status "Docker Swarm                    " "docker info 2>/dev/null | grep -q 'Swarm: active'"
check_status "hostapd (WiFi AP)               " "systemctl is-active hostapd"
check_status "Pi-hole (DNS/DHCP)         :6001" "curl -sf http://127.0.0.1:6001/admin/"
check_status "NPM (Reverse Proxy)        :81  " "curl -sf http://127.0.0.1:81/api/"
check_status "HAL (Hardware)             :6005" "curl -sf http://127.0.0.1:6005/health"
check_status "API (Backend)              :6010" "curl -sf http://127.0.0.1:6010/health"
check_status "Dashboard (Frontend)       :6011" "curl -sf http://127.0.0.1:6011/"

log ""
log "  ─────────────────────────────────────────"

if [ "$FAILURES" -gt 0 ]; then
    log ""
    log "  ${FAILURES} service(s) not healthy."
    log "  Watchdog will attempt recovery every 60s."
    log "  Manual recovery: cubeos-deploy-stacks.sh"
fi

source "${CONFIG_DIR}/ap.env" 2>/dev/null || true
log ""
log "  WiFi:      ${CUBEOS_AP_SSID:-CubeOS-Setup} / ${CUBEOS_AP_KEY:-cubeos-setup}"
log "  Dashboard: http://cubeos.cube  or  http://${GATEWAY_IP}"
log "  Login:     admin / cubeos"
log ""
log "============================================================"

mkdir -p "$(dirname "$SETUP_FLAG")"
touch "$SETUP_FLAG"
log "[BOOT] Setup flag created — next boot will run normal-boot.sh"

# Disable cloud-init on subsequent boots (prevents timeout delays on air-gapped operation)
touch /etc/cloud/cloud-init.disabled
log "[BOOT] Cloud-init disabled for subsequent boots"

rm -f "$HEARTBEAT" "$PROGRESS" /tmp/cubeos-swarm-ready

exit 0
