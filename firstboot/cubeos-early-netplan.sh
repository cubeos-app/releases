#!/bin/bash
# =============================================================================
# cubeos-early-netplan.sh — Write correct netplan BEFORE systemd-networkd starts
# =============================================================================
# B89: systemd-networkd starts ~80s before cubeos-init.service and reads the
# previous boot's netplan. If the user switched modes (e.g. ONLINE_ETH → OFFLINE),
# networkd may still use the old netplan (eth0 with DHCP), causing an internet
# leak in OFFLINE mode.
#
# This script runs as cubeos-early-netplan.service:
#   Before=systemd-networkd.service
#   After=local-fs.target
#
# It reads the persisted network mode from SQLite and writes the correct
# netplan YAML so networkd gets the right config on startup.
#
# Safety: If the DB doesn't exist (fresh install), exits silently — the
# baked-in OFFLINE netplan is already correct.
# =============================================================================

LOGFILE="/var/log/cubeos-early-netplan.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE" 2>/dev/null; }

DB_PATH="/cubeos/data/cubeos.db"
BOOT_LIB="/usr/local/bin/cubeos-boot-lib.sh"

# ── Guard: no DB = fresh install → baked-in OFFLINE netplan is correct ──
if [ ! -f "$DB_PATH" ]; then
    log "No database ($DB_PATH) — fresh install, using baked-in OFFLINE netplan"
    exit 0
fi

# ── Guard: sqlite3 must be available ──
if ! command -v sqlite3 &>/dev/null; then
    log "WARN: sqlite3 not found — cannot read network config, using existing netplan"
    exit 0
fi

# ── Read network mode from DB using sqlite3 CLI ──
# Returns "mode|wifi_ssid|wifi_password|use_static_ip|static_ip|netmask|gateway|dns1|dns2"
DB_ROW=$(sqlite3 "$DB_PATH" \
    "SELECT mode, wifi_ssid, wifi_password, use_static_ip, static_ip_address, static_ip_netmask, static_ip_gateway, static_dns_primary, static_dns_secondary FROM network_config WHERE id = 1;" \
    2>/dev/null) || true

if [ -z "$DB_ROW" ]; then
    log "No network_config row in DB — using existing netplan"
    exit 0
fi

# Parse pipe-separated fields
IFS='|' read -r NET_MODE NET_WIFI_SSID NET_WIFI_PASSWORD \
    NET_USE_STATIC_IP_RAW NET_STATIC_IP NET_STATIC_NETMASK \
    NET_STATIC_GATEWAY NET_STATIC_DNS1 NET_STATIC_DNS2 <<< "$DB_ROW"

# Normalize: empty/null → defaults
NET_MODE="${NET_MODE:-offline}"
NET_USE_STATIC_IP=$([ "${NET_USE_STATIC_IP_RAW:-0}" = "1" ] && echo "1" || echo "0")
NET_STATIC_NETMASK="${NET_STATIC_NETMASK:-255.255.255.0}"

export NET_MODE NET_WIFI_SSID NET_WIFI_PASSWORD
export NET_USE_STATIC_IP NET_STATIC_IP NET_STATIC_NETMASK
export NET_STATIC_GATEWAY NET_STATIC_DNS1 NET_STATIC_DNS2

log "DB mode=$NET_MODE static_ip=$NET_USE_STATIC_IP"

# ── Check if netplan already matches ──
# Quick heuristic: if mode is offline and netplan doesn't have dhcp4, skip rewrite
NETPLAN_FILE="/etc/netplan/01-cubeos.yaml"
if [ "$NET_MODE" = "offline" ] && [ -f "$NETPLAN_FILE" ]; then
    if ! grep -q "dhcp4:" "$NETPLAN_FILE" 2>/dev/null; then
        log "Netplan already matches OFFLINE (no dhcp4 present) — no rewrite needed"
        exit 0
    fi
fi

# ── Source boot-lib for write_netplan_for_mode() ──
# boot-lib only defines functions and constants — no auto-execution.
# Override LOG_FILE so any log calls from boot-lib go to our logfile.
LOG_FILE="$LOGFILE"
if [ -f "$BOOT_LIB" ]; then
    source "$BOOT_LIB"
else
    log "WARN: $BOOT_LIB not found — cannot write netplan"
    exit 0
fi

# ── Write the correct netplan ──
log "Writing netplan for mode=$NET_MODE"
write_netplan_for_mode "$NET_MODE" "$NET_WIFI_SSID" "$NET_WIFI_PASSWORD"
log "Netplan written successfully for mode=$NET_MODE"

exit 0
