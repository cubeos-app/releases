#!/bin/bash
# =============================================================================
# cubeos-first-boot.sh — CubeOS First Boot Orchestrator (v3 - Voyager)
# =============================================================================
# Runs ONCE on the very first power-on of a new CubeOS device.
#
# v3 — VOYAGER EDITION (changes from v2):
#   1. NO exec/tee — logging via function, no process substitution deadlock
#   2. NO set -e — explicit error handling per step, script never dies silently
#   3. NO /var/swap.cubeos — ZRAM handles swap (golden base v1.1.0+)
#   4. Dead man's switch — background watchdog kills hung steps
#   5. Per-step timeouts — no single step can hang forever
#   6. Heartbeat file — progress tracking for external monitoring
#   7. Step skip on repeated failure — boot continues past broken steps
#   8. Version from defaults.env — no hardcoded version strings
#   9. Ultimate failsafe — reboot after 15 minutes if still running
# =============================================================================
set -uo pipefail
# NOTE: No -e! We handle errors explicitly. The script must never die silently.

# ── Paths ─────────────────────────────────────────────────────────────
LOG_FILE="/var/log/cubeos-first-boot.log"
HEARTBEAT="/tmp/cubeos-boot-heartbeat"
PROGRESS="/tmp/cubeos-boot-progress"
GATEWAY_IP="10.42.24.1"
SUBNET="10.42.24.0/24"
CONFIG_DIR="/cubeos/config"
COREAPPS_DIR="/cubeos/coreapps"
DATA_DIR="/cubeos/data"
CACHE_DIR="/var/cache/cubeos-images"
SETUP_FLAG="/cubeos/data/.setup_complete"

# ── State gates ───────────────────────────────────────────────────────
SWARM_READY=false
SECRETS_READY=false
FAILURES=0
BOOT_START=$(date +%s)

# ── Logging (no exec/tee — write to file AND stderr for journalctl) ──
log() {
    local msg
    msg="$(date '+%H:%M:%S') $*"
    echo "$msg" >> "$LOG_FILE"
    echo "$msg" >&2
}

log_step() {
    log "[BOOT] $*"
    # Update heartbeat — dead man's switch watches this
    date +%s > "$HEARTBEAT"
}

log_ok() { log "[BOOT]   ✓ $*"; }
log_warn() { log "[BOOT]   ⚠ $*"; }
log_fail() { log "[BOOT]   ✗ $*"; FAILURES=$((FAILURES + 1)); }

# ── Dead Man's Switch ─────────────────────────────────────────────────
# Background process that monitors heartbeat. If no progress for
# STALL_TIMEOUT seconds, it kills this script. If total runtime exceeds
# MAX_BOOT_TIME, it forces a reboot.
# ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ──
STALL_TIMEOUT=180    # 3 minutes without progress = step is hung
MAX_BOOT_TIME=900    # 15 minutes total = something is very wrong
BOOT_PID=$$

start_dead_mans_switch() {
    (
        while true; do
            sleep 15

            # Check total boot time
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

            # Check heartbeat staleness
            if [ -f "$HEARTBEAT" ]; then
                local last_beat stale
                last_beat=$(cat "$HEARTBEAT" 2>/dev/null || echo "$now")
                stale=$((now - last_beat))
                if [ "$stale" -gt "$STALL_TIMEOUT" ]; then
                    echo "$(date '+%H:%M:%S') [DEADMAN] No heartbeat for ${stale}s — killing hung boot script!" >> "$LOG_FILE"
                    # Kill all child processes of the boot script
                    pkill -P "$BOOT_PID" 2>/dev/null
                    kill -TERM "$BOOT_PID" 2>/dev/null
                    sleep 5
                    kill -9 "$BOOT_PID" 2>/dev/null
                    exit
                fi
            fi

            # Check if boot script is still alive
            if ! kill -0 "$BOOT_PID" 2>/dev/null; then
                exit
            fi
        done
    ) &
    DEADMAN_PID=$!
    # Ensure dead man's switch dies when we exit
    trap "kill $DEADMAN_PID 2>/dev/null; cleanup_and_exit" EXIT
}

cleanup_and_exit() {
    kill "$DEADMAN_PID" 2>/dev/null || true
    rm -f "$HEARTBEAT" "$PROGRESS"
}

# ── Helpers ───────────────────────────────────────────────────────────
wait_for() {
    local name="$1"
    local check_cmd="$2"
    local max_wait="${3:-60}"
    local interval="${4:-2}"
    local elapsed=0

    log_step "Waiting for ${name}..."
    while [ $elapsed -lt $max_wait ]; do
        if eval "$check_cmd" &>/dev/null; then
            log_ok "${name} ready (${elapsed}s)"
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        # Keep heartbeat alive during waits
        date +%s > "$HEARTBEAT"
    done
    log_warn "${name} not ready after ${max_wait}s"
    return 1
}

ensure_image_loaded() {
    local image_ref="$1"
    local cache_name="$2"

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
    local iface="$1"
    local ip="$2"
    local max_wait="${3:-15}"

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

run_step() {
    local step_num="$1"
    local step_name="$2"
    local step_func="$3"
    local step_timeout="${4:-300}"

    echo "$step_num" > "$PROGRESS"
    log_step "Step ${step_num}: ${step_name}..."
    date +%s > "$HEARTBEAT"

    # Run step with timeout
    local step_exit=0
    timeout "$step_timeout" bash -c "$(declare -f "$step_func" log log_step log_ok log_warn log_fail wait_for ensure_image_loaded ensure_ip_on_interface); $step_func" 2>&1 || step_exit=$?

    if [ "$step_exit" -eq 124 ]; then
        log_fail "Step ${step_num} TIMED OUT after ${step_timeout}s — continuing"
    elif [ "$step_exit" -ne 0 ]; then
        log_fail "Step ${step_num} failed (exit ${step_exit}) — continuing"
    fi

    date +%s > "$HEARTBEAT"
    return 0  # Always return 0 — we never stop the boot
}

# =============================================================================
# Initialize
# =============================================================================
: > "$LOG_FILE"  # Truncate log
date +%s > "$HEARTBEAT"

# Read version from defaults.env (set during image build by 04-cubeos.sh)
source "${CONFIG_DIR}/defaults.env" 2>/dev/null || true
CUBEOS_VERSION="${CUBEOS_VERSION:-unknown}"

log "============================================================"
log "  CubeOS First Boot — v${CUBEOS_VERSION}"
log "  $(date)"
log "============================================================"
log ""

# Start the dead man's switch
start_dead_mans_switch

# =========================================================================
# Step 1/9: ZRAM Swap + Watchdog
# =========================================================================
step_1_swap_watchdog() {
    # ZRAM is configured in golden base — just verify it's active
    if swapon --show 2>/dev/null | grep -q zram; then
        log_ok "ZRAM swap active"
    else
        log "[BOOT]   Starting ZRAM..."
        systemctl start systemd-zram-setup@zram0.service 2>/dev/null || true
        sleep 2
        if swapon --show 2>/dev/null | grep -q zram; then
            log_ok "ZRAM swap started"
        else
            log_warn "ZRAM swap not available (non-fatal)"
        fi
    fi

    if [ -e /dev/watchdog ]; then
        systemctl start watchdog 2>/dev/null || true
        log_ok "Hardware watchdog enabled"
    else
        log_warn "No watchdog device"
    fi

    log "[BOOT]   $(free -h | awk '/^Mem:/{printf "RAM: total=%s avail=%s", $2, $7}') $(free -h | awk '/^Swap:/{printf "Swap: %s", $2}')"
}
run_step "1/9" "ZRAM swap and hardware watchdog" step_1_swap_watchdog 30

# =========================================================================
# Step 2/9: Network interface
# =========================================================================
step_2_network() {
    netplan apply 2>/dev/null || true

    if ensure_ip_on_interface wlan0 "$GATEWAY_IP" 10; then
        log_ok "wlan0 has ${GATEWAY_IP}"
    else
        log_warn "Could not assign ${GATEWAY_IP} to wlan0 — Swarm will use fallback"
    fi
}
run_step "2/9" "Configuring network interface" step_2_network 30

# =========================================================================
# Step 3/9: AP credentials + secrets
# =========================================================================
step_3_credentials() {
    /usr/local/bin/cubeos-generate-ap-creds.sh 2>/dev/null || log_warn "AP creds generation failed"
    source "${CONFIG_DIR}/ap.env" 2>/dev/null || true
    log_ok "SSID: ${CUBEOS_AP_SSID:-CubeOS-Setup}"
    log_ok "Key:  ${CUBEOS_AP_KEY:-cubeos-setup}"

    /usr/local/bin/cubeos-generate-secrets.sh 2>/dev/null || log_warn "Secrets generation failed"
    source "${CONFIG_DIR}/secrets.env" 2>/dev/null || true
    if [ -n "${CUBEOS_JWT_SECRET:-}" ]; then
        log_ok "Secrets generated"
    else
        log_fail "Secrets NOT generated — stacks will fail"
    fi
}
run_step "3/9" "Generating credentials" step_3_credentials 30

# =========================================================================
# Step 4/9: Docker + Swarm
# =========================================================================
step_4_docker_swarm() {
    # Wait for Docker
    local docker_ok=false
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
        if ! docker info &>/dev/null; then
            log_fail "FATAL: Docker still not running"
            return 1
        fi
        log_ok "Docker recovered after restart"
    fi

    # Swarm init
    if docker info 2>/dev/null | grep -q "Swarm: active"; then
        log_ok "Swarm already active"
        SWARM_READY=true
        return 0
    fi

    log "[BOOT]   Initializing Swarm..."

    # Attempt 1
    if docker swarm init \
        --advertise-addr "$GATEWAY_IP" \
        --listen-addr "0.0.0.0:2377" \
        --task-history-limit 1 2>&1; then
        log_ok "Swarm initialized (attempt 1)"
        SWARM_READY=true
    # Attempt 2
    elif docker swarm init \
        --advertise-addr "$GATEWAY_IP" \
        --listen-addr "0.0.0.0:2377" \
        --force-new-cluster \
        --task-history-limit 1 2>&1; then
        log_ok "Swarm initialized (attempt 2, force-new-cluster)"
        SWARM_READY=true
    # Attempt 3
    elif docker swarm init \
        --listen-addr "0.0.0.0:2377" \
        --task-history-limit 1 2>&1; then
        log_ok "Swarm initialized (attempt 3, auto-addr)"
        SWARM_READY=true
    else
        log_fail "All Swarm init attempts failed"
    fi

    if [ "$SWARM_READY" = true ]; then
        # Overlay network
        if ! docker network ls --format '{{.Name}}' | grep -q "^cubeos$"; then
            docker network create \
                --driver overlay --attachable --subnet 172.20.0.0/24 \
                cubeos 2>/dev/null || log_warn "Overlay network creation failed"
        fi
        log_ok "cubeos overlay network ready"

        # Docker secrets
        source "${CONFIG_DIR}/secrets.env" 2>/dev/null || true
        if [ -n "${CUBEOS_JWT_SECRET:-}" ]; then
            echo -n "$CUBEOS_JWT_SECRET" | docker secret create jwt_secret - 2>/dev/null && \
                log_ok "Created jwt_secret" || log_ok "jwt_secret already exists"
            echo -n "$CUBEOS_API_SECRET" | docker secret create api_secret - 2>/dev/null && \
                log_ok "Created api_secret" || log_ok "api_secret already exists"
            SECRETS_READY=true
        else
            log_warn "No secrets to create — stacks will fail"
        fi
    fi
}
# Swarm init needs the exported vars — run inline instead of via run_step
log_step "Step 4/9: Docker and Swarm initialization..."
date +%s > "$HEARTBEAT"
echo "4/9" > "$PROGRESS"
timeout 180 bash -c "
    set -uo pipefail
    $(declare -f log log_step log_ok log_warn log_fail)
    $(declare -p LOG_FILE HEARTBEAT GATEWAY_IP CONFIG_DIR SWARM_READY SECRETS_READY 2>/dev/null)

    # Wait for Docker
    docker_ok=false
    for i in \$(seq 1 120); do
        if docker info &>/dev/null; then
            docker_ok=true
            log_ok \"Docker ready (\${i}s)\"
            break
        fi
        sleep 1
        date +%s > \"$HEARTBEAT\"
    done

    if [ \"\$docker_ok\" = false ]; then
        log_fail \"Docker not starting — attempting restart\"
        systemctl restart docker 2>/dev/null || true
        sleep 10
        if ! docker info &>/dev/null; then
            log_fail \"FATAL: Docker still not running\"
            exit 1
        fi
        log_ok \"Docker recovered after restart\"
    fi

    # Export Swarm state via files
    if docker info 2>/dev/null | grep -q 'Swarm: active'; then
        log_ok 'Swarm already active'
        echo true > /tmp/cubeos-swarm-ready
        exit 0
    fi

    log '[BOOT]   Initializing Swarm...'
    if docker swarm init --advertise-addr $GATEWAY_IP --listen-addr 0.0.0.0:2377 --task-history-limit 1 2>&1; then
        log_ok 'Swarm initialized (attempt 1)'
        echo true > /tmp/cubeos-swarm-ready
    elif docker swarm init --advertise-addr $GATEWAY_IP --listen-addr 0.0.0.0:2377 --force-new-cluster --task-history-limit 1 2>&1; then
        log_ok 'Swarm initialized (attempt 2, force-new-cluster)'
        echo true > /tmp/cubeos-swarm-ready
    elif docker swarm init --listen-addr 0.0.0.0:2377 --task-history-limit 1 2>&1; then
        log_ok 'Swarm initialized (attempt 3, auto-addr)'
        echo true > /tmp/cubeos-swarm-ready
    else
        log_fail 'All Swarm init attempts failed'
        echo false > /tmp/cubeos-swarm-ready
    fi
" 2>&1 || log_warn "Step 4 Docker/Swarm timed out or failed"

# Read Swarm state from file (subprocess can't set parent vars)
SWARM_READY=$(cat /tmp/cubeos-swarm-ready 2>/dev/null || echo false)
date +%s > "$HEARTBEAT"

# Create overlay + secrets in parent (needs Swarm to be active)
if [ "$SWARM_READY" = "true" ]; then
    if ! docker network ls --format '{{.Name}}' | grep -q "^cubeos$"; then
        docker network create --driver overlay --attachable --subnet 172.20.0.0/24 cubeos 2>/dev/null || true
    fi
    log_ok "cubeos overlay network ready"

    source "${CONFIG_DIR}/secrets.env" 2>/dev/null || true
    if [ -n "${CUBEOS_JWT_SECRET:-}" ]; then
        echo -n "$CUBEOS_JWT_SECRET" | docker secret create jwt_secret - 2>/dev/null && \
            log_ok "Created jwt_secret" || log_ok "jwt_secret exists"
        echo -n "$CUBEOS_API_SECRET" | docker secret create api_secret - 2>/dev/null && \
            log_ok "Created api_secret" || log_ok "api_secret exists"
        SECRETS_READY=true
    else
        log_warn "No secrets available"
    fi
else
    log_fail "Skipping overlay/secrets — Swarm not active"
fi

# =========================================================================
# Step 5/9: Pi-hole (DNS/DHCP first)
# =========================================================================
log_step "Step 5/9: Deploying infrastructure..."
date +%s > "$HEARTBEAT"
echo "5/9" > "$PROGRESS"

ensure_image_loaded "pihole/pihole:latest" "pihole" || true

source "${CONFIG_DIR}/defaults.env" 2>/dev/null || true
DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose \
    -f "${COREAPPS_DIR}/pihole/appconfig/docker-compose.yml" \
    --env-file "${COREAPPS_DIR}/pihole/appconfig/.env" \
    up -d --pull never 2>&1 || log_warn "Pi-hole deploy failed"

wait_for "Pi-hole DNS" "dig @127.0.0.1 localhost +short +timeout=1 +tries=1" 90 1 || log_warn "Pi-hole DNS not responding"

# Seed custom DNS
PIHOLE_HOSTS="/cubeos/coreapps/pihole/appdata/etc-pihole/hosts/custom.list"
mkdir -p "$(dirname "$PIHOLE_HOSTS")"
cat > "$PIHOLE_HOSTS" << EOF
${GATEWAY_IP} cubeos.cube
${GATEWAY_IP} api.cubeos.cube
${GATEWAY_IP} npm.cubeos.cube
EOF
docker exec cubeos-pihole pihole reloaddns 2>/dev/null || true
log_ok "Pi-hole deployed + DNS seeded"

# =========================================================================
# Step 6/9: WiFi AP
# =========================================================================
log_step "Step 6/9: Starting WiFi Access Point..."
date +%s > "$HEARTBEAT"
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
date +%s > "$HEARTBEAT"
echo "7/9" > "$PROGRESS"

# DNS resolver fallback
if ! grep -q "^nameserver" /etc/resolv.conf 2>/dev/null; then
    log "[BOOT]   Fixing /etc/resolv.conf"
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
fi

ensure_image_loaded "jc21/nginx-proxy-manager:latest" "npm" || true
DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose \
    -f "${COREAPPS_DIR}/npm/appconfig/docker-compose.yml" \
    up -d --pull never 2>&1 || log_warn "NPM deploy failed"
wait_for "NPM" "curl -sf http://127.0.0.1:81/api/" 90 || log_warn "NPM not responding"

ensure_image_loaded "ghcr.io/cubeos-app/hal:latest" "cubeos-hal" || true
DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose \
    -f "${COREAPPS_DIR}/cubeos-hal/appconfig/docker-compose.yml" \
    up -d --pull never 2>&1 || log_warn "HAL deploy failed"
wait_for "HAL" "curl -sf http://127.0.0.1:6013/health" 30 || log_warn "HAL not responding"

# =========================================================================
# Step 8/9: Swarm stacks (gated)
# =========================================================================
log_step "Step 8/9: Deploying platform services..."
date +%s > "$HEARTBEAT"
echo "8/9" > "$PROGRESS"

if [ "$SWARM_READY" = "true" ] && [ "$SECRETS_READY" = true ]; then

    ensure_image_loaded "ghcr.io/cubeos-app/api:latest" "cubeos-api" || true
    docker stack deploy \
        -c "${COREAPPS_DIR}/cubeos-api/appconfig/docker-compose.yml" \
        --resolve-image never \
        cubeos-api 2>&1 || log_warn "API stack deploy failed"
    wait_for "API" "curl -sf http://127.0.0.1:6010/health" 120 || log_warn "API not healthy"

    ensure_image_loaded "ghcr.io/cubeos-app/dashboard:latest" "cubeos-dashboard" || true
    docker stack deploy \
        -c "${COREAPPS_DIR}/cubeos-dashboard/appconfig/docker-compose.yml" \
        --resolve-image never \
        cubeos-dashboard 2>&1 || log_warn "Dashboard stack deploy failed"
    wait_for "Dashboard" "curl -sf http://127.0.0.1:6011/" 60 || log_warn "Dashboard not healthy"

elif [ "$SWARM_READY" = "true" ]; then
    log_warn "Stacks need secrets. Run: cubeos-deploy-stacks.sh"
else
    log_warn "Stacks need Swarm. Run: cubeos-deploy-stacks.sh"
fi

# =========================================================================
# Step 9/9: Verification + setup flag
# =========================================================================
log_step "Step 9/9: Verification..."
date +%s > "$HEARTBEAT"
echo "9/9" > "$PROGRESS"

BOOT_END=$(date +%s)
BOOT_DURATION=$((BOOT_END - BOOT_START))

log ""
log "============================================================"
log "  CubeOS First Boot Complete! (${BOOT_DURATION}s)"
log "============================================================"
log ""

check_status() {
    local name="$1"
    local cmd="$2"
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
check_status "HAL (Hardware)             :6013" "curl -sf http://127.0.0.1:6013/health"
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

# Create setup complete flag (even if some services failed — watchdog will heal)
mkdir -p "$(dirname "$SETUP_FLAG")"
touch "$SETUP_FLAG"
log "[BOOT] Setup flag created — next boot will run normal-boot.sh"

# Cleanup
rm -f "$HEARTBEAT" "$PROGRESS" /tmp/cubeos-swarm-ready

exit 0
