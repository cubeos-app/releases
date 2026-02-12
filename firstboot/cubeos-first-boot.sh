#!/bin/bash
# =============================================================================
# cubeos-first-boot.sh — CubeOS First Boot Orchestrator (v2 - hardened)
# =============================================================================
# Runs ONCE on the very first power-on of a new CubeOS device.
#
# HARDENING (v2 changes from v1):
#   1. Explicit IP verification on wlan0 BEFORE Swarm init (fixes #A)
#   2. State gates — SWARM_READY/SECRETS_READY prevent cascading failures (#B,#F)
#   3. Multi-attempt Swarm init with fallback strategies (#A)
#   4. DNS resolver fallback before NPM deploy (fixes crash loop #D)
#   5. Pi-hole deployed BEFORE WiFi AP (clients get DHCP on connect)
#   6. Port-based health checks (dig on 53) instead of slow HTTP checks (#E)
#   7. Recovery hints on failure — tells user exactly what to run
#   8. cubeos-deploy-stacks.sh for manual stack recovery
# =============================================================================
set -euo pipefail

LOG_FILE="/var/log/cubeos-first-boot.log"
exec 1> >(tee -a "$LOG_FILE") 2>&1

CUBEOS_VERSION="0.2.0-alpha"
GATEWAY_IP="10.42.24.1"
SUBNET="10.42.24.0/24"
CONFIG_DIR="/cubeos/config"
COREAPPS_DIR="/cubeos/coreapps"
DATA_DIR="/cubeos/data"
CACHE_DIR="/var/cache/cubeos-images"
SWAP_FILE="/var/swap.cubeos"

# ── State gates ───────────────────────────────────────────────────────
SWARM_READY=false
SECRETS_READY=false

echo "============================================================"
echo "  CubeOS First Boot — v${CUBEOS_VERSION}"
echo "  $(date)"
echo "============================================================"
echo ""

BOOT_START=$(date +%s)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
wait_for() {
    local name="$1"
    local check_cmd="$2"
    local timeout="${3:-60}"
    local interval="${4:-2}"
    local elapsed=0

    echo -n "[BOOT] Waiting for ${name}..."
    while [ $elapsed -lt $timeout ]; do
        if eval "$check_cmd" &>/dev/null; then
            echo " OK (${elapsed}s)"
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        echo -n "."
    done
    echo " TIMEOUT (${timeout}s)"
    echo "[BOOT] WARNING: ${name} did not become healthy in ${timeout}s"
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
        echo "[BOOT]   Image ${image_ref} missing — loading from cache..."
        if docker load < "$tarball" 2>&1; then
            echo "[BOOT]   Loaded ${cache_name} from cache."
            return 0
        else
            echo "[BOOT]   FAILED to load ${cache_name} from cache."
            return 1
        fi
    fi

    echo "[BOOT]   Image ${image_ref} not available and no cached tarball."
    return 1
}

ensure_ip_on_interface() {
    local iface="$1"
    local ip="$2"
    local timeout="${3:-15}"

    ip link set "$iface" up 2>/dev/null || true
    ip addr add "${ip}/24" dev "$iface" 2>/dev/null || true

    for i in $(seq 1 "$timeout"); do
        if ip addr show "$iface" 2>/dev/null | grep -q "$ip"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# =========================================================================
# Step 1/9: Swap + Watchdog
# =========================================================================
echo "[BOOT] Step 1/9: Enabling swap and hardware watchdog..."

RAM_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
DESIRED_MB=${RAM_MB:-2048}
[ "$DESIRED_MB" -lt 1024 ] 2>/dev/null && DESIRED_MB=1024
[ "$DESIRED_MB" -gt 4096 ] 2>/dev/null && DESIRED_MB=4096

if [ -f "$SWAP_FILE" ] && ! swapon --show | grep -q "$SWAP_FILE"; then
    swapon "$SWAP_FILE" 2>/dev/null && \
        echo "[BOOT]   Swap enabled ($(du -h $SWAP_FILE | cut -f1))" || \
        echo "[BOOT]   Swap enable failed (non-fatal)"
elif swapon --show | grep -q "$SWAP_FILE"; then
    echo "[BOOT]   Swap already active"
else
    echo "[BOOT]   Creating ${DESIRED_MB}MB swap..."
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$DESIRED_MB" 2>/dev/null && \
        chmod 600 "$SWAP_FILE" && \
        mkswap "$SWAP_FILE" && \
        swapon "$SWAP_FILE" && \
        echo "[BOOT]   Swap created (${DESIRED_MB}MB)" || \
        echo "[BOOT]   Swap creation failed (non-fatal)"
fi

if [ -e /dev/watchdog ]; then
    systemctl start watchdog 2>/dev/null || true
    echo "[BOOT]   Watchdog enabled (15s timeout)"
else
    echo "[BOOT]   No watchdog device found"
fi

echo "[BOOT]   $(free -h | awk '/^Mem:/{printf "RAM: total=%s avail=%s", $2, $7}') $(free -h | awk '/^Swap:/{printf "Swap: %s", $2}')"

# =========================================================================
# Step 2/9: Ensure wlan0 has gateway IP (BEFORE Swarm needs it)
# =========================================================================
echo "[BOOT] Step 2/9: Configuring network interface..."

# Apply netplan (assigns IP from config file)
netplan apply 2>/dev/null || true

# Belt-and-suspenders: explicitly assign IP + bring interface up.
# Netplan may not apply immediately on NO-CARRIER interfaces (first boot
# before hostapd starts). This ensures the IP is there for Swarm init.
if ensure_ip_on_interface wlan0 "$GATEWAY_IP" 10; then
    echo "[BOOT]   wlan0 has ${GATEWAY_IP}"
else
    echo "[BOOT]   WARNING: Could not assign ${GATEWAY_IP} to wlan0"
    echo "[BOOT]   Swarm init will use fallback strategy"
fi

# =========================================================================
# Step 3/9: Generate AP credentials + device secrets
# =========================================================================
echo "[BOOT] Step 3/9: Generating credentials..."

/usr/local/bin/cubeos-generate-ap-creds.sh
source "${CONFIG_DIR}/ap.env" 2>/dev/null || true
echo "[BOOT]   SSID: ${CUBEOS_AP_SSID:-CubeOS-Setup}"
echo "[BOOT]   Key:  ${CUBEOS_AP_KEY:-cubeos-setup}"

/usr/local/bin/cubeos-generate-secrets.sh
source "${CONFIG_DIR}/secrets.env" 2>/dev/null || true
echo "[BOOT]   Secrets generated"

# =========================================================================
# Step 4/9: Docker + Swarm initialization (multi-attempt)
# =========================================================================
echo "[BOOT] Step 4/9: Initializing Docker Swarm..."

wait_for "Docker" "docker info" 120 || {
    echo "[BOOT] FATAL: Docker failed to start. Cannot continue."
    exit 1
}

if docker info 2>/dev/null | grep -q "Swarm: active"; then
    echo "[BOOT]   Swarm already active."
    SWARM_READY=true
else
    echo "[BOOT]   Initializing Swarm..."

    # Attempt 1: Standard init
    if docker swarm init \
        --advertise-addr "$GATEWAY_IP" \
        --listen-addr "0.0.0.0:2377" \
        --task-history-limit 1 2>&1; then
        SWARM_READY=true
        echo "[BOOT]   Swarm initialized (attempt 1)."
    else
        echo "[BOOT]   Attempt 1 failed. Retrying with force-new-cluster..."
        sleep 2

        # Attempt 2: Force new cluster
        if docker swarm init \
            --advertise-addr "$GATEWAY_IP" \
            --listen-addr "0.0.0.0:2377" \
            --force-new-cluster \
            --task-history-limit 1 2>&1; then
            SWARM_READY=true
            echo "[BOOT]   Swarm initialized (attempt 2, force-new-cluster)."
        else
            echo "[BOOT]   Attempt 2 failed. Trying without --advertise-addr..."
            sleep 2

            # Attempt 3: Let Docker pick the address
            if docker swarm init \
                --listen-addr "0.0.0.0:2377" \
                --task-history-limit 1 2>&1; then
                SWARM_READY=true
                echo "[BOOT]   Swarm initialized (attempt 3, auto-addr)."
                echo "[BOOT]   WARNING: Swarm may not be advertising on ${GATEWAY_IP}"
            else
                echo "[BOOT]   CRITICAL: All Swarm init attempts failed!"
                echo "[BOOT]   Compose services will still deploy."
                echo "[BOOT]   Stack services (API, Dashboard) will be skipped."
            fi
        fi
    fi
fi

# Create overlay network + secrets (only if Swarm is active)
if [ "$SWARM_READY" = true ]; then
    if ! docker network ls --format '{{.Name}}' | grep -q "^cubeos$"; then
        echo "[BOOT]   Creating cubeos overlay network..."
        docker network create \
            --driver overlay \
            --attachable \
            --subnet 172.20.0.0/24 \
            cubeos 2>/dev/null || true
    fi

    if [ -n "${CUBEOS_JWT_SECRET:-}" ]; then
        echo -n "$CUBEOS_JWT_SECRET" | docker secret create jwt_secret - 2>/dev/null && \
            echo "[BOOT]   Created jwt_secret" || \
            echo "[BOOT]   jwt_secret already exists"
        echo -n "$CUBEOS_API_SECRET" | docker secret create api_secret - 2>/dev/null && \
            echo "[BOOT]   Created api_secret" || \
            echo "[BOOT]   api_secret already exists"
        SECRETS_READY=true
    else
        echo "[BOOT]   WARNING: No secrets available to create!"
    fi
else
    echo "[BOOT]   Skipping overlay network and secrets (Swarm not active)."
fi

# =========================================================================
# Step 5/9: Deploy Pi-hole (DNS/DHCP first — so WiFi clients get DNS)
# =========================================================================
echo "[BOOT] Step 5/9: Deploying infrastructure..."

echo "[BOOT]   Deploying Pi-hole..."
ensure_image_loaded "pihole/pihole:latest" "pihole" || true

source "${CONFIG_DIR}/defaults.env" 2>/dev/null || true
DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose \
    -f "${COREAPPS_DIR}/pihole/appconfig/docker-compose.yml" \
    --env-file "${COREAPPS_DIR}/pihole/appconfig/.env" \
    up -d --pull never 2>&1 || echo "[BOOT]   WARNING: Pi-hole deploy failed"

# Use port 53 check (faster than HTTP /admin/) — Pi-hole DNS is what matters
wait_for "Pi-hole DNS" "dig @127.0.0.1 localhost +short +timeout=1 +tries=1" 90 1 || true

# Seed custom DNS entries
PIHOLE_HOSTS="/cubeos/coreapps/pihole/appdata/etc-pihole/hosts/custom.list"
mkdir -p "$(dirname "$PIHOLE_HOSTS")"
cat > "$PIHOLE_HOSTS" << EOF
${GATEWAY_IP} cubeos.cube
${GATEWAY_IP} api.cubeos.cube
${GATEWAY_IP} npm.cubeos.cube
EOF
docker exec cubeos-pihole pihole reloaddns 2>/dev/null || true

# =========================================================================
# Step 6/9: Start WiFi AP (AFTER Pi-hole — clients get DHCP+DNS immediately)
# =========================================================================
echo "[BOOT] Step 6/9: Starting WiFi Access Point..."

rfkill unblock wifi 2>/dev/null || true
systemctl unmask hostapd 2>/dev/null || true
systemctl start hostapd 2>/dev/null && {
    echo "[BOOT]   AP started: ${CUBEOS_AP_SSID:-CubeOS-Setup}"
    echo "[BOOT]   Users can connect to WiFi now (services still loading)"
} || {
    echo "[BOOT]   WARNING: hostapd failed to start"
    echo "[BOOT]   Users can connect via ethernet to ${GATEWAY_IP}"
}

# =========================================================================
# Step 7/9: Deploy NPM + HAL
# =========================================================================
echo "[BOOT] Step 7/9: Deploying NPM + HAL..."

# CRITICAL: Ensure /etc/resolv.conf has a nameserver.
# NPM generates nginx resolvers.conf from /etc/resolv.conf.
# Without a nameserver entry, NPM enters a crash loop:
#   "nginx: [emerg] no name servers defined in resolvers.conf:1"
if ! grep -q "^nameserver" /etc/resolv.conf 2>/dev/null; then
    echo "[BOOT]   Fixing /etc/resolv.conf (no nameserver entry found)"
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
fi

echo "[BOOT]   Deploying NPM..."
ensure_image_loaded "jc21/nginx-proxy-manager:latest" "npm" || true

DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose \
    -f "${COREAPPS_DIR}/npm/appconfig/docker-compose.yml" \
    up -d --pull never 2>&1 || echo "[BOOT]   WARNING: NPM deploy failed"

wait_for "NPM" "curl -sf http://127.0.0.1:81/api/" 90 || true

echo "[BOOT]   Deploying HAL..."
ensure_image_loaded "ghcr.io/cubeos-app/hal:latest" "cubeos-hal" || true

DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose \
    -f "${COREAPPS_DIR}/cubeos-hal/appconfig/docker-compose.yml" \
    up -d --pull never 2>&1 || echo "[BOOT]   WARNING: HAL deploy failed"

wait_for "HAL" "curl -sf http://127.0.0.1:6013/health" 30 || true

# =========================================================================
# Step 8/9: Deploy Swarm stacks — GATED on Swarm + Secrets
# =========================================================================
echo "[BOOT] Step 8/9: Deploying platform services..."

if [ "$SWARM_READY" = true ] && [ "$SECRETS_READY" = true ]; then

    echo "[BOOT]   Deploying cubeos-api stack..."
    ensure_image_loaded "ghcr.io/cubeos-app/api:latest" "cubeos-api" || true

    docker stack deploy \
        -c "${COREAPPS_DIR}/cubeos-api/appconfig/docker-compose.yml" \
        --resolve-image never \
        cubeos-api 2>&1 || echo "[BOOT]   WARNING: API stack deploy failed"

    wait_for "API" "curl -sf http://127.0.0.1:6010/health" 120 || true

    echo "[BOOT]   Deploying cubeos-dashboard stack..."
    ensure_image_loaded "ghcr.io/cubeos-app/dashboard:latest" "cubeos-dashboard" || true

    docker stack deploy \
        -c "${COREAPPS_DIR}/cubeos-dashboard/appconfig/docker-compose.yml" \
        --resolve-image never \
        cubeos-dashboard 2>&1 || echo "[BOOT]   WARNING: Dashboard stack deploy failed"

    wait_for "Dashboard" "curl -sf http://127.0.0.1:6011/" 60 || true

elif [ "$SWARM_READY" = true ]; then
    echo "[BOOT]   SKIPPED: Stacks need secrets. Run cubeos-deploy-stacks.sh to recover."
else
    echo "[BOOT]   SKIPPED: Stacks need Docker Swarm. Run cubeos-deploy-stacks.sh to recover."
fi

# =========================================================================
# Step 9/9: Verification
# =========================================================================
echo "[BOOT] Step 9/9: Verification..."

BOOT_END=$(date +%s)
BOOT_DURATION=$((BOOT_END - BOOT_START))

echo ""
echo "============================================================"
echo "  CubeOS First Boot Complete! (${BOOT_DURATION}s)"
echo "============================================================"
echo ""

FAILURES=0

check_status() {
    local name="$1"
    local cmd="$2"
    if eval "$cmd" &>/dev/null; then
        echo "  [OK]  ${name}"
    else
        echo "  [!!]  ${name}"
        FAILURES=$((FAILURES + 1))
    fi
}

echo "  Service Status:"
echo "  ─────────────────────────────────────────"
check_status "Docker Swarm                    " "docker info 2>/dev/null | grep -q 'Swarm: active'"
check_status "hostapd (WiFi AP)               " "systemctl is-active hostapd"
check_status "Pi-hole (DNS/DHCP)         :6001" "curl -sf http://127.0.0.1:6001/admin/"
check_status "NPM (Reverse Proxy)        :81  " "curl -sf http://127.0.0.1:81/api/"
check_status "HAL (Hardware)             :6013" "curl -sf http://127.0.0.1:6013/health"
check_status "API (Backend)              :6010" "curl -sf http://127.0.0.1:6010/health"
check_status "Dashboard (Frontend)       :6011" "curl -sf http://127.0.0.1:6011/"

echo ""
echo "  ─────────────────────────────────────────"

if [ "$FAILURES" -gt 0 ]; then
    echo ""
    echo "  ${FAILURES} service(s) not healthy."
    echo "  Watchdog will attempt recovery every 60s."
    echo "  Manual recovery: cubeos-deploy-stacks.sh"
    echo "  Logs: journalctl -u cubeos-init -e"
fi

echo ""
echo "  WiFi:      ${CUBEOS_AP_SSID:-CubeOS-Setup} / ${CUBEOS_AP_KEY:-cubeos-setup}"
echo "  Dashboard: http://cubeos.cube  or  http://${GATEWAY_IP}"
echo "  Login:     admin / cubeos"
echo ""
echo "============================================================"
