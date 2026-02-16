#!/bin/bash
# =============================================================================
# cubeos-boot-lib.sh — CubeOS Boot Shared Library (v10 - Alpha.14)
# =============================================================================
# Sourced by both cubeos-first-boot.sh and cubeos-normal-boot.sh.
# Contains all shared functions, constants, and configuration arrays.
#
# SINGLE SOURCE OF TRUTH for:
#   - NPM proxy rules (9 rules)
#   - Pi-hole custom DNS entries (9 entries)
#   - Log formatting (ASCII markers)
#   - Common helpers (wait_for, container_running, etc.)
#   - WiFi AP configuration
#   - Watchdog management
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
CONFIG_DIR="/cubeos/config"
COREAPPS_DIR="/cubeos/coreapps"
DATA_DIR="/cubeos/data"
CACHE_DIR="/var/cache/cubeos-images"
SETUP_FLAG="/cubeos/data/.setup_complete"
LOG_FILE="${LOG_FILE:-/var/log/cubeos-boot.log}"

# ── NPM Proxy Rules (Single Source of Truth — 9 rules) ──────────────
# Format: "domain:port"
# Used by: first-boot NPM seeding, API NPM bootstrap, boot verification
CORE_PROXY_RULES=(
    "cubeos.cube:6011"
    "api.cubeos.cube:6010"
    "docs.cubeos.cube:6032"
    "pihole.cubeos.cube:6001"
    "npm.cubeos.cube:81"
    "registry.cubeos.cube:5000"
    "hal.cubeos.cube:6005"
    "dozzle.cubeos.cube:6012"
    "terminal.cubeos.cube:6009"
)

# ── Pi-hole Custom DNS Entries (Single Source of Truth) ──────────────
# All *.cubeos.cube subdomains that Pi-hole should resolve to gateway
CORE_DNS_HOSTS=(
    "cubeos.cube"
    "api.cubeos.cube"
    "npm.cubeos.cube"
    "pihole.cubeos.cube"
    "hal.cubeos.cube"
    "dozzle.cubeos.cube"
    "registry.cubeos.cube"
    "docs.cubeos.cube"
    "terminal.cubeos.cube"
)

# ── Swarm Stacks ─────────────────────────────────────────────────────
SWARM_STACKS="cubeos-api cubeos-dashboard registry cubeos-docsindex"

# ── Compose Services ─────────────────────────────────────────────────
COMPOSE_SERVICES="pihole npm cubeos-hal"

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
        docker network create --driver overlay --attachable \
            --subnet "$OVERLAY_SUBNET" "$NETWORK_NAME" 2>/dev/null || true
        sleep 5
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
    local COUNTRY_CODE="${CUBEOS_COUNTRY_CODE:-US}"
    log "Setting regulatory domain: $COUNTRY_CODE"
    iw reg set "$COUNTRY_CODE" 2>/dev/null || true
    sleep 2  # Give kernel time to apply regulatory domain

    if systemctl start hostapd 2>/dev/null; then
        sleep 3
        # Read live SSID from hostapd.conf (wizard may have changed it)
        local LIVE_SSID
        LIVE_SSID=$(grep '^ssid=' /etc/hostapd/hostapd.conf 2>/dev/null | cut -d= -f2)
        local DISPLAY_SSID="${LIVE_SSID:-${CUBEOS_AP_SSID:-CubeOS-Setup}}"
        if iw dev wlan0 info 2>/dev/null | grep -q "type AP"; then
            log_ok "WiFi AP broadcasting: ${DISPLAY_SSID} (country: $COUNTRY_CODE)"
            return 0
        else
            log_warn "WiFi AP not broadcasting -- restarting hostapd..."
            iw reg set "$COUNTRY_CODE" 2>/dev/null || true
            sleep 1
            systemctl restart hostapd 2>/dev/null || true
            sleep 2
            if iw dev wlan0 info 2>/dev/null | grep -q "type AP"; then
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

# ── Overlay Network Verify ───────────────────────────────────────────
ensure_overlay_network() {
    # Check if network exists with wrong scope
    local NETWORK_SCOPE
    NETWORK_SCOPE=$(docker network inspect "$NETWORK_NAME" --format '{{.Scope}}' 2>/dev/null || echo "none")
    if [ "$NETWORK_SCOPE" = "local" ]; then
        log "Removing local ${NETWORK_NAME} (wrong scope)..."
        docker network rm "$NETWORK_NAME" 2>/dev/null || true
        NETWORK_SCOPE="none"
    fi
    if [ "$NETWORK_SCOPE" = "none" ]; then
        docker network create \
            --driver overlay --attachable \
            --subnet "$OVERLAY_SUBNET" \
            "$NETWORK_NAME" 2>/dev/null || true
    fi

    # Verify overlay network is ready (swarm scope)
    for i in $(seq 1 30); do
        if docker network inspect "$NETWORK_NAME" --format '{{.Scope}}' 2>/dev/null | grep -q swarm; then
            log_ok "${NETWORK_NAME} overlay verified (${i}s)"
            return 0
        fi
        sleep 1
    done
    log_warn "${NETWORK_NAME} overlay not verified after 30s -- stacks may fail"
    return 1
}

# ── Pi-hole DNS Seeding ──────────────────────────────────────────────
seed_pihole_dns() {
    local PIHOLE_HOSTS="/cubeos/coreapps/pihole/appdata/etc-pihole/hosts/custom.list"
    mkdir -p "$(dirname "$PIHOLE_HOSTS")"
    : > "$PIHOLE_HOSTS"
    for host in "${CORE_DNS_HOSTS[@]}"; do
        echo "${GATEWAY_IP} ${host}" >> "$PIHOLE_HOSTS"
    done
    docker exec cubeos-pihole pihole reloaddns 2>/dev/null || true
    log_ok "Pi-hole DNS seeded (${#CORE_DNS_HOSTS[@]} entries)"
}

# ── Network Mode ─────────────────────────────────────────────────────
apply_network_mode() {
    log "Applying network mode..."
    case "${CUBEOS_NETWORK_MODE:-OFFLINE}" in
        ONLINE_ETH)
            log_ok "Mode: ONLINE_ETH -- NAT via eth0"
            /usr/local/lib/cubeos/nat-enable.sh eth0 2>/dev/null || true
            ;;
        ONLINE_WIFI)
            log_ok "Mode: ONLINE_WIFI -- NAT via wlan1"
            /usr/local/lib/cubeos/nat-enable.sh wlan1 2>/dev/null || true
            ;;
        OFFLINE|*)
            log_ok "Mode: OFFLINE"
            ;;
    esac
}
