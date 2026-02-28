#!/bin/bash
# =============================================================================
# cubeos-boot-lib.sh — CubeOS Boot Shared Library (v13 - Alpha.23)
# =============================================================================
# Sourced by both cubeos-first-boot.sh and cubeos-normal-boot.sh.
# Contains all shared functions, constants, and configuration arrays.
#
# SINGLE SOURCE OF TRUTH for:
#   - NPM proxy rules (10 rules)
#   - Pi-hole custom DNS entries (10 entries)
#   - Log formatting (ASCII markers)
#   - Common helpers (wait_for, container_running, etc.)
#   - WiFi AP configuration
#   - Watchdog management
#   - Network mode (6 distinct netplan templates)
#
# v14 — beta.05:
#   - Migrated all Pi-hole config from docker exec pihole-FTL --config to v6 REST API
#   - Added wait_for_pihole_api(), pihole_api_login(), pihole_api_set_dhcp(), etc.
#   - configure_pihole_dhcp() now uses REST API with 5-retry, verification, toml fallback
#   - seed_pihole_dns() now uses REST API bulk sync with custom.list fallback
#
# v13 — ALPHA.23 (Batch 2):
#   - B82: seed_pihole_dns() rewritten to use pihole-FTL --config dns.hosts
#     (JSON array persisted to pihole.toml). custom.list kept as fallback.
#
# v12 — ALPHA.22 (Network Modes Batch 1):
#   - T02: Split write_netplan_for_mode() from 3 cases into 5 distinct templates
#     - offline_hotspot: eth0 no address (B92 fix), wlan0 static AP
#     - wifi_router: eth0 DHCP client, wlan0 static AP
#     - wifi_bridge: wlan1 WiFi client (upstream), wlan0 static AP, no eth0
#     - eth_client / wifi_client: unchanged
#   - Added configure_pihole_dhcp() for boot-time Pi-hole DHCP config
#
# v11 — ALPHA.18:
#   - B16: Replaced overlay network scope-verify loop with retry-on-create
#   - deploy_stack() uses ensure_overlay_network() for recreation (not raw create)
#
# v10 — ALPHA.14:
#   - Removed Ollama + ChromaDB (9 proxy rules, 9 DNS entries, 4 Swarm stacks)
#   - deploy-stacks sources defaults.env for version wiring (B59)
#   - configure_wifi_ap() reads country code from defaults.env (B55)
# =============================================================================

# ── Constants ────────────────────────────────────────────────────────
GATEWAY_IP="10.42.24.1"
SUBNET="10.42.24.0/24"
OVERLAY_SUBNET="10.42.25.0/24"
NETWORK_NAME="cubeos-network"
HAL_OVERLAY_SUBNET="10.42.26.0/24"
HAL_NETWORK_NAME="hal-internal"
CONFIG_DIR="/cubeos/config"
COREAPPS_DIR="/cubeos/coreapps"
DATA_DIR="/cubeos/data"
CACHE_DIR="/var/cache/cubeos-images"
SETUP_FLAG="/cubeos/data/.setup_complete"
# B37: Provisioned flag = first-boot script completed (services deployed).
# Separate from wizard completion (tracked in DB by API).
PROVISIONED_FLAG="/cubeos/data/.provisioned"
LOG_FILE="${LOG_FILE:-/var/log/cubeos-boot.log}"

# ── Source defaults.env early (provides CUBEOS_VERSION, TZ, DOMAIN, etc.) ──
[ -f "${CONFIG_DIR}/defaults.env" ] && source "${CONFIG_DIR}/defaults.env" 2>/dev/null || true

# ── NPM Proxy Rules (Single Source of Truth) ─────────────────────────
# Format: "domain:port:coreapp_name"
# coreapp_name is used to check if the service exists on this variant.
# Rules for always-present services (pihole, npm, hal, api, dashboard,
# registry, terminal) are always included; optional ones are filtered.
_ALL_PROXY_RULES=(
    "cubeos.cube:6011:cubeos-dashboard"
    "api.cubeos.cube:6010:cubeos-api"
    "docs.cubeos.cube:6032:cubeos-docsindex"
    "pihole.cubeos.cube:6001:pihole"
    "npm.cubeos.cube:81:npm"
    "registry.cubeos.cube:5000:registry"
    "hal.cubeos.cube:6005:cubeos-hal"
    "dozzle.cubeos.cube:6012:dozzle"
    "terminal.cubeos.cube:6042:terminal"
    "kiwix.cubeos.cube:6043:kiwix"
)

# ── Pi-hole Custom DNS Entries (Single Source of Truth) ──────────────
# Format: "hostname:coreapp_name"
_ALL_DNS_HOSTS=(
    "cubeos.cube:cubeos-dashboard"
    "api.cubeos.cube:cubeos-api"
    "npm.cubeos.cube:npm"
    "pihole.cubeos.cube:pihole"
    "hal.cubeos.cube:cubeos-hal"
    "dozzle.cubeos.cube:dozzle"
    "registry.cubeos.cube:registry"
    "docs.cubeos.cube:cubeos-docsindex"
    "terminal.cubeos.cube:terminal"
    "kiwix.cubeos.cube:kiwix"
)

# Build active arrays by filtering on coreapps present on disk.
# Services without a coreapps dir (e.g., cubeos-docsindex on lite) are excluded.
_build_active_arrays() {
    CORE_PROXY_RULES=()
    CORE_DNS_HOSTS=()

    for entry in "${_ALL_PROXY_RULES[@]}"; do
        local domain="${entry%%:*}"
        local rest="${entry#*:}"
        local port="${rest%%:*}"
        local svc="${rest#*:}"
        if [ -d "${COREAPPS_DIR}/${svc}" ]; then
            CORE_PROXY_RULES+=("${domain}:${port}")
        fi
    done

    for entry in "${_ALL_DNS_HOSTS[@]}"; do
        local host="${entry%%:*}"
        local svc="${entry#*:}"
        if [ -d "${COREAPPS_DIR}/${svc}" ]; then
            CORE_DNS_HOSTS+=("${host}")
        fi
    done
}
_build_active_arrays

# ── Swarm Stacks ─────────────────────────────────────────────────────
# B08: Split into pre-API and post-API stacks.
# Dashboard deploys AFTER API health check to prevent 502/wizard flash.
# Canonical ordering — deploy_stack() skips stacks with no compose file,
# so these lists are safe for both Full and Lite variants.
SWARM_STACKS_BOOTSTRAP="registry"
SWARM_STACKS_PRE_API="cubeos-api cubeos-docsindex dozzle"
SWARM_STACKS_POST_API="cubeos-dashboard kiwix"
# Combined list for recovery/normal boot where ordering is less critical
SWARM_STACKS="registry cubeos-api cubeos-docsindex dozzle cubeos-dashboard kiwix"

# ── Compose Services ─────────────────────────────────────────────────
COMPOSE_SERVICES="pihole npm cubeos-hal terminal"

# ── Variant Detection ────────────────────────────────────────────────
# Read CUBEOS_VARIANT from defaults.env (set at image build time).
# Used for logging — actual behavior is driven by presence of compose files.
_detect_variant() {
    local variant="full"
    if [ -f "${CONFIG_DIR}/defaults.env" ]; then
        variant=$(grep '^CUBEOS_VARIANT=' "${CONFIG_DIR}/defaults.env" 2>/dev/null | cut -d= -f2 || echo "full")
    fi
    echo "${variant:-full}"
}
CUBEOS_VARIANT="$(_detect_variant)"

# ── Logging (ASCII-only markers) ─────────────────────────────────────
log() {
    local msg
    msg="$(date '+%Y-%m-%d %H:%M:%S') $*"
    echo "$msg" >> "$LOG_FILE"
    echo "$msg" >&2
}

log_ok()   { log "OK: $*"; }
log_warn() { log "WARN: $*"; }
log_fail() { log "FAIL: $*"; FAILURES=$((FAILURES + 1)); }

# ── Helpers ──────────────────────────────────────────────────────────
wait_for() {
    local name="$1" check_cmd="$2" max_wait="${3:-30}" interval="${4:-2}" elapsed=0
    log "Waiting for ${name}..."
    while [ $elapsed -lt $max_wait ]; do
        if eval "$check_cmd" &>/dev/null; then
            log_ok "${name} ready (${elapsed}s)"
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        # Update heartbeat if it exists (first-boot uses this)
        [ -f "${HEARTBEAT:-}" ] && date +%s > "$HEARTBEAT"
    done
    log_warn "${name} not ready after ${max_wait}s"
    return 1
}

# ── Registry health gate ──────────────────────────────────────────
wait_for_registry() {
    local max_wait="${1:-30}"
    log "Waiting for local registry (localhost:5000)..."
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        if curl -sf http://localhost:5000/v2/ &>/dev/null; then
            log_ok "Registry healthy (${elapsed}s)"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    log_warn "Registry not healthy after ${max_wait}s -- continuing (--pull never uses Docker cache)"
    return 0  # Non-blocking: always return success
}

container_running() {
    docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null | grep -q true
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

# ── Docker Stack Deploy (with retry + network check) ────────────────
deploy_stack() {
    local name="$1"
    local compose_file="${COREAPPS_DIR}/${name}/appconfig/docker-compose.yml"
    if [ ! -f "$compose_file" ]; then
        log_warn "No compose file for stack ${name}"
        return 1
    fi

    # Verify overlay network exists before deploying
    if ! docker network inspect "$NETWORK_NAME" &>/dev/null; then
        log_warn "Network ${NETWORK_NAME} gone before deploying ${name} -- recreating"
        ensure_overlay_network || {
            log_warn "Network recreation failed -- attempting deploy anyway"
        }
    fi

    local attempt
    for attempt in 1 2 3; do
        log "  Deploying stack: ${name} (attempt ${attempt})..."
        if docker stack deploy -c "$compose_file" --resolve-image never "$name" 2>&1; then
            log_ok "Stack ${name} deployed"
            return 0
        fi
        sleep 3
    done
    log_fail "Stack ${name} deploy failed after 3 attempts"
    return 1
}

# ── WiFi AP Configuration ────────────────────────────────────────────
configure_wifi_ap() {
    source "${CONFIG_DIR}/ap.env" 2>/dev/null || true
    # Read country code from defaults.env (B55: avoid hardcoded US fallback)
    source "${CONFIG_DIR}/defaults.env" 2>/dev/null || true
    rfkill unblock wifi 2>/dev/null || true

    # Get country code from config (cfg80211 handles kernel-level regulatory domain)
    local COUNTRY_CODE="${CUBEOS_COUNTRY_CODE:-NL}"
    log "Setting regulatory domain: $COUNTRY_CODE"
    iw reg set "$COUNTRY_CODE" 2>/dev/null || true
    sleep 2  # Give kernel time to apply regulatory domain

    if systemctl start hostapd 2>/dev/null; then
        sleep 3
        # Cap TX power to regulatory maximum (20 dBm for NL/ETSI on 2.4GHz).
        # The BCM4345 driver defaults to 31 dBm which exceeds the regulatory
        # limit and silently suppresses beacon transmission.
        iw dev "${CUBEOS_AP_IFACE:-wlan0}" set txpower fixed 2000 2>/dev/null || true
        # Read live SSID from hostapd.conf (wizard may have changed it)
        local LIVE_SSID
        LIVE_SSID=$(grep '^ssid=' /etc/hostapd/hostapd.conf 2>/dev/null | cut -d= -f2)
        local DISPLAY_SSID="${LIVE_SSID:-${CUBEOS_AP_SSID:-CubeOS-Setup}}"
        if iw dev "${CUBEOS_AP_IFACE:-wlan0}" info 2>/dev/null | grep -q "type AP"; then
            log_ok "WiFi AP broadcasting: ${DISPLAY_SSID} (country: $COUNTRY_CODE)"
            return 0
        else
            log_warn "WiFi AP not broadcasting -- restarting hostapd..."
            iw reg set "$COUNTRY_CODE" 2>/dev/null || true
            sleep 1
            systemctl restart hostapd 2>/dev/null || true
            sleep 2
            iw dev "${CUBEOS_AP_IFACE:-wlan0}" set txpower fixed 2000 2>/dev/null || true
            if iw dev "${CUBEOS_AP_IFACE:-wlan0}" info 2>/dev/null | grep -q "type AP"; then
                log_ok "WiFi AP recovered after restart: ${DISPLAY_SSID}"
                return 0
            else
                log_warn "WiFi AP STILL not broadcasting -- manual intervention needed"
                return 1
            fi
        fi
    else
        log_warn "hostapd failed -- ethernet access only at ${GATEWAY_IP}"
        return 1
    fi
}

# ── ZRAM Swap ────────────────────────────────────────────────────────
ensure_zram() {
    if swapon --show 2>/dev/null | grep -q zram; then
        log_ok "ZRAM swap active"
    else
        systemctl start systemd-zram-setup@zram0.service 2>/dev/null || true
        sleep 2
        swapon --show 2>/dev/null | grep -q zram && log_ok "ZRAM swap started" || log_warn "ZRAM swap not available"
    fi
}

# ── Hardware Watchdog (non-blocking) ─────────────────────────────────
start_watchdog() {
    if [ -e /dev/watchdog ]; then
        systemctl start watchdog --no-block 2>/dev/null || true
        log_ok "Hardware watchdog starting (non-blocking)"
    fi
}

# ── DNS Resolver Fallback ────────────────────────────────────────────
ensure_dns_resolver() {
    if ! grep -q "^nameserver" /etc/resolv.conf 2>/dev/null; then
        log "Fixing /etc/resolv.conf (no nameserver)"
        echo "nameserver 127.0.0.1" > /etc/resolv.conf
    fi
}

# ── Image version pins ────────────────────────────────────────────
source_image_versions() {
    if [ -f "${COREAPPS_DIR}/image-versions.env" ]; then
        source "${COREAPPS_DIR}/image-versions.env"
        log_ok "Sourced image-versions.env"
    else
        log_warn "image-versions.env not found -- using default tags"
    fi
}

# ── Swarm Recovery ───────────────────────────────────────────────────
recover_swarm() {
    if docker info 2>/dev/null | grep -q "Swarm: active"; then
        return 0  # Already active
    fi

    log "Swarm not active! Recovering..."
    local SWARM_OUTPUT

    SWARM_OUTPUT=$(docker swarm init \
        --advertise-addr "$GATEWAY_IP" \
        --listen-addr "0.0.0.0:2377" \
        --force-new-cluster \
        --task-history-limit 1 2>&1) && {
        log_ok "Swarm recovered (force-new-cluster)"
        return 0
    } || {
        log "  Attempt 1 failed: ${SWARM_OUTPUT}"
        SWARM_OUTPUT=$(docker swarm init \
            --listen-addr "0.0.0.0:2377" \
            --task-history-limit 1 2>&1) && {
            log_ok "Swarm recovered (auto-addr)"
            return 0
        } || {
            log_warn "Swarm recovery failed: ${SWARM_OUTPUT}"
            return 1
        }
    }
}

# ── Overlay Network Create (retry-on-create) ────────────────────────
ensure_overlay_network() {
    # B16 FIX: Retry on CREATE, not on scope verification.
    # Previous approach wasted 60s verifying "swarm" scope — unreliable.
    # New approach: remove bad networks, create with retries, verify existence only.

    # Step 1: Remove network if it exists with wrong scope (local instead of swarm)
    local NETWORK_SCOPE
    NETWORK_SCOPE=$(docker network inspect "$NETWORK_NAME" --format '{{.Scope}}' 2>/dev/null || echo "none")
    if [ "$NETWORK_SCOPE" = "local" ]; then
        log "Removing local ${NETWORK_NAME} (wrong scope)..."
        docker network rm "$NETWORK_NAME" 2>/dev/null || true
        sleep 2
        NETWORK_SCOPE="none"
    fi

    # Step 2: If network already exists with correct scope, we're done
    if [ "$NETWORK_SCOPE" = "swarm" ]; then
        log_ok "${NETWORK_NAME} overlay already exists"
        return 0
    fi

    # Step 3: Create with retries and backoff
    local attempt sleep_time=2
    for attempt in 1 2 3 4 5; do
        log "  Creating overlay network (attempt ${attempt}/5)..."
        if docker network create \
            --driver overlay \
            --attachable \
            --subnet "$OVERLAY_SUBNET" \
            "$NETWORK_NAME" 2>&1; then
            # Verify it actually exists (quick check, no scope wait)
            sleep 1
            if docker network inspect "$NETWORK_NAME" &>/dev/null; then
                log_ok "${NETWORK_NAME} overlay created (attempt ${attempt})"
                return 0
            fi
        fi
        log "  Attempt ${attempt} failed -- waiting ${sleep_time}s..."
        sleep "$sleep_time"
        # Backoff: 2, 4, 6, 8, 10
        sleep_time=$((sleep_time + 2))
    done
    log_warn "${NETWORK_NAME} overlay creation failed after 5 attempts -- stacks may fail"
    return 1
}

# ── HAL-Internal Overlay Network ─────────────────────────────────────
# Restricted overlay network for services authorized to access HAL.
# Only cubeos-api joins this network — user apps never do.
# HAL itself runs on host network (required for hardware access) and
# is reachable via the gateway IP (10.42.24.1:6005). This network
# provides an organizational boundary; ACL keys (X-HAL-Key) provide
# the actual authentication layer.
ensure_hal_internal_network() {
    local NETWORK_SCOPE
    NETWORK_SCOPE=$(docker network inspect "$HAL_NETWORK_NAME" --format '{{.Scope}}' 2>/dev/null || echo "none")
    if [ "$NETWORK_SCOPE" = "local" ]; then
        log "Removing local ${HAL_NETWORK_NAME} (wrong scope)..."
        docker network rm "$HAL_NETWORK_NAME" 2>/dev/null || true
        sleep 2
        NETWORK_SCOPE="none"
    fi

    if [ "$NETWORK_SCOPE" = "swarm" ]; then
        log_ok "${HAL_NETWORK_NAME} overlay already exists"
        return 0
    fi

    local attempt sleep_time=2
    for attempt in 1 2 3; do
        log "  Creating ${HAL_NETWORK_NAME} overlay (attempt ${attempt}/3)..."
        if docker network create \
            --driver overlay \
            --attachable \
            --subnet "$HAL_OVERLAY_SUBNET" \
            "$HAL_NETWORK_NAME" 2>&1; then
            sleep 1
            if docker network inspect "$HAL_NETWORK_NAME" &>/dev/null; then
                log_ok "${HAL_NETWORK_NAME} overlay created (attempt ${attempt})"
                return 0
            fi
        fi
        log "  Attempt ${attempt} failed -- waiting ${sleep_time}s..."
        sleep "$sleep_time"
        sleep_time=$((sleep_time + 2))
    done
    log_warn "${HAL_NETWORK_NAME} overlay creation failed after 3 attempts"
    return 1
}

# ── HAL Port Protection (iptables) ───────────────────────────────────
# Block external access to HAL port 6005. Docker containers reach HAL
# via the gateway IP, which is internal. External interfaces (eth0,
# wlan0 station mode) should not expose HAL to the broader network.
protect_hal_port() {
    local HAL_PORT=6005
    local CHAIN="CUBEOS_HAL"

    # Create or flush the custom chain
    iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"

    # Allow localhost (healthchecks, local tools)
    iptables -A "$CHAIN" -i lo -j ACCEPT

    # Allow Docker bridge networks (containers reaching host via gateway)
    iptables -A "$CHAIN" -i docker0 -j ACCEPT
    iptables -A "$CHAIN" -i docker_gwbridge -j ACCEPT
    iptables -A "$CHAIN" -i br-+ -j ACCEPT

    # Allow from AP subnet (10.42.24.0/24 — host-network services)
    iptables -A "$CHAIN" -s "${SUBNET}" -j ACCEPT

    # Drop everything else (external networks)
    iptables -A "$CHAIN" -j DROP

    # Insert jump to our chain in INPUT (idempotent — remove first if exists)
    iptables -D INPUT -p tcp --dport "$HAL_PORT" -j "$CHAIN" 2>/dev/null || true
    iptables -I INPUT -p tcp --dport "$HAL_PORT" -j "$CHAIN"

    log_ok "HAL port ${HAL_PORT} protected (external access blocked)"
}

# ── Pi-hole v6 REST API Helpers ──────────────────────────────────────
# These functions replace ALL docker exec pihole-FTL --config usage.
# Pi-hole v6 uses a REST API at http://127.0.0.1:6001/api/
# See CLAUDE.md "Pi-hole v6 REST API Quick Reference" for full details.

# Wait for Pi-hole FTL to be fully ready (config engine, not just web UI).
# Uses the unauthenticated /api/info/login endpoint which only returns 200
# when FTL is ready. This replaces the old "curl /admin/" health check.
wait_for_pihole_api() {
    local max_attempts="${1:-30}"
    local sleep_interval="${2:-3}"
    log "Waiting for Pi-hole FTL API to be ready..."
    for i in $(seq 1 "$max_attempts"); do
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:6001/api/info/login" 2>/dev/null)
        if [ "$HTTP_CODE" = "200" ]; then
            log_ok "Pi-hole FTL API ready (attempt $i/$max_attempts)"
            return 0
        fi
        log "Pi-hole FTL API not ready (HTTP $HTTP_CODE), retrying in ${sleep_interval}s... ($i/$max_attempts)"
        sleep "$sleep_interval"
    done
    log_warn "Pi-hole FTL API not ready after $max_attempts attempts"
    return 1
}

# Get Pi-hole API session ID for authenticated operations.
# Reads password from CUBEOS_PIHOLE_PASSWORD env var or /cubeos/config/secrets.env.
# Usage: SID=$(pihole_api_login) || { log_warn "login failed"; return 1; }
pihole_api_login() {
    local password="${CUBEOS_PIHOLE_PASSWORD:-}"
    if [ -z "$password" ]; then
        # Try to read from secrets.env
        if [ -f /cubeos/config/secrets.env ]; then
            password=$(grep -oP '^CUBEOS_PIHOLE_PASSWORD=\K.*' /cubeos/config/secrets.env 2>/dev/null || true)
        fi
    fi
    if [ -z "$password" ]; then
        # Fallback to default Pi-hole password
        password="cubeos"
    fi

    local response
    response=$(curl -s -X POST "http://127.0.0.1:6001/api/auth" \
        -H "Content-Type: application/json" \
        -d "{\"password\":\"${password}\"}" 2>/dev/null)

    local sid
    sid=$(echo "$response" | jq -r '.session.sid // empty' 2>/dev/null)
    if [ -z "$sid" ]; then
        log_warn "Pi-hole API login failed: $response"
        return 1
    fi
    echo "$sid"
}

# Set Pi-hole DHCP active state via REST API.
# Usage: pihole_api_set_dhcp <true|false> <sid>
pihole_api_set_dhcp() {
    local active="$1"
    local sid="$2"
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X PUT "http://127.0.0.1:6001/api/config/dhcp/active/${active}" \
        -H "X-FTL-SID: ${sid}" 2>/dev/null)
    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ] || [ "$http_code" = "204" ]; then
        return 0
    fi
    log_warn "Pi-hole API set DHCP active=$active failed (HTTP $http_code)"
    return 1
}

# Read Pi-hole DHCP active state via REST API.
# Returns "true" or "false" on stdout.
pihole_api_get_dhcp() {
    local sid="$1"
    local response
    response=$(curl -s "http://127.0.0.1:6001/api/config/dhcp/active" \
        -H "X-FTL-SID: ${sid}" 2>/dev/null)
    echo "$response" | jq -r '.config.dhcp.active // "unknown"' 2>/dev/null
}

# Set Pi-hole dnsmasq_lines via REST API (PATCH with wrapped JSON).
# Usage: pihole_api_set_dnsmasq_lines <sid> <json_array_string>
# Example: pihole_api_set_dnsmasq_lines "$sid" '["address=/cubeos.cube/10.42.24.1","no-dhcp-interface=eth0"]'
pihole_api_set_dnsmasq_lines() {
    local sid="$1"
    local json_array="$2"
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X PATCH "http://127.0.0.1:6001/api/config/misc/dnsmasq_lines" \
        -H "Content-Type: application/json" \
        -H "X-FTL-SID: ${sid}" \
        -d "{\"config\":{\"misc\":{\"dnsmasq_lines\":${json_array}}}}" 2>/dev/null)
    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ] || [ "$http_code" = "204" ]; then
        return 0
    fi
    log_warn "Pi-hole API set dnsmasq_lines failed (HTTP $http_code)"
    return 1
}

# Add a DNS host entry via REST API.
# Usage: pihole_api_add_dns_host "10.42.24.1" "cubeos.cube" <sid>
pihole_api_add_dns_host() {
    local ip="$1"
    local hostname="$2"
    local sid="$3"
    local encoded="${ip}%20${hostname}"
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X PUT "http://127.0.0.1:6001/api/config/dns/hosts/${encoded}" \
        -H "X-FTL-SID: ${sid}" 2>/dev/null)
    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ] || [ "$http_code" = "204" ]; then
        return 0
    fi
    log_warn "Pi-hole API add DNS host $hostname -> $ip failed (HTTP $http_code)"
    return 1
}

# Bulk sync DNS host entries via REST API (replaces all existing entries).
# Usage: pihole_api_sync_dns_hosts <sid> <json_array_string>
# Example: pihole_api_sync_dns_hosts "$sid" '["10.42.24.1 cubeos.cube","10.42.24.1 api.cubeos.cube"]'
pihole_api_sync_dns_hosts() {
    local sid="$1"
    local json_array="$2"
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X PATCH "http://127.0.0.1:6001/api/config/dns/hosts" \
        -H "Content-Type: application/json" \
        -H "X-FTL-SID: ${sid}" \
        -d "{\"config\":{\"dns\":{\"hosts\":${json_array}}}}" 2>/dev/null)
    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ] || [ "$http_code" = "204" ]; then
        return 0
    fi
    log_warn "Pi-hole API sync DNS hosts failed (HTTP $http_code)"
    return 1
}

# ── Pi-hole DNS Seeding ──────────────────────────────────────────────
seed_pihole_dns() {
    # Pi-hole v6 stores dns.hosts in pihole.toml (persisted across restarts).
    # Primary: use Pi-hole v6 REST API to bulk-sync DNS host entries.
    # Fallback: write custom.list directly (for pre-API scenarios).

    log "Seeding Pi-hole DNS entries (${#CORE_DNS_HOSTS[@]} entries)..."

    # Build JSON array: ["10.42.24.1 cubeos.cube","10.42.24.1 api.cubeos.cube",...]
    local json_entries=""
    for host in "${CORE_DNS_HOSTS[@]}"; do
        [ -n "$json_entries" ] && json_entries="${json_entries},"
        json_entries="${json_entries}\"${GATEWAY_IP} ${host}\""
    done
    local json_array="[${json_entries}]"

    # Primary: use Pi-hole v6 REST API
    local api_ok=false
    if container_running cubeos-pihole; then
        if wait_for_pihole_api 15 2; then
            local sid
            sid=$(pihole_api_login)
            if [ $? -eq 0 ] && [ -n "$sid" ]; then
                if pihole_api_sync_dns_hosts "$sid" "$json_array"; then
                    api_ok=true
                else
                    log_warn "Pi-hole REST API dns.hosts sync failed -- falling back to custom.list"
                fi
            else
                log_warn "Pi-hole API login failed for DNS seeding -- falling back to custom.list"
            fi
        else
            log_warn "Pi-hole FTL API not ready for DNS seeding -- falling back to custom.list"
        fi
    else
        log_warn "Pi-hole not running -- writing custom.list only (API config on next boot)"
    fi

    # Belt-and-suspenders: also write custom.list directly
    local PIHOLE_HOSTS="/cubeos/coreapps/pihole/appdata/etc-pihole/hosts/custom.list"
    mkdir -p "$(dirname "$PIHOLE_HOSTS")"
    : > "$PIHOLE_HOSTS"
    for host in "${CORE_DNS_HOSTS[@]}"; do
        echo "${GATEWAY_IP} ${host}" >> "$PIHOLE_HOSTS"
    done

    if [ "$api_ok" = true ]; then
        log_ok "Pi-hole DNS seeded (${#CORE_DNS_HOSTS[@]} entries via REST API + custom.list)"
    else
        log_ok "Pi-hole DNS seeded (${#CORE_DNS_HOSTS[@]} entries via custom.list fallback)"
    fi
}

# ── Network Mode ─────────────────────────────────────────────────────

# Read persisted network config from SQLite.
# Sets global: NET_MODE, NET_WIFI_SSID, NET_WIFI_PASSWORD,
#              NET_USE_STATIC_IP, NET_STATIC_IP, NET_STATIC_NETMASK,
#              NET_STATIC_GATEWAY, NET_STATIC_DNS1, NET_STATIC_DNS2
# Fallback: NET_MODE=offline_hotspot if db missing or query fails.
read_persisted_network_config() {
    NET_MODE=""
    NET_WIFI_SSID=""
    NET_WIFI_PASSWORD=""
    NET_USE_STATIC_IP=""
    NET_STATIC_IP=""
    NET_STATIC_NETMASK=""
    NET_STATIC_GATEWAY=""
    NET_STATIC_DNS1=""
    NET_STATIC_DNS2=""
    local DB_PATH="${DATA_DIR}/cubeos.db"
    if [ -f "$DB_PATH" ]; then
        eval "$(python3 -c "
import sqlite3
try:
    conn = sqlite3.connect('${DB_PATH}')
    row = conn.execute('SELECT mode, wifi_ssid, wifi_password, use_static_ip, static_ip_address, static_ip_netmask, static_ip_gateway, static_dns_primary, static_dns_secondary FROM network_config WHERE id = 1').fetchone()
    if row:
        print(f'NET_MODE={row[0]}')
        # Shell-escape single quotes in SSID/password
        ssid = (row[1] or '').replace(\"'\", \"'\\\"'\\\"'\")
        pw = (row[2] or '').replace(\"'\", \"'\\\"'\\\"'\")
        print(f\"NET_WIFI_SSID='{ssid}'\")
        print(f\"NET_WIFI_PASSWORD='{pw}'\")
        # Static IP fields (T15 — Network Modes Batch 3)
        print(f'NET_USE_STATIC_IP={1 if row[3] else 0}')
        print(f\"NET_STATIC_IP='{row[4] or ''}'\")
        print(f\"NET_STATIC_NETMASK='{row[5] or '255.255.255.0'}'\")
        print(f\"NET_STATIC_GATEWAY='{row[6] or ''}'\")
        print(f\"NET_STATIC_DNS1='{row[7] or ''}'\")
        print(f\"NET_STATIC_DNS2='{row[8] or ''}'\")
    conn.close()
except: pass
" 2>/dev/null)" || true
    fi
    NET_MODE="${NET_MODE:-${CUBEOS_NETWORK_MODE:-offline_hotspot}}"
}

# =============================================================================
# WiFi AP Whitelist/Blacklist Check
# =============================================================================
# Checks if a USB WiFi adapter is whitelisted or blacklisted for AP mode.
# Reads HAL's JSON files at /cubeos/config/wifi-ap-{whitelist,blacklist}.json
# Returns: "whitelisted", "blacklisted", or "" (unknown)
check_wifi_ap_list() {
    local iface="$1"

    # Read USB device IDs from sysfs
    local device_path
    device_path=$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null) || return 0

    # Walk up to find idVendor/idProduct
    local vid="" pid="" path="$device_path"
    for _ in 1 2 3 4 5; do
        if [ -f "${path}/idVendor" ] && [ -f "${path}/idProduct" ]; then
            vid=$(cat "${path}/idVendor" 2>/dev/null | tr -d '[:space:]')
            pid=$(cat "${path}/idProduct" 2>/dev/null | tr -d '[:space:]')
            break
        fi
        path=$(dirname "$path")
        [ "$path" = "/" ] && break
    done

    [ -z "$vid" ] || [ -z "$pid" ] && return 0

    # Check whitelist
    if [ -f "/cubeos/config/wifi-ap-whitelist.json" ]; then
        if grep -q "\"vendor_id\".*\"${vid}\"" /cubeos/config/wifi-ap-whitelist.json 2>/dev/null &&
           grep -q "\"product_id\".*\"${pid}\"" /cubeos/config/wifi-ap-whitelist.json 2>/dev/null; then
            log "  USB WiFi ${vid}:${pid} found in AP whitelist"
            echo "whitelisted"
            return 0
        fi
    fi

    # Check blacklist
    if [ -f "/cubeos/config/wifi-ap-blacklist.json" ]; then
        if grep -q "\"vendor_id\".*\"${vid}\"" /cubeos/config/wifi-ap-blacklist.json 2>/dev/null &&
           grep -q "\"product_id\".*\"${pid}\"" /cubeos/config/wifi-ap-blacklist.json 2>/dev/null; then
            log "  USB WiFi ${vid}:${pid} found in AP blacklist"
            echo "blacklisted"
            return 0
        fi
    fi

    # Unknown — will be tested by HAL on first DetectInterfaces call
    echo ""
}

# =============================================================================
# Interface Detection — replaces all hardcoded wlan0/wlan1/eth0 references
# =============================================================================
# Sets: CUBEOS_AP_IFACE, CUBEOS_UPLINK_IFACE, CUBEOS_ETH_IFACE, CUBEOS_WIFI_CLIENT_IFACE
# Exports to /cubeos/config/interfaces.env for use by API and HAL containers
detect_interfaces() {
    log "Detecting network interfaces..."

    local ap_iface=""
    local uplink_iface=""
    local eth_iface=""
    local wifi_ifaces=()
    local builtin_wifi=""
    local usb_wifi=""

    # Scan /sys/class/net for physical interfaces
    for dir in /sys/class/net/*/; do
        local iface
        iface=$(basename "$dir")

        # Skip virtual interfaces
        case "$iface" in
            lo|docker*|veth*|br-*|virbr*) continue ;;
        esac

        # Detect type
        if [ -d "/sys/class/net/${iface}/wireless" ]; then
            wifi_ifaces+=("$iface")

            # Detect bus: SDIO/PCI = built-in, USB = external
            local subsystem=""
            if [ -L "/sys/class/net/${iface}/device/subsystem" ]; then
                subsystem=$(readlink -f "/sys/class/net/${iface}/device/subsystem" | xargs basename)
            fi

            case "$subsystem" in
                sdio|mmc|pci|pcie|platform)
                    builtin_wifi="$iface"
                    log "  WiFi (built-in): $iface [$subsystem]"
                    ;;
                usb)
                    usb_wifi="$iface"
                    log "  WiFi (USB): $iface [$subsystem]"
                    ;;
                *)
                    # Default: first WiFi without bus info treated as built-in
                    if [ -z "$builtin_wifi" ]; then
                        builtin_wifi="$iface"
                        log "  WiFi (assumed built-in): $iface"
                    else
                        usb_wifi="$iface"
                        log "  WiFi (assumed USB): $iface"
                    fi
                    ;;
            esac
        elif [ -d "/sys/class/net/${iface}/device" ]; then
            # Physical ethernet
            if [ -z "$eth_iface" ]; then
                eth_iface="$iface"
                log "  Ethernet: $iface"
            fi
        fi
    done

    # Role assignment: prefer USB WiFi for AP (better performance than built-in)
    # Check whitelist/blacklist from HAL's AP capability testing
    local usb_wifi_ap_ok=""
    if [ -n "$usb_wifi" ]; then
        usb_wifi_ap_ok=$(check_wifi_ap_list "$usb_wifi")
    fi

    if [ -n "$usb_wifi" ] && [ "$usb_wifi_ap_ok" != "blacklisted" ]; then
        # USB WiFi available and not blacklisted — prefer for AP
        ap_iface="$usb_wifi"
        log "  AP role: USB WiFi ($usb_wifi) — preferred for performance"
    elif [ -n "$builtin_wifi" ]; then
        # Fallback to built-in WiFi
        ap_iface="$builtin_wifi"
        log "  AP role: built-in WiFi ($builtin_wifi)"
    elif [ ${#wifi_ifaces[@]} -eq 1 ]; then
        ap_iface="${wifi_ifaces[0]}"
        log "  AP role: only WiFi ($ap_iface)"
    fi

    # Default uplink is ethernet (wifi_router mode default)
    uplink_iface="${eth_iface:-}"

    # Export as environment variables (with safe fallbacks)
    export CUBEOS_AP_IFACE="${ap_iface:-wlan0}"
    export CUBEOS_UPLINK_IFACE="${uplink_iface:-eth0}"
    export CUBEOS_ETH_IFACE="${eth_iface:-eth0}"
    export CUBEOS_WIFI_CLIENT_IFACE="${usb_wifi:-${ap_iface:-wlan0}}"
    export CUBEOS_BUILTIN_WIFI="${builtin_wifi:-}"
    export CUBEOS_USB_WIFI="${usb_wifi:-}"
    export CUBEOS_DETECTED_ETH="${eth_iface:-}"

    # Write to config file for containers to read
    install -d -o cubeos -g cubeos /cubeos/config
    cat > /cubeos/config/interfaces.env <<IFACES_EOF
# Auto-detected network interfaces (generated by cubeos-boot-lib.sh)
CUBEOS_AP_INTERFACE=${CUBEOS_AP_IFACE}
CUBEOS_WAN_INTERFACE=${CUBEOS_UPLINK_IFACE}
CUBEOS_WIFI_CLIENT_INTERFACE=${CUBEOS_WIFI_CLIENT_IFACE}
HAL_DEFAULT_WIFI_INTERFACE=${CUBEOS_AP_IFACE}
HAL_NAT_INTERFACE=${CUBEOS_UPLINK_IFACE}
CUBEOS_DETECTED_ETH=${CUBEOS_DETECTED_ETH}
CUBEOS_BUILTIN_WIFI=${CUBEOS_BUILTIN_WIFI}
CUBEOS_USB_WIFI=${CUBEOS_USB_WIFI}
IFACES_EOF

    log "Interface roles: AP=${CUBEOS_AP_IFACE} Uplink=${CUBEOS_UPLINK_IFACE} WiFi-Client=${CUBEOS_WIFI_CLIENT_IFACE}"
}

# =============================================================================
# Bluetooth Coexistence — manage BT based on WiFi AP role
# =============================================================================
# Pi's built-in Bluetooth shares SDIO bus with built-in WiFi.
# When built-in WiFi is AP: disable BT (unless override active)
# When built-in WiFi is unused (USB took AP) or client: enable BT
enforce_bluetooth_coexistence() {
    # Skip if no built-in WiFi detected
    if [ -z "${CUBEOS_BUILTIN_WIFI:-}" ]; then
        log "Bluetooth coexistence: no built-in WiFi — skipping"
        return 0
    fi

    # Check if rfkill is available
    if ! command -v rfkill &>/dev/null; then
        log "Bluetooth coexistence: rfkill not found — skipping"
        return 0
    fi

    local bt_override=""
    if [ -f "${CUBEOS_DB_PATH:-/cubeos/data/cubeos.db}" ]; then
        bt_override=$(sqlite3 "${CUBEOS_DB_PATH:-/cubeos/data/cubeos.db}" \
            "SELECT value FROM system_config WHERE key = 'bluetooth_override';" 2>/dev/null || echo "")
    fi

    if [ "${CUBEOS_AP_IFACE:-}" = "${CUBEOS_BUILTIN_WIFI:-}" ]; then
        # Built-in WiFi is AP — should disable Bluetooth
        if [ "$bt_override" = "true" ]; then
            rfkill unblock bluetooth 2>/dev/null || true
            log "Bluetooth coexistence: built-in WiFi is AP but override active — BT ENABLED (warning: may degrade AP perf)"
        else
            rfkill block bluetooth 2>/dev/null || true
            log "Bluetooth coexistence: built-in WiFi is AP — BT DISABLED (SDIO bus protection)"
        fi
    else
        # Built-in WiFi is not AP (USB took AP or no AP) — enable Bluetooth
        rfkill unblock bluetooth 2>/dev/null || true
        log "Bluetooth coexistence: built-in WiFi not AP — BT ENABLED"
    fi
}

# Determine best default mode based on detected hardware.
# T6c-09: Uses raw detection values (CUBEOS_BUILTIN_WIFI, CUBEOS_DETECTED_ETH)
# which are empty when hardware is absent, unlike CUBEOS_AP_IFACE/CUBEOS_ETH_IFACE
# which always have safe fallbacks (wlan0/eth0).
#
# Decision tree:
#   WiFi + Ethernet → wifi_router   (AP + internet via eth)
#   WiFi only       → offline_hotspot (AP, air-gapped)
#   Ethernet only   → eth_client    (no AP, DHCP client)
#   Neither         → offline_hotspot (safe fallback)
determine_default_mode() {
    local has_wifi="${CUBEOS_BUILTIN_WIFI:+yes}"
    local has_eth="${CUBEOS_DETECTED_ETH:+yes}"

    if [ -n "$has_wifi" ] && [ -n "$has_eth" ]; then
        echo "wifi_router"
    elif [ -n "$has_wifi" ] && [ -z "$has_eth" ]; then
        echo "offline_hotspot"
    elif [ -z "$has_wifi" ] && [ -n "$has_eth" ]; then
        echo "eth_client"
    else
        echo "offline_hotspot"
    fi
}

# Write netplan YAML matching the active network mode.
# Each of the 6 modes has a distinct template — no shared fallback.
#
# T02 (Network Modes Batch 1): Split from 3 cases into 5.
# T14 (Network Modes Batch 3): Added static IP variants.
#   Reads globals: NET_USE_STATIC_IP, NET_STATIC_IP, NET_STATIC_NETMASK,
#                  NET_STATIC_GATEWAY, NET_STATIC_DNS1, NET_STATIC_DNS2
#
# Static IP applies to the upstream interface per mode:
#   wifi_router     → eth0,  wifi_bridge → wlan1,
#   eth_client      → eth0,  wifi_client → wlan0,
#   android_tether  → N/A (DHCP from phone, managed outside netplan)
#   offline_hotspot → N/A (no upstream)
write_netplan_for_mode() {
    local mode="$1"
    local wifi_ssid="${2:-}"
    local wifi_password="${3:-}"
    local NETPLAN_FILE="/etc/netplan/01-cubeos.yaml"

    # Helper: convert dotted netmask to CIDR prefix length
    local cidr=24
    case "${NET_STATIC_NETMASK:-255.255.255.0}" in
        255.255.255.0)   cidr=24 ;;
        255.255.255.128) cidr=25 ;;
        255.255.254.0)   cidr=23 ;;
        255.255.252.0)   cidr=22 ;;
        255.255.240.0)   cidr=20 ;;
        255.255.0.0)     cidr=16 ;;
        255.0.0.0)       cidr=8 ;;
        *)               cidr=24 ;;
    esac

    # Helper: build DNS nameservers block for static IP
    # Uses user-specified DNS or falls back to Pi-hole (10.42.24.1) for AP modes
    _static_dns_block() {
        local fallback="$1"
        if [ -n "${NET_STATIC_DNS1:-}" ]; then
            echo "      nameservers:"
            echo "        addresses:"
            echo "          - ${NET_STATIC_DNS1}"
            [ -n "${NET_STATIC_DNS2:-}" ] && echo "          - ${NET_STATIC_DNS2}"
        elif [ -n "$fallback" ]; then
            echo "      nameservers:"
            echo "        addresses:"
            echo "          - ${fallback}"
        else
            echo "      nameservers:"
            echo "        addresses:"
            echo "          - 1.1.1.1"
            echo "          - 8.8.8.8"
        fi
    }

    # Use detected interfaces (set by detect_interfaces, with safe defaults)
    local AP_IF="${CUBEOS_AP_IFACE:-wlan0}"
    local ETH_IF="${CUBEOS_ETH_IFACE:-eth0}"
    local WIFI_CLIENT_IF="${CUBEOS_WIFI_CLIENT_IFACE:-wlan1}"

    case "$mode" in
        offline_hotspot)
            # offline_hotspot: Air-gapped operation. AP interface serves 10.42.24.0/24.
            # Ethernet has no address — B92: dual-IP on the same subnet
            # caused ARP conflicts killing connectivity after setup.
            cat > "$NETPLAN_FILE" <<NETPLAN_OFFLINE
# CubeOS Network — offline_hotspot (air-gapped, AP only)
# Auto-generated by apply_network_mode — do not edit manually.
# ${AP_IF} MUST be under ethernets (NOT wifis) — hostapd manages the radio.
# ${ETH_IF} has no address — B92: prevents ARP conflict with ${AP_IF}.
network:
  version: 2
  renderer: networkd
  ethernets:
    ${ETH_IF}:
      link-local: []
      optional: true
    ${AP_IF}:
      addresses:
        - 10.42.24.1/24
      link-local: []
      optional: true
NETPLAN_OFFLINE
            ;;

        wifi_router)
            # wifi_router: AP mode with internet via Ethernet.
            if [ "${NET_USE_STATIC_IP:-0}" = "1" ] && [ -n "${NET_STATIC_IP:-}" ] && [ -n "${NET_STATIC_GATEWAY:-}" ]; then
                log "wifi_router: using static IP ${NET_STATIC_IP}/${cidr} via ${NET_STATIC_GATEWAY}"
                {
                    echo "# CubeOS Network — wifi_router (AP + NAT via Ethernet, static IP)"
                    echo "# Auto-generated by apply_network_mode — do not edit manually."
                    echo "network:"
                    echo "  version: 2"
                    echo "  renderer: networkd"
                    echo "  ethernets:"
                    echo "    ${ETH_IF}:"
                    echo "      addresses:"
                    echo "        - ${NET_STATIC_IP}/${cidr}"
                    echo "      routes:"
                    echo "        - to: default"
                    echo "          via: ${NET_STATIC_GATEWAY}"
                    _static_dns_block "10.42.24.1"
                    echo "      optional: true"
                    echo "    ${AP_IF}:"
                    echo "      addresses:"
                    echo "        - 10.42.24.1/24"
                    echo "      link-local: []"
                    echo "      optional: true"
                } > "$NETPLAN_FILE"
            else
                cat > "$NETPLAN_FILE" <<NETPLAN_ONLINE_ETH
# CubeOS Network — wifi_router (AP + NAT via Ethernet)
# Auto-generated by apply_network_mode — do not edit manually.
# ${AP_IF} MUST be under ethernets (NOT wifis) — hostapd manages the radio.
network:
  version: 2
  renderer: networkd
  ethernets:
    ${ETH_IF}:
      dhcp4: true
      dhcp-identifier: mac
      optional: true
      dhcp4-overrides:
        use-dns: false
      nameservers:
        addresses:
          - 10.42.24.1
    ${AP_IF}:
      addresses:
        - 10.42.24.1/24
      link-local: []
      optional: true
NETPLAN_ONLINE_ETH
            fi
            ;;

        wifi_bridge)
            # wifi_bridge: AP mode with internet via USB WiFi dongle.
            if [ -z "$wifi_ssid" ]; then
                log_warn "wifi_bridge: no SSID saved — keeping default netplan"
                return 1
            fi
            if [ "${NET_USE_STATIC_IP:-0}" = "1" ] && [ -n "${NET_STATIC_IP:-}" ] && [ -n "${NET_STATIC_GATEWAY:-}" ]; then
                log "wifi_bridge: using static IP ${NET_STATIC_IP}/${cidr} via ${NET_STATIC_GATEWAY}"
                {
                    echo "# CubeOS Network — wifi_bridge (AP + NAT via USB WiFi, static IP)"
                    echo "# Auto-generated by apply_network_mode — do not edit manually."
                    echo "network:"
                    echo "  version: 2"
                    echo "  renderer: networkd"
                    echo "  ethernets:"
                    echo "    ${AP_IF}:"
                    echo "      addresses:"
                    echo "        - 10.42.24.1/24"
                    echo "      link-local: []"
                    echo "      optional: true"
                    echo "  wifis:"
                    echo "    ${WIFI_CLIENT_IF}:"
                    echo "      addresses:"
                    echo "        - ${NET_STATIC_IP}/${cidr}"
                    echo "      routes:"
                    echo "        - to: default"
                    echo "          via: ${NET_STATIC_GATEWAY}"
                    _static_dns_block "10.42.24.1"
                    echo "      optional: true"
                    echo "      access-points:"
                    echo "        \"${wifi_ssid}\":"
                    echo "          password: \"${wifi_password}\""
                } > "$NETPLAN_FILE"
            else
                cat > "$NETPLAN_FILE" <<NETPLAN_ONLINE_WIFI
# CubeOS Network — wifi_bridge (AP + NAT via USB WiFi dongle ${WIFI_CLIENT_IF})
# Auto-generated by apply_network_mode — do not edit manually.
# ${AP_IF} MUST be under ethernets (NOT wifis) — hostapd manages the radio.
# ${WIFI_CLIENT_IF} is the USB WiFi dongle acting as upstream WiFi client.
network:
  version: 2
  renderer: networkd
  ethernets:
    ${AP_IF}:
      addresses:
        - 10.42.24.1/24
      link-local: []
      optional: true
  wifis:
    ${WIFI_CLIENT_IF}:
      dhcp4: true
      optional: true
      dhcp4-overrides:
        use-dns: false
      nameservers:
        addresses:
          - 10.42.24.1
      access-points:
        "${wifi_ssid}":
          password: "${wifi_password}"
NETPLAN_ONLINE_WIFI
            fi
            ;;

        android_tether)
            # android_tether: AP mode with internet via Android USB tethering.
            # The tethering interface (usb0/enx*) has a dynamic name and is
            # managed outside netplan (brought up + DHCP'd at runtime).
            # Netplan only configures the AP interface — same layout as offline_hotspot.
            cat > "$NETPLAN_FILE" <<NETPLAN_TETHER
# CubeOS Network — android_tether (AP + NAT via Android USB tethering)
# Auto-generated by apply_network_mode — do not edit manually.
# ${AP_IF} MUST be under ethernets (NOT wifis) — hostapd manages the radio.
# Android tethering interface (usb0/enx*) managed outside netplan.
network:
  version: 2
  renderer: networkd
  ethernets:
    ${ETH_IF}:
      link-local: []
      optional: true
    ${AP_IF}:
      addresses:
        - 10.42.24.1/24
      link-local: []
      optional: true
NETPLAN_TETHER
            ;;

        eth_client)
            # eth_client: No AP, Ethernet client only.
            if [ "${NET_USE_STATIC_IP:-0}" = "1" ] && [ -n "${NET_STATIC_IP:-}" ] && [ -n "${NET_STATIC_GATEWAY:-}" ]; then
                log "eth_client: using static IP ${NET_STATIC_IP}/${cidr} via ${NET_STATIC_GATEWAY}"
                {
                    echo "# CubeOS Network — eth_client (no AP, Ethernet static IP)"
                    echo "# Auto-generated by apply_network_mode — do not edit manually."
                    echo "network:"
                    echo "  version: 2"
                    echo "  renderer: networkd"
                    echo "  ethernets:"
                    echo "    ${ETH_IF}:"
                    echo "      addresses:"
                    echo "        - ${NET_STATIC_IP}/${cidr}"
                    echo "      routes:"
                    echo "        - to: default"
                    echo "          via: ${NET_STATIC_GATEWAY}"
                    _static_dns_block ""
                    echo "      optional: true"
                } > "$NETPLAN_FILE"
            else
                cat > "$NETPLAN_FILE" <<NETPLAN_SERVER_ETH
# CubeOS Network — eth_client (no AP, Ethernet DHCP only)
# Auto-generated by apply_network_mode — do not edit manually.
network:
  version: 2
  renderer: networkd
  ethernets:
    ${ETH_IF}:
      dhcp4: true
      dhcp-identifier: mac
      optional: true
NETPLAN_SERVER_ETH
            fi
            ;;

        wifi_client)
            # wifi_client: No AP, WiFi client only.
            if [ -z "$wifi_ssid" ]; then
                log_warn "wifi_client: no SSID saved — keeping default netplan"
                return 1
            fi
            if [ "${NET_USE_STATIC_IP:-0}" = "1" ] && [ -n "${NET_STATIC_IP:-}" ] && [ -n "${NET_STATIC_GATEWAY:-}" ]; then
                log "wifi_client: using static IP ${NET_STATIC_IP}/${cidr} via ${NET_STATIC_GATEWAY}"
                {
                    echo "# CubeOS Network — wifi_client (no AP, static IP)"
                    echo "# Auto-generated by apply_network_mode — do not edit manually."
                    echo "network:"
                    echo "  version: 2"
                    echo "  renderer: networkd"
                    echo "  wifis:"
                    echo "    ${AP_IF}:"
                    echo "      addresses:"
                    echo "        - ${NET_STATIC_IP}/${cidr}"
                    echo "      routes:"
                    echo "        - to: default"
                    echo "          via: ${NET_STATIC_GATEWAY}"
                    _static_dns_block ""
                    echo "      optional: true"
                    echo "      access-points:"
                    echo "        \"${wifi_ssid}\":"
                    echo "          password: \"${wifi_password}\""
                } > "$NETPLAN_FILE"
            else
                cat > "$NETPLAN_FILE" <<NETPLAN_SERVER_WIFI
# CubeOS Network — wifi_client (no AP, ${AP_IF} as WiFi client)
# Auto-generated by apply_network_mode — do not edit manually.
network:
  version: 2
  renderer: networkd
  wifis:
    ${AP_IF}:
      dhcp4: true
      optional: true
      access-points:
        "${wifi_ssid}":
          password: "${wifi_password}"
NETPLAN_SERVER_WIFI
            fi
            ;;

        *)
            # Unknown mode — fall back to offline_hotspot for safety
            log_warn "Unknown network mode '${mode}' — falling back to offline_hotspot"
            write_netplan_for_mode "offline_hotspot"
            return $?
            ;;
    esac

    chmod 600 "$NETPLAN_FILE"

    # Generate networkd configs from the YAML (safe — only writes files, no restart).
    # The generated configs take effect on next boot or after networkctl reload.
    netplan generate 2>/dev/null || log_warn "netplan generate failed"
}

# Configure Pi-hole DHCP scope for the active network mode via REST API.
# Called at boot time AFTER Pi-hole container is running but BEFORE the
# CubeOS API is available. Uses Pi-hole v6 REST API with retry, verification,
# and pihole.toml direct-write as a last-resort fallback.
#
# DHCP scope per mode (Section 15.3 of Network Modes Execution Plan):
#   offline_hotspot:  DHCP active on all interfaces (wlan0 + eth0 serve clients)
#   wifi_router:      DHCP active, no-dhcp-interface=eth0 (DHCP only on wlan0)
#   wifi_bridge:      DHCP active, no-dhcp-interface=wlan1 (DHCP only on wlan0)
#   android_tether:   DHCP active on AP only (tether iface excluded, same as wifi_router)
#   eth_client:       DHCP disabled (CubeOS is a client, not serving)
#   wifi_client:      DHCP disabled (CubeOS is a client, not serving)
configure_pihole_dhcp() {
    local mode="${1:-offline_hotspot}"
    local active="false"
    local wildcard="address=/cubeos.cube/10.42.24.1"
    local dnsmasq_json=""

    # Wait for Pi-hole container to be running
    if ! container_running cubeos-pihole; then
        log_warn "Pi-hole not running -- skipping DHCP configuration"
        return 1
    fi

    # Determine DHCP state and dnsmasq_lines for the mode
    case "$mode" in
        offline_hotspot)
            active="true"
            dnsmasq_json="[\"${wildcard}\"]"
            ;;
        wifi_router)
            active="true"
            dnsmasq_json="[\"${wildcard}\",\"no-dhcp-interface=${CUBEOS_ETH_IFACE:-eth0}\"]"
            ;;
        wifi_bridge)
            active="true"
            dnsmasq_json="[\"${wildcard}\",\"no-dhcp-interface=${CUBEOS_WIFI_CLIENT_IFACE:-wlan1}\"]"
            ;;
        android_tether)
            active="true"
            dnsmasq_json="[\"${wildcard}\",\"no-dhcp-interface=${CUBEOS_ETH_IFACE:-eth0}\"]"
            ;;
        eth_client|wifi_client)
            active="false"
            dnsmasq_json="[\"${wildcard}\"]"
            ;;
        *)
            log_warn "Unknown network mode '$mode', defaulting DHCP to false"
            active="false"
            dnsmasq_json="[\"${wildcard}\"]"
            ;;
    esac

    log "Configuring Pi-hole DHCP: active=$active for mode=$mode"

    # Step 1: Wait for Pi-hole FTL API to be ready
    if ! wait_for_pihole_api 30 3; then
        log_warn "Pi-hole FTL API never became ready -- falling back to pihole.toml direct write"
        _pihole_dhcp_fallback_toml "$active"
        return $?
    fi

    # Step 2: Login to Pi-hole API
    local sid
    sid=$(pihole_api_login)
    if [ $? -ne 0 ] || [ -z "$sid" ]; then
        log_warn "Pi-hole API login failed -- falling back to pihole.toml direct write"
        _pihole_dhcp_fallback_toml "$active"
        return $?
    fi

    # Step 3: Set DHCP state with retry (5 attempts, 3s sleep)
    local dhcp_ok=false
    for attempt in 1 2 3 4 5; do
        if pihole_api_set_dhcp "$active" "$sid"; then
            dhcp_ok=true
            break
        fi
        log_warn "DHCP config attempt $attempt/5 failed, retrying in 3s..."
        sleep 3
    done

    if [ "$dhcp_ok" = "false" ]; then
        log_warn "All 5 DHCP config attempts failed -- falling back to pihole.toml direct write"
        _pihole_dhcp_fallback_toml "$active"
        return $?
    fi

    # Step 4: Verify the setting was actually applied
    local actual
    actual=$(pihole_api_get_dhcp "$sid")
    if [ "$actual" != "$active" ]; then
        log_warn "Pi-hole DHCP verification FAILED: expected=$active, actual=$actual -- falling back to pihole.toml"
        _pihole_dhcp_fallback_toml "$active"
        return $?
    fi

    # Step 5: Set dnsmasq_lines (wildcard DNS + per-mode interface exclusion)
    if ! pihole_api_set_dnsmasq_lines "$sid" "$dnsmasq_json"; then
        log_warn "Pi-hole dnsmasq_lines config failed (non-fatal, wildcard DNS may not work)"
    fi

    log_ok "Pi-hole DHCP verified: active=$active, mode=$mode"
}

# Fallback: write DHCP state directly to pihole.toml and restart container.
# Used only when REST API is completely unavailable.
_pihole_dhcp_fallback_toml() {
    local active="$1"
    local toml_path="/cubeos/coreapps/pihole/appdata/etc-pihole/pihole.toml"

    if [ ! -f "$toml_path" ]; then
        log_warn "pihole.toml not found at $toml_path -- cannot apply fallback"
        return 1
    fi

    log_warn "Applying DHCP fallback: writing dhcp.active=$active directly to pihole.toml"

    # Use sed to update the dhcp.active line in the [dhcp] section
    if grep -q "active = " "$toml_path" 2>/dev/null; then
        sed -i "s/^  active = .*/  active = $active/" "$toml_path"
    else
        log_warn "Could not find 'active = ' line in pihole.toml -- manual fix required"
        return 1
    fi

    # Restart Pi-hole container to pick up the change
    log "Restarting Pi-hole container to apply toml changes..."
    docker restart cubeos-pihole 2>/dev/null
    if [ $? -eq 0 ]; then
        log_ok "Pi-hole restarted with DHCP active=$active (via toml fallback)"
        # Wait for it to come back
        sleep 10
        wait_for_pihole_api 20 3 || log_warn "Pi-hole may not have recovered fully after restart"
        return 0
    else
        log_warn "Pi-hole container restart failed -- DHCP may be in wrong state"
        return 1
    fi
}

apply_network_mode() {
    log "Applying network mode..."

    # Detect interfaces if not already done
    if [ -z "${CUBEOS_AP_IFACE:-}" ]; then
        detect_interfaces
    fi

    # Read persisted config (sets NET_MODE, NET_WIFI_SSID, NET_WIFI_PASSWORD,
    #   NET_USE_STATIC_IP, NET_STATIC_IP, NET_STATIC_NETMASK,
    #   NET_STATIC_GATEWAY, NET_STATIC_DNS1, NET_STATIC_DNS2)
    read_persisted_network_config

    # Log static IP if configured
    if [ "${NET_USE_STATIC_IP:-0}" = "1" ] && [ -n "${NET_STATIC_IP:-}" ]; then
        log "Static IP configured: ${NET_STATIC_IP} gw ${NET_STATIC_GATEWAY}"
    fi

    # Write netplan YAML for the active mode (reads NET_USE_STATIC_IP globals).
    # Takes effect fully on next boot; runtime setup below handles the current boot.
    write_netplan_for_mode "$NET_MODE" "$NET_WIFI_SSID" "$NET_WIFI_PASSWORD"

    local AP_IF="${CUBEOS_AP_IFACE:-wlan0}"
    local ETH_IF="${CUBEOS_ETH_IFACE:-eth0}"
    local WIFI_CLIENT_IF="${CUBEOS_WIFI_CLIENT_IFACE:-wlan1}"

    case "$NET_MODE" in
        wifi_router)
            log_ok "Mode: wifi_router -- NAT via ${ETH_IF}"
            networkctl reconfigure "${ETH_IF}" 2>/dev/null || true
            sleep 2
            /usr/local/lib/cubeos/nat-enable.sh "${ETH_IF}" 2>/dev/null || true
            systemctl stop avahi-daemon 2>/dev/null || true
            ;;

        android_tether)
            # Detect the USB tethering interface (usb0 or enx* — dynamic name).
            # HAL isn't running yet at boot, so detect directly from /sys/class/net.
            local TETHER_IF=""
            for candidate in /sys/class/net/usb* /sys/class/net/enx*; do
                [ -e "$candidate" ] || continue
                local iname
                iname=$(basename "$candidate")
                # Verify it's a USB device (not a virtual interface)
                if [ -L "/sys/class/net/${iname}/device/subsystem" ]; then
                    local sub
                    sub=$(readlink -f "/sys/class/net/${iname}/device/subsystem" | xargs basename)
                    if [ "$sub" = "usb" ]; then
                        TETHER_IF="$iname"
                        break
                    fi
                fi
            done

            if [ -n "$TETHER_IF" ]; then
                log_ok "Mode: android_tether -- NAT via ${TETHER_IF}"
                ip link set "$TETHER_IF" up 2>/dev/null || true
                # Request DHCP from the phone (dhclient or networkctl)
                if command -v dhclient &>/dev/null; then
                    dhclient -1 -timeout 15 "$TETHER_IF" 2>/dev/null || true
                else
                    networkctl reconfigure "$TETHER_IF" 2>/dev/null || true
                    sleep 5
                fi
                if ip addr show "$TETHER_IF" 2>/dev/null | grep -q "inet "; then
                    local TETHER_IP
                    TETHER_IP=$(ip -4 addr show "$TETHER_IF" | grep -oP 'inet \K[\d.]+')
                    log_ok "android_tether: ${TETHER_IF} connected ($TETHER_IP)"
                else
                    log_warn "android_tether: ${TETHER_IF} has no IP -- phone may not be tethering"
                fi
                /usr/local/lib/cubeos/nat-enable.sh "$TETHER_IF" 2>/dev/null || true
            else
                log_warn "android_tether: no USB tethering interface found -- NAT not configured"
            fi
            systemctl stop avahi-daemon 2>/dev/null || true
            ;;

        wifi_bridge)
            log_ok "Mode: wifi_bridge -- NAT via ${WIFI_CLIENT_IF}"
            networkctl reload 2>/dev/null || true
            sleep 2
            networkctl reconfigure "${WIFI_CLIENT_IF}" 2>/dev/null || true
            sleep 5
            if ip addr show "${WIFI_CLIENT_IF}" 2>/dev/null | grep -q "inet "; then
                local WLAN1_IP
                WLAN1_IP=$(ip -4 addr show "${WIFI_CLIENT_IF}" | grep -oP 'inet \K[\d.]+')
                log_ok "wifi_bridge: ${WIFI_CLIENT_IF} connected ($WLAN1_IP)"
            else
                log_warn "wifi_bridge: ${WIFI_CLIENT_IF} has no IP -- check WiFi credentials or dongle"
            fi
            /usr/local/lib/cubeos/nat-enable.sh "${WIFI_CLIENT_IF}" 2>/dev/null || true
            systemctl stop avahi-daemon 2>/dev/null || true
            ;;

        eth_client)
            log_ok "Mode: eth_client -- no AP, ${ETH_IF} DHCP"
            systemctl stop hostapd 2>/dev/null || true
            ip addr flush dev "${AP_IF}" 2>/dev/null || true
            /usr/local/lib/cubeos/nat-disable.sh 2>/dev/null || true
            networkctl reconfigure "${ETH_IF}" 2>/dev/null || true
            systemctl start avahi-daemon 2>/dev/null || true
            ;;

        wifi_client)
            log_ok "Mode: wifi_client -- no AP, ${AP_IF} WiFi client"
            systemctl stop hostapd 2>/dev/null || true
            ip addr flush dev "${AP_IF}" 2>/dev/null || true
            /usr/local/lib/cubeos/nat-disable.sh 2>/dev/null || true
            networkctl reload 2>/dev/null || true
            sleep 2
            networkctl reconfigure "${AP_IF}" 2>/dev/null || true

            local WIFI_TIMEOUT=30
            local WIFI_ELAPSED=0
            while [ "$WIFI_ELAPSED" -lt "$WIFI_TIMEOUT" ]; do
                if ip addr show "${AP_IF}" 2>/dev/null | grep -q "inet "; then
                    break
                fi
                sleep 2
                WIFI_ELAPSED=$((WIFI_ELAPSED + 2))
            done

            if ip addr show "${AP_IF}" 2>/dev/null | grep -q "inet "; then
                local WLAN_IP
                WLAN_IP=$(ip -4 addr show "${AP_IF}" | grep -oP 'inet \K[\d.]+')
                log_ok "wifi_client: ${AP_IF} connected ($WLAN_IP)"
                systemctl start avahi-daemon 2>/dev/null || true
            else
                log_warn "wifi_client: connection failed after ${WIFI_TIMEOUT}s -- reverting to offline_hotspot"
                write_netplan_for_mode "offline_hotspot" "" ""
                netplan apply 2>/dev/null || true
                systemctl start hostapd 2>/dev/null || true
                systemctl stop avahi-daemon 2>/dev/null || true
                if [ -f /cubeos/data/cubeos.db ]; then
                    sqlite3 /cubeos/data/cubeos.db "UPDATE network_config SET mode='offline_hotspot' WHERE id=1;" 2>/dev/null || true
                fi
                log_warn "wifi_client: reverted to offline_hotspot"
            fi
            ;;

        offline_hotspot|*)
            log_ok "Mode: offline_hotspot"
            # Ensure NAT is disabled (clean state)
            /usr/local/lib/cubeos/nat-disable.sh 2>/dev/null || true
            systemctl stop avahi-daemon 2>/dev/null || true
            ;;
    esac
}

# ── USB Recovery Detection (bare-metal restore) ──────────────────────
# Scans USB block devices for CubeOS backup archives. If found, copies
# the backup to /cubeos/data/backups/ and writes a pending-restore.json
# marker so the API can auto-trigger a restore workflow on first boot.
#
# Priority 1: cubeos-backup-*.tar.gz → bare-metal restore
# Priority 2: cubeos-config.json     → config import (Phase 6 prep)
#
# Returns 0 if any recovery file was found, 1 otherwise.
check_usb_recovery() {
    local USB_MNT="/cubeos/mnt/usb-restore"
    local BACKUP_DEST="${DATA_DIR}/backups"
    local found=false

    mkdir -p "${USB_MNT}" "${BACKUP_DEST}"

    # Find USB block devices via lsblk
    local usb_parts
    usb_parts=$(lsblk -nrpo NAME,TRAN,FSTYPE 2>/dev/null | awk '$2=="usb" && $3!=""{ print $1 }')

    if [ -z "${usb_parts}" ]; then
        log "USB recovery: no USB partitions detected"
        rmdir "${USB_MNT}" 2>/dev/null || true
        return 1
    fi

    for part in ${usb_parts}; do
        log "USB recovery: checking ${part}..."
        [ -f "${HEARTBEAT:-}" ] && date +%s > "${HEARTBEAT}"

        # Mount read-only
        if ! mount -o ro "${part}" "${USB_MNT}" 2>/dev/null; then
            log_warn "USB recovery: failed to mount ${part}"
            continue
        fi

        # Priority 1: look for backup archives (max depth 2)
        local backup_file
        backup_file=$(find "${USB_MNT}" -maxdepth 2 -name 'cubeos-backup-*.tar.gz' -type f 2>/dev/null | head -n 1)

        if [ -n "${backup_file}" ]; then
            local backup_name
            backup_name=$(basename "${backup_file}")
            log "USB recovery: found backup ${backup_name} on ${part}"

            # Copy to backup directory (update heartbeat during copy)
            [ -f "${HEARTBEAT:-}" ] && date +%s > "${HEARTBEAT}"
            if cp "${backup_file}" "${BACKUP_DEST}/${backup_name}"; then
                log_ok "USB recovery: copied ${backup_name} to ${BACKUP_DEST}/"

                # Write pending-restore marker for the API
                cat > "${DATA_DIR}/pending-restore.json" << RESTORE_EOF
{
  "backup_file": "${BACKUP_DEST}/${backup_name}",
  "source_device": "${part}",
  "detected_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "auto_restore": true
}
RESTORE_EOF
                log_ok "USB recovery: pending-restore.json written"
                found=true
            else
                log_warn "USB recovery: failed to copy ${backup_name}"
            fi

            umount "${USB_MNT}" 2>/dev/null || true
            break
        fi

        # Priority 2: look for config import file (Phase 6 prep)
        local config_file
        config_file=$(find "${USB_MNT}" -maxdepth 2 -name 'cubeos-config.json' -type f 2>/dev/null | head -n 1)

        if [ -n "${config_file}" ]; then
            log "USB recovery: found cubeos-config.json on ${part}"
            if cp "${config_file}" "${DATA_DIR}/pending-import.json"; then
                log_ok "USB recovery: pending-import.json written (Phase 6)"
                found=true
            fi

            umount "${USB_MNT}" 2>/dev/null || true
            break
        fi

        # Nothing found on this device — unmount and try next
        umount "${USB_MNT}" 2>/dev/null || true
    done

    rmdir "${USB_MNT}" 2>/dev/null || true

    if [ "${found}" = true ]; then
        return 0
    else
        log "USB recovery: no recovery files found on USB devices"
        return 1
    fi
}

# Check if current mode is a server mode (no AP).
# Used by normal-boot.sh to skip hostapd start.
is_server_mode() {
    read_persisted_network_config
    case "$NET_MODE" in
        eth_client|wifi_client) return 0 ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# Pre-Configuration Support (v0.2.0-beta.06)
# =============================================================================
# Functions for adopting settings from Pi Imager, Armbian, custom.toml, and LXC.
# Called by first-boot after detect-preconfiguration.sh writes preconfiguration.json.

# Swap cloud-init/Armbian netplan with CubeOS curated netplan.
# Called AFTER detection, BEFORE services start.
# CRITICAL: This causes a brief network reconnection. Must complete before wizard.
apply_preconfigured_network() {
    local preconfig="/cubeos/config/preconfiguration.json"

    if [ ! -f "$preconfig" ]; then
        log "No preconfiguration.json -- skipping network swap"
        return 0
    fi

    local source wifi_ssid wifi_password network_mode_hint
    source=$(jq -r '.source' "$preconfig")
    wifi_ssid=$(jq -r '.wifi.ssid // ""' "$preconfig")
    wifi_password=$(jq -r '.wifi.password // ""' "$preconfig")
    network_mode_hint=$(jq -r '.network_mode_hint // "wifi_router"' "$preconfig")

    if [ "$source" = "none" ]; then
        log "No pre-configuration -- keeping default netplan"
        return 0
    fi

    log "Applying pre-configured network: mode=$network_mode_hint, ssid=$wifi_ssid"

    # Step 1: Delete ALL foreign netplan files (cloud-init, Armbian, etc.)
    # Keep only CubeOS-generated netplan files (contain "CubeOS" marker)
    local cubeos_marker="CubeOS"
    for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
        [ -f "$f" ] || continue
        if ! grep -q "$cubeos_marker" "$f" 2>/dev/null; then
            log "Removing foreign netplan: $f"
            rm -f "$f"
        fi
    done

    # Step 2: Write CubeOS curated netplan for the detected mode
    # Ensure interfaces are detected for write_netplan_for_mode
    if [ -z "${CUBEOS_AP_IFACE:-}" ]; then
        detect_interfaces
    fi

    if [ "$network_mode_hint" = "wifi_client" ] && [ -n "$wifi_ssid" ]; then
        write_netplan_for_mode "wifi_client" "$wifi_ssid" "$wifi_password"
    elif [ "$network_mode_hint" = "eth_client" ]; then
        write_netplan_for_mode "eth_client"
    else
        # Default -- wifi_router (AP mode, same as no-preconfig)
        write_netplan_for_mode "wifi_router"
    fi

    # Step 3: Apply netplan
    log "Applying CubeOS netplan..."
    netplan apply 2>&1 | while IFS= read -r line; do log "  netplan: $line"; done

    # Step 4: Wait for network connectivity to stabilize
    if [ "$network_mode_hint" = "wifi_client" ] || [ "$network_mode_hint" = "eth_client" ]; then
        log "Waiting for network connectivity..."
        local max_wait=60
        local waited=0
        while [ $waited -lt $max_wait ]; do
            if ip -4 addr show scope global 2>/dev/null | grep -q "inet "; then
                local ip
                ip=$(ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[^/]+' | head -1)
                log_ok "Network connected: $ip (waited ${waited}s)"
                return 0
            fi
            sleep 2
            waited=$((waited + 2))
            # Update heartbeat if tracking
            [ -f "${HEARTBEAT:-/dev/null}" ] && date +%s > "$HEARTBEAT"
        done

        # Timeout -- fall back to AP mode
        log_warn "Network connectivity timeout after ${max_wait}s. Falling back to AP mode."

        # Update preconfiguration to note the failure
        local tmp
        tmp=$(mktemp)
        jq '.network_mode_hint = "wifi_router" | .wifi_connect_failed = true' "$preconfig" > "$tmp" && mv "$tmp" "$preconfig"
        chmod 640 "$preconfig"

        write_netplan_for_mode "wifi_router"
        netplan apply 2>&1 | while IFS= read -r line; do log "  netplan: $line"; done
    fi

    return 0
}

# Permanently disable cloud-init after extracting pre-configuration.
# MUST be called after detect-preconfiguration.sh but before reboot.
disable_cloud_init_permanently() {
    local preconfig="/cubeos/config/preconfiguration.json"
    local source
    source=$(jq -r '.source // "none"' "$preconfig" 2>/dev/null || echo "none")

    if [ "$source" != "cloud-init" ]; then
        log "Source is not cloud-init ($source) -- skipping cloud-init disable"
        return 0
    fi

    log "Disabling cloud-init permanently..."

    # Method 1: Create the disable marker file
    touch /etc/cloud/cloud-init.disabled

    # Method 2: Mask the services
    systemctl mask cloud-init.service 2>/dev/null || true
    systemctl mask cloud-init-local.service 2>/dev/null || true
    systemctl mask cloud-config.service 2>/dev/null || true
    systemctl mask cloud-final.service 2>/dev/null || true

    # Method 3: Clean cloud-init state (prevents re-run)
    cloud-init clean --logs 2>/dev/null || true

    # Rename user-data and network-config to prevent confusion
    for f in user-data network-config meta-data; do
        if [ -f "/boot/firmware/$f" ]; then
            mv "/boot/firmware/$f" "/boot/firmware/${f}.cubeos-processed" 2>/dev/null || true
        fi
    done

    log_ok "cloud-init permanently disabled"
}

# Ensure cubeos system user exists and Imager user is in the cubeos group.
# cloud-init creates the Imager user; this adds them to the cubeos group.
setup_users_from_preconfig() {
    local preconfig="/cubeos/config/preconfiguration.json"

    if [ ! -f "$preconfig" ]; then
        return 0
    fi

    local source
    source=$(jq -r '.source // "none"' "$preconfig")
    if [ "$source" = "none" ]; then
        return 0
    fi

    # Get Imager usernames from preconfiguration
    local users
    users=$(jq -r '.users[]?.name // empty' "$preconfig" 2>/dev/null)

    for username in $users; do
        [ -z "$username" ] && continue
        [ "$username" = "cubeos" ] && continue

        # Check if user exists (cloud-init should have created them)
        if id "$username" &>/dev/null; then
            log "Adding Imager user '$username' to cubeos group..."
            usermod -aG cubeos "$username" 2>/dev/null || log_warn "Failed to add $username to cubeos group"
            log_ok "Imager user '$username' added to cubeos group"
        else
            log "Imager user '$username' does not exist yet -- cloud-init may not have run"
        fi
    done
}
