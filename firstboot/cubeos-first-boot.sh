#!/bin/bash
# =============================================================================
# cubeos-first-boot.sh — CubeOS First Boot Orchestrator (v9 - Alpha.13)
# =============================================================================
# Runs ONCE on the very first power-on of a new CubeOS device.
#
# v9 — ALPHA.13:
#   1. Sources cubeos-boot-lib.sh (shared functions, constants, proxy rules)
#   2. ASCII-only log markers (OK:/WARN:/FAIL: — no Unicode)
#   3. 11 NPM proxy rules from shared CORE_PROXY_RULES array
#   4. Pi-hole DNS from shared CORE_DNS_HOSTS array
#   5. Country code from defaults.env (not hardcoded US)
#   6. Watchdog --no-block start (prevents 195s hang on Pi 4B)
#   7. Log truncation at script start
#   8. 30s default timeout for wait_for()
#   9. container_running() helper for compose services
#
# v8 — ALPHA.11 FIXES:
#   1. Removed netplan apply (deadlocks against Docker bridges + hostapd)
#   2. Added overlay network verify loop after creation (race condition fix)
#   3. Pre-deploy network existence check in deploy_stack()
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

# ── First-boot specific overrides ───────────────────────────────────
LOG_FILE="/var/log/cubeos-first-boot.log"
HEARTBEAT="/tmp/cubeos-boot-heartbeat"
PROGRESS="/tmp/cubeos-boot-progress"

# ── State gates ──────────────────────────────────────────────────────
SWARM_READY=false
FAILURES=0
BOOT_START=$(date +%s)

# v9: Truncate log at start
: > "$LOG_FILE"

# Alpha.17: Boot metadata for boot page (cubeos-boot.html)
cat > /var/log/cubeos-boot-meta.json << EOF
{
  "boot_type": "first",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "version": "${CUBEOS_VERSION:-unknown}"
}
EOF

# Alpha.17: Predictable symlink for nginx log serving
ln -sf "$(basename "$LOG_FILE")" /var/log/cubeos-current-boot.log

# ── Dead Man's Switch ────────────────────────────────────────────────
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
                echo "$(date '+%Y-%m-%d %H:%M:%S') FAIL: Boot exceeded ${MAX_BOOT_TIME}s -- forcing reboot!" >> "$LOG_FILE"
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
                    echo "$(date '+%Y-%m-%d %H:%M:%S') FAIL: No heartbeat for ${stale}s -- killing hung boot!" >> "$LOG_FILE"
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

log_step() {
    log "$*"
    date +%s > "$HEARTBEAT"
}

# ── NPM Seeding ─────────────────────────────────────────────────────
seed_npm() {
    local NPM_API="http://127.0.0.1:81/api"
    local NPM_EMAIL="admin@cubeos.cube"
    local NPM_PASSWORD
    NPM_PASSWORD=$(openssl rand -hex 16)

    # Step 1: Check if NPM needs initial setup
    local SETUP_STATUS
    SETUP_STATUS=$(curl -sf "${NPM_API}/" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('setup', {}).get('status', 'unknown'))
except:
    print('unknown')
" 2>/dev/null || echo "unknown")

    if [ "$SETUP_STATUS" != "false" ] && [ "$SETUP_STATUS" != "unknown" ]; then
        log_ok "NPM already initialized"
        return 0
    fi

    # Step 2: Create initial admin user
    log "  NPM: Creating admin user..."
    local CREATE_RESP
    CREATE_RESP=$(curl -sf -X POST "${NPM_API}/users" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"CubeOS Admin\",
            \"nickname\": \"admin\",
            \"email\": \"${NPM_EMAIL}\",
            \"roles\": [\"admin\"],
            \"is_disabled\": false,
            \"auth\": {
                \"type\": \"password\",
                \"secret\": \"${NPM_PASSWORD}\"
            }
        }" 2>/dev/null) || { log_warn "NPM user creation failed"; return 1; }

    # Step 3: Get auth token
    log "  NPM: Authenticating..."
    local TOKEN_RESP TOKEN
    TOKEN_RESP=$(curl -sf -X POST "${NPM_API}/tokens" \
        -H "Content-Type: application/json" \
        -d "{\"identity\": \"${NPM_EMAIL}\", \"secret\": \"${NPM_PASSWORD}\"}" \
        2>/dev/null) || { log_warn "NPM auth failed"; return 1; }

    TOKEN=$(echo "$TOKEN_RESP" | python3 -c "
import sys, json
print(json.load(sys.stdin).get('token', ''))
" 2>/dev/null)

    if [ -z "$TOKEN" ]; then
        log_warn "NPM: no token received"
        return 1
    fi

    # Step 4: Create proxy hosts — uses shared CORE_PROXY_RULES array (11 rules)
    for entry in "${CORE_PROXY_RULES[@]}"; do
        local domain="${entry%%:*}"
        local port="${entry##*:}"
        log "  NPM: Proxy ${domain} -> :${port}"

        # Alpha.17: cubeos.cube gets 502 error page config (serves boot page when dashboard is down)
        local adv_config=""
        if [ "$domain" = "cubeos.cube" ]; then
            adv_config="proxy_intercept_errors on;\nerror_page 502 503 504 /cubeos-boot.html;"
        fi

        curl -sf -X POST "${NPM_API}/nginx/proxy-hosts" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${TOKEN}" \
            -d "{
                \"domain_names\": [\"${domain}\"],
                \"forward_scheme\": \"http\",
                \"forward_host\": \"${GATEWAY_IP}\",
                \"forward_port\": ${port},
                \"block_exploits\": false,
                \"allow_websocket_upgrade\": true,
                \"access_list_id\": 0,
                \"certificate_id\": 0,
                \"advanced_config\": \"${adv_config}\",
                \"meta\": {\"dns_challenge\": false},
                \"locations\": []
            }" 2>/dev/null || log_warn "  Failed: ${domain}"
    done

    # Step 5: Set default site to CubeOS boot page
    # This replaces the NPM "Congratulations" page with our branded boot page.
    # Uses NPM's "html" default site mode with inline content.
    if [ -f "/cubeos/static/cubeos-boot.html" ]; then
        local BOOT_HTML_JSON
        BOOT_HTML_JSON=$(python3 -c "
import sys, json
with open('/cubeos/static/cubeos-boot.html') as f:
    print(json.dumps(f.read()))
" 2>/dev/null)
        if [ -n "$BOOT_HTML_JSON" ]; then
            curl -sf -X PUT "${NPM_API}/settings/default-site" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${TOKEN}" \
                -d "{\"value\":\"html\",\"meta\":{\"html\":${BOOT_HTML_JSON}}}" \
                2>/dev/null && log_ok "NPM default site set to CubeOS boot page" \
                || log_warn "NPM default site setting failed"
        fi
    fi

    # Step 5: Store NPM password in secrets.env
    if [ -f "${CONFIG_DIR}/secrets.env" ]; then
        echo "CUBEOS_NPM_PASSWORD=${NPM_PASSWORD}" >> "${CONFIG_DIR}/secrets.env"
        echo "CUBEOS_NPM_EMAIL=${NPM_EMAIL}" >> "${CONFIG_DIR}/secrets.env"
    fi

    log_ok "NPM initialized with ${#CORE_PROXY_RULES[@]} proxy hosts"
}

# =============================================================================
# Initialize
# =============================================================================
date +%s > "$HEARTBEAT"

source "${CONFIG_DIR}/defaults.env" 2>/dev/null || true

log "============================================================"
log "  CubeOS First Boot -- v${CUBEOS_VERSION:-unknown}"
log "  $(date)"
log "============================================================"
log ""

start_dead_mans_switch

# B5 safety net: cloud-init may regenerate 50-cloud-init.conf with PasswordAuthentication no
rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf

# =========================================================================
# Step 1/9: ZRAM Swap + Watchdog
# =========================================================================
log_step "Step 1/9: ZRAM swap and hardware watchdog..."
echo "1/9" > "$PROGRESS"

ensure_zram
start_watchdog

log "  $(free -h | awk '/^Mem:/{printf "RAM: total=%s avail=%s", $2, $7}') $(free -h | awk '/^Swap:/{printf "Swap: %s", $2}')"

# =========================================================================
# Step 2/9: Network interface
# =========================================================================
log_step "Step 2/9: Configuring network interface..."
echo "2/9" > "$PROGRESS"

# NOTE: netplan apply deliberately omitted — deadlocks against Docker bridges + hostapd.
if ensure_ip_on_interface wlan0 "$GATEWAY_IP" 10; then
    log_ok "wlan0 has ${GATEWAY_IP}"
else
    log_warn "Could not assign ${GATEWAY_IP} to wlan0 -- Swarm will use fallback"
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

# Ensure secrets.env is readable by docker group
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
    log_fail "Docker not starting -- attempting restart"
    systemctl restart docker 2>/dev/null || true
    sleep 10
    if docker info &>/dev/null; then
        log_ok "Docker recovered after restart"
    else
        log_fail "FATAL: Docker still not running"
    fi
fi

# Swarm init
if docker info 2>/dev/null | grep -q "Swarm: active"; then
    log_ok "Swarm already active"
    SWARM_READY=true
else
    log "  Initializing Swarm..."

    SWARM_OUTPUT=$(docker swarm init \
        --advertise-addr "$GATEWAY_IP" \
        --listen-addr "0.0.0.0:2377" \
        --task-history-limit 1 2>&1) && {
        log_ok "Swarm initialized (attempt 1)"
        SWARM_READY=true
    } || {
        log "  Attempt 1 failed: ${SWARM_OUTPUT}"
        SWARM_OUTPUT=$(docker swarm init \
            --advertise-addr "$GATEWAY_IP" \
            --listen-addr "0.0.0.0:2377" \
            --force-new-cluster \
            --task-history-limit 1 2>&1) && {
            log_ok "Swarm initialized (attempt 2, force-new-cluster)"
            SWARM_READY=true
        } || {
            log "  Attempt 2 failed: ${SWARM_OUTPUT}"
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

# Create overlay network
if [ "$SWARM_READY" = true ]; then
    ensure_overlay_network
fi

# =========================================================================
# Step 5/9: Pi-hole (DNS/DHCP first)
# =========================================================================
log_step "Step 5/9: Deploying infrastructure..."
echo "5/9" > "$PROGRESS"

if docker image inspect "pihole/pihole:latest" &>/dev/null; then
    log_ok "Pi-hole image present (pre-loaded)"
else
    log_warn "Pi-hole image not found -- deploy may pull or fail"
fi

source "${CONFIG_DIR}/defaults.env" 2>/dev/null || true
DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose \
    -f "${COREAPPS_DIR}/pihole/appconfig/docker-compose.yml" \
    up -d --pull never 2>&1 || log_warn "Pi-hole deploy failed"

wait_for "Pi-hole" "curl -sf http://127.0.0.1:6001/admin/" 90 1 || log_warn "Pi-hole not responding"

# Seed custom DNS — uses shared CORE_DNS_HOSTS array
seed_pihole_dns

# =========================================================================
# Step 6/9: WiFi AP
# =========================================================================
log_step "Step 6/9: Starting WiFi Access Point..."
echo "6/9" > "$PROGRESS"

source "${CONFIG_DIR}/ap.env" 2>/dev/null || true
systemctl unmask hostapd 2>/dev/null || true

# B1 fix: Ensure SSID was set (in case AP creds failed in Step 3)
if grep -q "ssid=CubeOS-Setup" /etc/hostapd/hostapd.conf; then
    log_warn "SSID still at default -- running AP creds generation"
    /usr/local/bin/cubeos-generate-ap-creds.sh 2>/dev/null || true
    source "${CONFIG_DIR}/ap.env" 2>/dev/null || true
fi

configure_wifi_ap

# =========================================================================
# Step 7/9: NPM + HAL
# =========================================================================
log_step "Step 7/9: Deploying NPM + HAL..."
echo "7/9" > "$PROGRESS"

ensure_dns_resolver

# Alpha.17: Pre-create NPM custom nginx config for boot page + log endpoints
# These location blocks are injected into every proxy host's server block,
# allowing /cubeos-log and /cubeos-boot.html to be served directly by nginx
# (exact-match locations take priority over the proxy_pass).
NPM_DATA="${COREAPPS_DIR}/npm/appdata/data"
mkdir -p "${NPM_DATA}/nginx/custom"
cat > "${NPM_DATA}/nginx/custom/server_proxy.conf" << 'NGINX'
# CubeOS boot page and log serving endpoints (Alpha.17)
# Injected into all proxy host server blocks via NPM custom include.
# Exact-match locations override the upstream proxy_pass.

location = /cubeos-boot.html {
    alias /data/custom-pages/cubeos-boot.html;
    default_type text/html;
    add_header Cache-Control "no-cache, no-store";
}

location = /cubeos-log {
    alias /var/log/host/cubeos-current-boot.log;
    default_type text/plain;
    add_header Cache-Control "no-cache, no-store";
    add_header Access-Control-Allow-Origin *;
}

location = /cubeos-log-meta {
    alias /var/log/host/cubeos-boot-meta.json;
    default_type application/json;
    add_header Cache-Control "no-cache, no-store";
    add_header Access-Control-Allow-Origin *;
}
NGINX
log_ok "NPM custom nginx config created (boot page + log endpoints)"

if docker image inspect "jc21/nginx-proxy-manager:latest" &>/dev/null; then
    log_ok "NPM image present (pre-loaded)"
else
    log_warn "NPM image not found -- deploy may pull or fail"
fi
DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose \
    -f "${COREAPPS_DIR}/npm/appconfig/docker-compose.yml" \
    up -d --pull never 2>&1 || log_warn "NPM deploy failed"
wait_for "NPM" "curl -sf http://127.0.0.1:81/api/" 90 || log_warn "NPM not responding"
seed_npm || log_warn "NPM seeding failed -- cubeos.cube may show default page"

# HAL
if docker image inspect "ghcr.io/cubeos-app/hal:latest" &>/dev/null; then
    log_ok "HAL image present (pre-loaded)"
else
    log_warn "HAL image not found -- deploy may pull or fail"
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
    # Verify Swarm node is ready before deploying
    wait_for "Swarm node ready" "docker node ls --format '{{.Status}}' | grep -q Ready" 30 2

    # Stabilization delay (reduced from 15s — overlay network no longer wastes 60s)
    log "  Waiting 5s for Swarm to stabilize..."
    sleep 5
    date +%s > "$HEARTBEAT"

    for stack in $SWARM_STACKS_PRE_API; do
        deploy_stack "$stack" || true
        sleep 3
        date +%s > "$HEARTBEAT"
    done

    # Wait for critical services
    wait_for "API" "curl -sf http://127.0.0.1:6010/health" 120 || log_warn "API not healthy"

    # B08: Deploy dashboard AFTER API is healthy to prevent 502/wizard flash
    for stack in $SWARM_STACKS_POST_API; do
        deploy_stack "$stack" || true
        sleep 3
        date +%s > "$HEARTBEAT"
    done

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
log "  -------------------------------------------"
check_status "Docker Swarm                    " "docker info 2>/dev/null | grep -q 'Swarm: active'"
check_status "hostapd (WiFi AP)               " "systemctl is-active hostapd"
check_status "Pi-hole (DNS/DHCP)         :6001" "curl -sf http://127.0.0.1:6001/admin/"
check_status "NPM (Reverse Proxy)        :81  " "curl -sf http://127.0.0.1:81/api/"
check_status "HAL (Hardware)             :6005" "curl -sf http://127.0.0.1:6005/health"
check_status "API (Backend)              :6010" "curl -sf http://127.0.0.1:6010/health"
check_status "Dashboard (Frontend)       :6011" "curl -sf http://127.0.0.1:6011/"

log ""
log "  -------------------------------------------"

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

# Start watchdog monitoring now that all services are deployed
systemctl enable cubeos-watchdog.timer 2>/dev/null || true
systemctl start cubeos-watchdog.timer 2>/dev/null || true
log_ok "Watchdog monitoring started"

mkdir -p "$(dirname "$SETUP_FLAG")"
touch "$SETUP_FLAG"
log "Setup flag created -- next boot will run normal-boot.sh"

# Disable cloud-init on subsequent boots (prevents timeout delays on air-gapped operation)
touch /etc/cloud/cloud-init.disabled
log "Cloud-init disabled for subsequent boots"

rm -f "$HEARTBEAT" "$PROGRESS" /tmp/cubeos-swarm-ready

# Copy first-boot log to standard location for API boot log endpoint
cp "$LOG_FILE" /var/log/cubeos-boot.log 2>/dev/null || true

exit 0
