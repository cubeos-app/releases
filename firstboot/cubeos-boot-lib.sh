#!/bin/bash
# =============================================================================
# cubeos-boot-lib.sh — CubeOS Boot Shared Library (v11 - Alpha.18)
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

# ── NPM Proxy Rules (Single Source of Truth — 10 rules) ──────────────
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
    "terminal.cubeos.cube:6042"
    "kiwix.cubeos.cube:6043"
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
    "kiwix.cubeos.cube"
)

# ── Swarm Stacks ─────────────────────────────────────────────────────
# B08: Split into pre-API and post-API stacks.
# Dashboard deploys AFTER API health check to prevent 502/wizard flash.
# Kiwix is optional/non-critical — deploys after core stacks.
SWARM_STACKS_PRE_API="cubeos-api registry cubeos-docsindex dozzle"
SWARM_STACKS_POST_API="cubeos-dashboard kiwix"
# Combined list for recovery/normal boot where ordering is less critical
SWARM_STACKS="registry cubeos-api cubeos-docsindex dozzle cubeos-dashboard kiwix"

# ── Compose Services ─────────────────────────────────────────────────
COMPOSE_SERVICES="pihole npm cubeos-hal terminal"

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

# Read persisted network config from SQLite.
# Sets global: NET_MODE, NET_WIFI_SSID, NET_WIFI_PASSWORD
# Fallback: NET_MODE=offline if db missing or query fails.
read_persisted_network_config() {
    NET_MODE=""
    NET_WIFI_SSID=""
    NET_WIFI_PASSWORD=""
    local DB_PATH="${DATA_DIR}/cubeos.db"
    if [ -f "$DB_PATH" ]; then
        eval "$(python3 -c "
import sqlite3
try:
    conn = sqlite3.connect('${DB_PATH}')
    row = conn.execute('SELECT mode, wifi_ssid, wifi_password FROM network_config WHERE id = 1').fetchone()
    if row:
        print(f'NET_MODE={row[0]}')
        # Shell-escape single quotes in SSID/password
        ssid = (row[1] or '').replace(\"'\", \"'\\\"'\\\"'\")
        pw = (row[2] or '').replace(\"'\", \"'\\\"'\\\"'\")
        print(f\"NET_WIFI_SSID='{ssid}'\")
        print(f\"NET_WIFI_PASSWORD='{pw}'\")
    conn.close()
except: pass
" 2>/dev/null)" || true
    fi
    NET_MODE="${NET_MODE:-${CUBEOS_NETWORK_MODE:-offline}}"
}

# Write netplan YAML matching the active network mode.
# AP modes (offline/online_eth/online_wifi): wlan0 under ethernets with static AP IP.
# Server modes: no wlan0 AP (server_eth) or wlan0 as WiFi client (server_wifi).
write_netplan_for_mode() {
    local mode="$1"
    local wifi_ssid="${2:-}"
    local wifi_password="${3:-}"
    local NETPLAN_FILE="/etc/netplan/01-cubeos.yaml"

    case "$mode" in
        server_eth)
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
            ;;

        server_wifi)
            if [ -z "$wifi_ssid" ]; then
                log_warn "SERVER_WIFI: no SSID saved — keeping default netplan"
                return 1
            fi
            # Netplan wifis: section makes networkd + wpa_supplicant manage wlan0 as client.
            # This is intentionally different from AP modes where wlan0 is under ethernets.
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
            ;;

        *)
            # AP-based modes: offline, online_eth, online_wifi
            # wlan0 under ethernets with static AP IP — hostapd manages the radio.
            cat > "$NETPLAN_FILE" << 'NETPLAN_AP'
# CubeOS Network — AP mode (wlan0=AP, eth0=DHCP upstream)
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
NETPLAN_AP
            ;;
    esac

    chmod 600 "$NETPLAN_FILE"

    # Generate networkd configs from the YAML (safe — only writes files, no restart).
    # The generated configs take effect on next boot or after networkctl reload.
    netplan generate 2>/dev/null || log_warn "netplan generate failed"
}

apply_network_mode() {
    log "Applying network mode..."

    # Read persisted config (sets NET_MODE, NET_WIFI_SSID, NET_WIFI_PASSWORD)
    read_persisted_network_config

    # Write netplan YAML for the active mode (takes effect fully on next boot;
    # runtime setup below handles the current boot).
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

# Check if current mode is a server mode (no AP).
# Used by normal-boot.sh to skip hostapd start.
is_server_mode() {
    read_persisted_network_config
    case "$NET_MODE" in
        server_eth|server_wifi) return 0 ;;
        *) return 1 ;;
    esac
}
