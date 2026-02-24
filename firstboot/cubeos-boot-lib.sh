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
#   - Network mode (5 distinct netplan templates)
#
# v13 — ALPHA.23 (Batch 2):
#   - B82: seed_pihole_dns() rewritten to use pihole-FTL --config dns.hosts
#     (JSON array persisted to pihole.toml). custom.list kept as fallback.
#
# v12 — ALPHA.22 (Network Modes Batch 1):
#   - T02: Split write_netplan_for_mode() from 3 cases into 5 distinct templates
#     - OFFLINE: eth0 no address (B92 fix), wlan0 static AP
#     - ONLINE_ETH: eth0 DHCP client, wlan0 static AP
#     - ONLINE_WIFI: wlan1 WiFi client (upstream), wlan0 static AP, no eth0
#     - SERVER_ETH / SERVER_WIFI: unchanged
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

# ── Pi-hole DNS Seeding ──────────────────────────────────────────────
seed_pihole_dns() {
    # B82: Pi-hole v6 FTL regenerates custom.list from dns.hosts in pihole.toml.
    # Writing custom.list directly is overwritten on FTL restart.
    # Primary: use pihole-FTL --config dns.hosts (JSON array, persists to pihole.toml).
    # Fallback: write custom.list for first-boot race (container may not be ready).

    # Build JSON array: ["10.42.24.1 cubeos.cube","10.42.24.1 api.cubeos.cube",...]
    local json_entries=""
    for host in "${CORE_DNS_HOSTS[@]}"; do
        [ -n "$json_entries" ] && json_entries="${json_entries},"
        json_entries="${json_entries}\"${GATEWAY_IP} ${host}\""
    done

    # Primary: pihole-FTL --config dns.hosts (writes to pihole.toml)
    local ftl_ok=false
    if container_running cubeos-pihole; then
        if docker exec cubeos-pihole pihole-FTL --config dns.hosts "[${json_entries}]" 2>/dev/null; then
            ftl_ok=true
        else
            log_warn "pihole-FTL --config dns.hosts failed -- falling back to custom.list"
        fi
    else
        log_warn "Pi-hole not running -- writing custom.list only (FTL config on next boot)"
    fi

    # Belt-and-suspenders: also write custom.list directly
    local PIHOLE_HOSTS="/cubeos/coreapps/pihole/appdata/etc-pihole/hosts/custom.list"
    mkdir -p "$(dirname "$PIHOLE_HOSTS")"
    : > "$PIHOLE_HOSTS"
    for host in "${CORE_DNS_HOSTS[@]}"; do
        echo "${GATEWAY_IP} ${host}" >> "$PIHOLE_HOSTS"
    done

    if [ "$ftl_ok" = true ]; then
        log_ok "Pi-hole DNS seeded (${#CORE_DNS_HOSTS[@]} entries via dns.hosts + custom.list)"
    else
        # Trigger a reload so custom.list takes effect immediately
        docker exec cubeos-pihole pihole reloaddns 2>/dev/null || true
        log_ok "Pi-hole DNS seeded (${#CORE_DNS_HOSTS[@]} entries via custom.list fallback)"
    fi
}

# ── Network Mode ─────────────────────────────────────────────────────

# Read persisted network config from SQLite.
# Sets global: NET_MODE, NET_WIFI_SSID, NET_WIFI_PASSWORD,
#              NET_USE_STATIC_IP, NET_STATIC_IP, NET_STATIC_NETMASK,
#              NET_STATIC_GATEWAY, NET_STATIC_DNS1, NET_STATIC_DNS2
# Fallback: NET_MODE=offline if db missing or query fails.
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
    NET_MODE="${NET_MODE:-${CUBEOS_NETWORK_MODE:-offline}}"
}

# Write netplan YAML matching the active network mode.
# Each of the 5 modes has a distinct template — no shared fallback.
#
# T02 (Network Modes Batch 1): Split from 3 cases into 5.
# T14 (Network Modes Batch 3): Added static IP variants.
#   Reads globals: NET_USE_STATIC_IP, NET_STATIC_IP, NET_STATIC_NETMASK,
#                  NET_STATIC_GATEWAY, NET_STATIC_DNS1, NET_STATIC_DNS2
#
# Static IP applies to the upstream interface per mode:
#   ONLINE_ETH  → eth0,  ONLINE_WIFI → wlan1,
#   SERVER_ETH  → eth0,  SERVER_WIFI → wlan0,
#   OFFLINE     → N/A (no upstream)
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

    case "$mode" in
        offline)
            # OFFLINE: Air-gapped operation. wlan0 (AP) serves the 10.42.24.0/24
            # subnet. eth0 has no address — B92: dual-IP on the same subnet
            # caused ARP conflicts killing connectivity after setup.
            cat > "$NETPLAN_FILE" << 'NETPLAN_OFFLINE'
# CubeOS Network — OFFLINE (air-gapped, AP only)
# Auto-generated by apply_network_mode — do not edit manually.
# wlan0 MUST be under ethernets (NOT wifis) — hostapd manages the radio.
# eth0 has no address — B92: prevents ARP conflict with wlan0.
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      link-local: []
      optional: true
    wlan0:
      addresses:
        - 10.42.24.1/24
      link-local: []
      optional: true
NETPLAN_OFFLINE
            ;;

        online_eth)
            # ONLINE_ETH: AP mode with internet via Ethernet.
            if [ "${NET_USE_STATIC_IP:-0}" = "1" ] && [ -n "${NET_STATIC_IP:-}" ] && [ -n "${NET_STATIC_GATEWAY:-}" ]; then
                # Static IP on eth0
                log "ONLINE_ETH: using static IP ${NET_STATIC_IP}/${cidr} via ${NET_STATIC_GATEWAY}"
                {
                    echo "# CubeOS Network — ONLINE_ETH (AP + NAT via Ethernet, static IP)"
                    echo "# Auto-generated by apply_network_mode — do not edit manually."
                    echo "network:"
                    echo "  version: 2"
                    echo "  renderer: networkd"
                    echo "  ethernets:"
                    echo "    eth0:"
                    echo "      addresses:"
                    echo "        - ${NET_STATIC_IP}/${cidr}"
                    echo "      routes:"
                    echo "        - to: default"
                    echo "          via: ${NET_STATIC_GATEWAY}"
                    _static_dns_block "10.42.24.1"
                    echo "      optional: true"
                    echo "    wlan0:"
                    echo "      addresses:"
                    echo "        - 10.42.24.1/24"
                    echo "      link-local: []"
                    echo "      optional: true"
                } > "$NETPLAN_FILE"
            else
                # DHCP on eth0 (default)
                cat > "$NETPLAN_FILE" << 'NETPLAN_ONLINE_ETH'
# CubeOS Network — ONLINE_ETH (AP + NAT via Ethernet)
# Auto-generated by apply_network_mode — do not edit manually.
# wlan0 MUST be under ethernets (NOT wifis) — hostapd manages the radio.
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
      dhcp-identifier: mac
      optional: true
      dhcp4-overrides:
        use-dns: false
      nameservers:
        addresses:
          - 10.42.24.1
    wlan0:
      addresses:
        - 10.42.24.1/24
      link-local: []
      optional: true
NETPLAN_ONLINE_ETH
            fi
            ;;

        online_wifi)
            # ONLINE_WIFI: AP mode with internet via USB WiFi dongle (wlan1).
            if [ -z "$wifi_ssid" ]; then
                log_warn "ONLINE_WIFI: no SSID saved — keeping default netplan"
                return 1
            fi
            if [ "${NET_USE_STATIC_IP:-0}" = "1" ] && [ -n "${NET_STATIC_IP:-}" ] && [ -n "${NET_STATIC_GATEWAY:-}" ]; then
                # Static IP on wlan1
                log "ONLINE_WIFI: using static IP ${NET_STATIC_IP}/${cidr} via ${NET_STATIC_GATEWAY}"
                {
                    echo "# CubeOS Network — ONLINE_WIFI (AP + NAT via USB WiFi, static IP)"
                    echo "# Auto-generated by apply_network_mode — do not edit manually."
                    echo "network:"
                    echo "  version: 2"
                    echo "  renderer: networkd"
                    echo "  ethernets:"
                    echo "    wlan0:"
                    echo "      addresses:"
                    echo "        - 10.42.24.1/24"
                    echo "      link-local: []"
                    echo "      optional: true"
                    echo "  wifis:"
                    echo "    wlan1:"
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
                # DHCP on wlan1 (default)
                cat > "$NETPLAN_FILE" << NETPLAN_ONLINE_WIFI
# CubeOS Network — ONLINE_WIFI (AP + NAT via USB WiFi dongle wlan1)
# Auto-generated by apply_network_mode — do not edit manually.
# wlan0 MUST be under ethernets (NOT wifis) — hostapd manages the radio.
# wlan1 is the USB WiFi dongle acting as upstream WiFi client.
network:
  version: 2
  renderer: networkd
  ethernets:
    wlan0:
      addresses:
        - 10.42.24.1/24
      link-local: []
      optional: true
  wifis:
    wlan1:
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

        server_eth)
            # SERVER_ETH: No AP, Ethernet client only.
            if [ "${NET_USE_STATIC_IP:-0}" = "1" ] && [ -n "${NET_STATIC_IP:-}" ] && [ -n "${NET_STATIC_GATEWAY:-}" ]; then
                # Static IP on eth0
                log "SERVER_ETH: using static IP ${NET_STATIC_IP}/${cidr} via ${NET_STATIC_GATEWAY}"
                {
                    echo "# CubeOS Network — SERVER_ETH (no AP, Ethernet static IP)"
                    echo "# Auto-generated by apply_network_mode — do not edit manually."
                    echo "network:"
                    echo "  version: 2"
                    echo "  renderer: networkd"
                    echo "  ethernets:"
                    echo "    eth0:"
                    echo "      addresses:"
                    echo "        - ${NET_STATIC_IP}/${cidr}"
                    echo "      routes:"
                    echo "        - to: default"
                    echo "          via: ${NET_STATIC_GATEWAY}"
                    _static_dns_block ""
                    echo "      optional: true"
                } > "$NETPLAN_FILE"
            else
                # DHCP on eth0 (default)
                cat > "$NETPLAN_FILE" << 'NETPLAN_SERVER_ETH'
# CubeOS Network — SERVER_ETH (no AP, Ethernet DHCP only)
# Auto-generated by apply_network_mode — do not edit manually.
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
      dhcp-identifier: mac
      optional: true
NETPLAN_SERVER_ETH
            fi
            ;;

        server_wifi)
            # SERVER_WIFI: No AP, wlan0 as WiFi client only.
            if [ -z "$wifi_ssid" ]; then
                log_warn "SERVER_WIFI: no SSID saved — keeping default netplan"
                return 1
            fi
            if [ "${NET_USE_STATIC_IP:-0}" = "1" ] && [ -n "${NET_STATIC_IP:-}" ] && [ -n "${NET_STATIC_GATEWAY:-}" ]; then
                # Static IP on wlan0
                log "SERVER_WIFI: using static IP ${NET_STATIC_IP}/${cidr} via ${NET_STATIC_GATEWAY}"
                {
                    echo "# CubeOS Network — SERVER_WIFI (no AP, wlan0 static IP)"
                    echo "# Auto-generated by apply_network_mode — do not edit manually."
                    echo "network:"
                    echo "  version: 2"
                    echo "  renderer: networkd"
                    echo "  wifis:"
                    echo "    wlan0:"
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
                # DHCP on wlan0 (default)
                cat > "$NETPLAN_FILE" << NETPLAN_SERVER_WIFI
# CubeOS Network — SERVER_WIFI (no AP, wlan0 as WiFi client)
# Auto-generated by apply_network_mode — do not edit manually.
network:
  version: 2
  renderer: networkd
  wifis:
    wlan0:
      dhcp4: true
      optional: true
      access-points:
        "${wifi_ssid}":
          password: "${wifi_password}"
NETPLAN_SERVER_WIFI
            fi
            ;;

        *)
            # Unknown mode — fall back to OFFLINE for safety
            log_warn "Unknown network mode '${mode}' — falling back to OFFLINE"
            write_netplan_for_mode "offline"
            return $?
            ;;
    esac

    chmod 600 "$NETPLAN_FILE"

    # Generate networkd configs from the YAML (safe — only writes files, no restart).
    # The generated configs take effect on next boot or after networkctl reload.
    netplan generate 2>/dev/null || log_warn "netplan generate failed"
}

# Configure Pi-hole DHCP scope for the active network mode.
# Called at boot time AFTER Pi-hole container is running but BEFORE the
# CubeOS API is available. Uses pihole-FTL --config CLI (writes to pihole.toml
# inside the container) since the REST API may not be ready yet.
#
# DHCP scope per mode (Section 15.3 of Network Modes Execution Plan):
#   OFFLINE:      DHCP active on all interfaces (wlan0 + eth0 serve clients)
#   ONLINE_ETH:   DHCP active, no-dhcp-interface=eth0 (DHCP only on wlan0)
#   ONLINE_WIFI:  DHCP active, no-dhcp-interface=wlan1 (DHCP only on wlan0)
#   SERVER_ETH:   DHCP disabled (CubeOS is a client, not serving)
#   SERVER_WIFI:  DHCP disabled (CubeOS is a client, not serving)
configure_pihole_dhcp() {
    local mode="${1:-offline}"

    # Wait for Pi-hole container to be running
    if ! container_running cubeos-pihole; then
        log_warn "Pi-hole not running -- skipping DHCP configuration"
        return 1
    fi

    case "$mode" in
        offline)
            docker exec cubeos-pihole pihole-FTL --config dhcp.active true 2>/dev/null || true
            docker exec cubeos-pihole pihole-FTL --config misc.dnsmasq_lines '["address=/cubeos.cube/10.42.24.1"]' 2>/dev/null || true
            log_ok "Pi-hole DHCP: active on all interfaces (OFFLINE)"
            ;;
        online_eth)
            docker exec cubeos-pihole pihole-FTL --config dhcp.active true 2>/dev/null || true
            docker exec cubeos-pihole pihole-FTL --config misc.dnsmasq_lines '["address=/cubeos.cube/10.42.24.1","no-dhcp-interface=eth0"]' 2>/dev/null || true
            log_ok "Pi-hole DHCP: active, no-dhcp-interface=eth0 (ONLINE_ETH)"
            ;;
        online_wifi)
            docker exec cubeos-pihole pihole-FTL --config dhcp.active true 2>/dev/null || true
            docker exec cubeos-pihole pihole-FTL --config misc.dnsmasq_lines '["address=/cubeos.cube/10.42.24.1","no-dhcp-interface=wlan1"]' 2>/dev/null || true
            log_ok "Pi-hole DHCP: active, no-dhcp-interface=wlan1 (ONLINE_WIFI)"
            ;;
        server_eth|server_wifi)
            docker exec cubeos-pihole pihole-FTL --config dhcp.active false 2>/dev/null || true
            docker exec cubeos-pihole pihole-FTL --config misc.dnsmasq_lines '["address=/cubeos.cube/10.42.24.1"]' 2>/dev/null || true
            log_ok "Pi-hole DHCP: disabled (${mode})"
            ;;
    esac
}

apply_network_mode() {
    log "Applying network mode..."

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

    case "$NET_MODE" in
        online_eth)
            log_ok "Mode: ONLINE_ETH -- NAT via eth0"
            # Kick DHCP on eth0 in case networkd didn't acquire a lease
            networkctl reconfigure eth0 2>/dev/null || true
            sleep 2
            /usr/local/lib/cubeos/nat-enable.sh eth0 2>/dev/null || true
            ;;

        online_wifi)
            log_ok "Mode: ONLINE_WIFI -- NAT via wlan1"
            # Reload networkd so it picks up the wlan1 wifis: config and starts
            # wpa_supplicant as a client on the USB dongle.
            networkctl reload 2>/dev/null || true
            sleep 2
            networkctl reconfigure wlan1 2>/dev/null || true
            # Give wpa_supplicant time to associate + DHCP
            sleep 5
            if ip addr show wlan1 2>/dev/null | grep -q "inet "; then
                local WLAN1_IP
                WLAN1_IP=$(ip -4 addr show wlan1 | grep -oP 'inet \K[\d.]+')
                log_ok "ONLINE_WIFI: wlan1 connected ($WLAN1_IP)"
            else
                log_warn "ONLINE_WIFI: wlan1 has no IP -- check WiFi credentials or dongle"
            fi
            /usr/local/lib/cubeos/nat-enable.sh wlan1 2>/dev/null || true
            ;;

        server_eth)
            log_ok "Mode: SERVER_ETH -- no AP, eth0 DHCP"
            # Stop hostapd if it was started (normal-boot may have started it
            # before we got here on first boot after mode change)
            systemctl stop hostapd 2>/dev/null || true
            # Remove AP static IP from wlan0 (netplan already updated, but
            # the old config may still be active for this boot)
            ip addr flush dev wlan0 2>/dev/null || true
            # Disable NAT (we're a plain client)
            /usr/local/lib/cubeos/nat-disable.sh 2>/dev/null || true
            # Ensure eth0 has DHCP
            networkctl reconfigure eth0 2>/dev/null || true
            ;;

        server_wifi)
            log_ok "Mode: SERVER_WIFI -- no AP, wlan0 WiFi client"
            # Stop hostapd to free wlan0 for client use
            systemctl stop hostapd 2>/dev/null || true
            ip addr flush dev wlan0 2>/dev/null || true
            /usr/local/lib/cubeos/nat-disable.sh 2>/dev/null || true
            # The netplan YAML with wifis: section was already written above.
            # Reload networkd so it picks up the new wlan0 config and starts
            # wpa_supplicant as a client (connects to saved SSID).
            networkctl reload 2>/dev/null || true
            sleep 2
            networkctl reconfigure wlan0 2>/dev/null || true
            # Give wpa_supplicant time to associate + DHCP
            sleep 5
            if ip addr show wlan0 2>/dev/null | grep -q "inet "; then
                local WLAN_IP
                WLAN_IP=$(ip -4 addr show wlan0 | grep -oP 'inet \K[\d.]+')
                log_ok "SERVER_WIFI: wlan0 connected ($WLAN_IP)"
            else
                log_warn "SERVER_WIFI: wlan0 has no IP -- check WiFi credentials"
            fi
            ;;

        offline|*)
            log_ok "Mode: OFFLINE"
            # Ensure NAT is disabled (clean state)
            /usr/local/lib/cubeos/nat-disable.sh 2>/dev/null || true
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
        server_eth|server_wifi) return 0 ;;
        *) return 1 ;;
    esac
}
