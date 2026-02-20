#!/bin/bash
# =============================================================================
# cubeos-console.sh — CubeOS System Console (whiptail TUI)
# =============================================================================
# Emergency recovery and network management console accessible via HDMI+keyboard
# on tty1. Auto-launched after login on tty1; SSH sessions are NOT affected.
#
# Tasks: T21 (main TUI), T23 (SQLite helpers), T24 (apply_network_mode integration)
# Batch: Network Modes Batch 5
#
# Alpha.23 Batch 5:
#   B90: Removed set -euo pipefail, added explicit error handling + trap.
#        Replaced python3 SQLite with sqlite3 CLI (removes python3 dependency).
#   B91: Changed LOG_FILE from /dev/null to /var/log/cubeos-console.log.
#        Added console_log() with timestamps. Added log rotation (1MB max).
#
# Features:
#   1. Switch between all 5 network modes with WiFi/static IP prompts
#   2. Configure static IP for the current mode's upstream interface
#   3. Update WiFi credentials (SSID + password)
#   4. View system status (network, Docker, resources)
#   5. Emergency reset to OFFLINE mode (safe default)
#   6. Clean reboot
#
# Dependencies: whiptail (pre-installed on Ubuntu), sqlite3 CLI
# Sources cubeos-boot-lib.sh for apply_network_mode() and shared constants.
# =============================================================================

# B90: Only set -u (catch unset variables). Do NOT use -e (whiptail returns
# non-zero on Cancel/Escape) or -o pipefail (causes spurious failures in
# subshells gathering system info).
set -u

# ── Constants ────────────────────────────────────────────────────────────────
readonly DB_PATH="/cubeos/data/cubeos.db"
readonly BOOT_LIB="/usr/local/bin/cubeos-boot-lib.sh"
readonly TITLE="CubeOS System Console"
readonly WT_WIDTH=72
readonly WT_HEIGHT=20
readonly WT_LIST_HEIGHT=10
readonly CONSOLE_LOG="/var/log/cubeos-console.log"
readonly CONSOLE_LOG_MAX_BYTES=1048576  # 1MB

# ── B91: Console Logging ────────────────────────────────────────────────────

# Rotate log if over 1MB — truncate to last 500 lines.
rotate_console_log() {
    if [ -f "$CONSOLE_LOG" ]; then
        local size
        size=$(stat -c%s "$CONSOLE_LOG" 2>/dev/null || echo 0)
        if [ "$size" -gt "$CONSOLE_LOG_MAX_BYTES" ]; then
            local tmp
            tmp=$(tail -500 "$CONSOLE_LOG")
            echo "$tmp" > "$CONSOLE_LOG"
            echo "$(date '+%Y-%m-%d %H:%M:%S') LOG_ROTATED: truncated to last 500 lines" >> "$CONSOLE_LOG"
        fi
    fi
}

# Log a timestamped message to the console log file.
console_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') CONSOLE: $*" >> "$CONSOLE_LOG" 2>/dev/null || true
}

# Log an error to the console log file.
console_log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') CONSOLE ERROR: $*" >> "$CONSOLE_LOG" 2>/dev/null || true
}

# Initialize logging — rotate if needed, write session start marker.
rotate_console_log
console_log "Session started (PID=$$, TTY=$(tty 2>/dev/null || echo unknown))"

# ── Source boot-lib for apply_network_mode() and helpers ─────────────────────
if [ -f "$BOOT_LIB" ]; then
    # B91: Direct boot-lib log output to the console log file (not /dev/null).
    # boot-lib's log() writes to LOG_FILE and stderr.
    export LOG_FILE="$CONSOLE_LOG"
    # shellcheck source=/usr/local/bin/cubeos-boot-lib.sh
    source "$BOOT_LIB"
else
    echo "ERROR: Boot library not found at $BOOT_LIB"
    echo "CubeOS may not be properly installed."
    exit 1
fi

# ── B90: Unexpected Exit Trap ───────────────────────────────────────────────
# If the script exits unexpectedly (signal, unset variable with set -u),
# show an error dialog so the user isn't left staring at a blank screen.
# Normal exits (menu "Exit to Shell", reboot) set CLEAN_EXIT=1 first.

CLEAN_EXIT=0

cleanup_trap() {
    local exit_code=$?
    if [ "$CLEAN_EXIT" -eq 0 ] && [ "$exit_code" -ne 0 ]; then
        console_log_error "Unexpected exit (code=$exit_code)"
        # Try to show error dialog — may fail if whiptail is the problem
        whiptail --title "CubeOS Console — Error" --msgbox \
            "The console exited unexpectedly (code: ${exit_code}).\n\nCheck ${CONSOLE_LOG} for details.\n\nType 'sudo cubeos-console' to restart." \
            12 "$WT_WIDTH" 2>/dev/null || true
    fi
    console_log "Session ended (exit_code=$exit_code, clean=$CLEAN_EXIT)"
}

trap cleanup_trap EXIT

# ── SQLite Helpers (T23 — B90 rewrite: sqlite3 CLI) ────────────────────────
# Read/write to SQLite using the sqlite3 CLI (no python3 dependency).
# These functions provide safe access to the network_config table.

# Read current network configuration from SQLite.
# Sets globals: CON_MODE, CON_SSID, CON_PASSWORD, CON_USE_STATIC,
#   CON_STATIC_IP, CON_STATIC_NETMASK, CON_STATIC_GATEWAY, CON_STATIC_DNS1, CON_STATIC_DNS2
db_read_network_config() {
    CON_MODE=""
    CON_SSID=""
    CON_PASSWORD=""
    CON_USE_STATIC="0"
    CON_STATIC_IP=""
    CON_STATIC_NETMASK="255.255.255.0"
    CON_STATIC_GATEWAY=""
    CON_STATIC_DNS1=""
    CON_STATIC_DNS2=""

    if [ ! -f "$DB_PATH" ]; then
        CON_MODE="offline"
        return 0
    fi

    # B90: Use sqlite3 CLI with | separator. Each field on one line.
    local db_output
    db_output=$(sqlite3 -separator '|' "$DB_PATH" \
        "SELECT mode, wifi_ssid, wifi_password, use_static_ip, static_ip_address, static_ip_netmask, static_ip_gateway, static_dns_primary, static_dns_secondary FROM network_config WHERE id = 1;" 2>/dev/null) || {
        console_log_error "db_read_network_config: sqlite3 query failed"
        CON_MODE="offline"
        return 0
    }

    if [ -z "$db_output" ]; then
        CON_MODE="offline"
        return 0
    fi

    # Parse pipe-separated fields using IFS
    local IFS='|'
    # shellcheck disable=SC2086
    set -- $db_output
    CON_MODE="${1:-offline}"
    CON_SSID="${2:-}"
    CON_PASSWORD="${3:-}"
    CON_USE_STATIC="${4:-0}"
    CON_STATIC_IP="${5:-}"
    CON_STATIC_NETMASK="${6:-255.255.255.0}"
    CON_STATIC_GATEWAY="${7:-}"
    CON_STATIC_DNS1="${8:-}"
    CON_STATIC_DNS2="${9:-}"

    # Normalize use_static_ip (SQLite may return 0/1 or true/false)
    case "$CON_USE_STATIC" in
        1|true|TRUE) CON_USE_STATIC="1" ;;
        *) CON_USE_STATIC="0" ;;
    esac

    CON_MODE="${CON_MODE:-offline}"
}

# Write network mode + WiFi credentials to SQLite.
# Args: $1=mode, $2=ssid (optional), $3=password (optional)
db_write_mode() {
    local mode="$1"
    local ssid="${2:-}"
    local password="${3:-}"

    if [ ! -f "$DB_PATH" ]; then
        console_log_error "db_write_mode: database not found"
        return 1
    fi

    # B90: Use sqlite3 CLI with parameterized-style escaping.
    # Single quotes in values are escaped by doubling them (SQL standard).
    local esc_ssid="${ssid//\'/\'\'}"
    local esc_password="${password//\'/\'\'}"

    sqlite3 "$DB_PATH" \
        "UPDATE network_config SET mode = '${mode}', wifi_ssid = '${esc_ssid}', wifi_password = '${esc_password}' WHERE id = 1;" 2>/dev/null || {
        console_log_error "db_write_mode: sqlite3 update failed (mode=${mode})"
        return 1
    }
    console_log "db_write_mode: mode=${mode}, ssid=${ssid:+(set)}"
}

# Write static IP configuration to SQLite.
# Args: $1=use_static(0|1), $2=ip, $3=netmask, $4=gateway, $5=dns1, $6=dns2
db_write_static_ip() {
    local use_static="$1"
    local ip="${2:-}"
    local netmask="${3:-255.255.255.0}"
    local gateway="${4:-}"
    local dns1="${5:-}"
    local dns2="${6:-}"

    if [ ! -f "$DB_PATH" ]; then
        console_log_error "db_write_static_ip: database not found"
        return 1
    fi

    sqlite3 "$DB_PATH" \
        "UPDATE network_config SET use_static_ip = ${use_static}, static_ip_address = '${ip}', static_ip_netmask = '${netmask}', static_ip_gateway = '${gateway}', static_dns_primary = '${dns1}', static_dns_secondary = '${dns2}' WHERE id = 1;" 2>/dev/null || {
        console_log_error "db_write_static_ip: sqlite3 update failed"
        return 1
    }
    console_log "db_write_static_ip: use_static=${use_static}, ip=${ip}"
}

# Write WiFi credentials only (no mode change).
# Args: $1=ssid, $2=password
db_write_wifi_creds() {
    local ssid="$1"
    local password="$2"

    if [ ! -f "$DB_PATH" ]; then
        console_log_error "db_write_wifi_creds: database not found"
        return 1
    fi

    local esc_ssid="${ssid//\'/\'\'}"
    local esc_password="${password//\'/\'\'}"

    sqlite3 "$DB_PATH" \
        "UPDATE network_config SET wifi_ssid = '${esc_ssid}', wifi_password = '${esc_password}' WHERE id = 1;" 2>/dev/null || {
        console_log_error "db_write_wifi_creds: sqlite3 update failed"
        return 1
    }
    console_log "db_write_wifi_creds: ssid=${ssid}"
}

# Clear static IP overrides (reset to DHCP).
db_clear_static_ip() {
    if [ ! -f "$DB_PATH" ]; then
        console_log_error "db_clear_static_ip: database not found"
        return 1
    fi

    sqlite3 "$DB_PATH" \
        "UPDATE network_config SET use_static_ip = 0, static_ip_address = '', static_ip_netmask = '255.255.255.0', static_ip_gateway = '', static_dns_primary = '', static_dns_secondary = '' WHERE id = 1;" 2>/dev/null || {
        console_log_error "db_clear_static_ip: sqlite3 update failed"
        return 1
    }
    console_log "db_clear_static_ip: reset to DHCP"
}


# ── Validation Helpers ───────────────────────────────────────────────────────

# Validate an IPv4 address (0-255 per octet, 4 octets).
# Returns 0 if valid, 1 if invalid.
validate_ipv4() {
    local ip="$1"
    if echo "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        local IFS='.'
        # shellcheck disable=SC2086
        set -- $ip
        [ "$1" -le 255 ] && [ "$2" -le 255 ] && [ "$3" -le 255 ] && [ "$4" -le 255 ]
        return $?
    fi
    return 1
}

# ── Display Helpers ──────────────────────────────────────────────────────────

# Human-readable mode name
mode_label() {
    case "$1" in
        offline)      echo "Offline (AP Only)" ;;
        online_eth)   echo "Online via Ethernet" ;;
        online_wifi)  echo "Online via WiFi" ;;
        server_eth)   echo "Server via Ethernet" ;;
        server_wifi)  echo "Server via WiFi" ;;
        *)            echo "$1" ;;
    esac
}

# Get the upstream interface for a given mode
mode_interface() {
    case "$1" in
        online_eth|server_eth) echo "eth0" ;;
        online_wifi)           echo "wlan1" ;;
        server_wifi)           echo "wlan0" ;;
        offline)               echo "none" ;;
        *)                     echo "unknown" ;;
    esac
}

# Get current IP on an interface
get_interface_ip() {
    local iface="$1"
    ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1
}

# ── Apply Changes (T24) ─────────────────────────────────────────────────────
# After writing to SQLite, call the same boot-lib functions used at boot time
# to apply netplan + hostapd + NAT changes.

apply_changes() {
    local mode="$1"

    console_log "apply_changes: starting mode=${mode}"

    # Show a progress message while applying (whiptail gauge)
    {
        echo 10
        # apply_network_mode reads from DB and writes netplan + applies
        if ! apply_network_mode 2>>"$CONSOLE_LOG"; then
            console_log_error "apply_changes: apply_network_mode failed"
        fi
        echo 50
        # Configure Pi-hole DHCP scope for the new mode
        if ! configure_pihole_dhcp "$mode" 2>>"$CONSOLE_LOG"; then
            console_log_error "apply_changes: configure_pihole_dhcp failed"
        fi
        echo 80
        # For AP modes, restart hostapd to pick up any changes
        case "$mode" in
            offline|online_eth|online_wifi)
                systemctl restart hostapd 2>/dev/null || true
                ;;
        esac
        echo 100
    } | whiptail --title "$TITLE" --gauge "Applying network configuration..." 8 $WT_WIDTH 0

    console_log "apply_changes: completed mode=${mode}"

    whiptail --title "$TITLE" --msgbox \
        "Network configuration applied.\n\nMode: $(mode_label "$mode")\n\nChanges take full effect immediately.\nA reboot is recommended for best stability." \
        12 $WT_WIDTH
}


# ── Menu 1: Network Mode ────────────────────────────────────────────────────

menu_network_mode() {
    console_log "menu: Network Mode"

    if ! db_read_network_config; then
        whiptail --title "$TITLE" --msgbox "Failed to read network configuration.\nCheck ${CONSOLE_LOG} for details." 10 $WT_WIDTH
        return 0
    fi

    local current
    current=$(mode_label "$CON_MODE")

    local choice
    choice=$(whiptail --title "$TITLE — Network Mode" \
        --menu "Current mode: ${current}\n\nSelect a network mode:" \
        $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
        "offline"      "Offline (AP Only) — air-gapped, no internet" \
        "online_eth"   "Online via Ethernet — AP + NAT via eth0" \
        "online_wifi"  "Online via WiFi — AP + NAT via USB dongle" \
        "server_eth"   "Server via Ethernet — no AP, eth0 client" \
        "server_wifi"  "Server via WiFi — no AP, wlan0 client" \
        3>&1 1>&2 2>&3) || { console_log "menu: Network Mode cancelled"; return 0; }

    local new_mode="$choice"
    local ssid=""
    local password=""

    console_log "menu: Network Mode selected=${new_mode}"

    # WiFi modes require SSID + password
    if [ "$new_mode" = "online_wifi" ] || [ "$new_mode" = "server_wifi" ]; then
        ssid=$(whiptail --title "$TITLE — WiFi Credentials" \
            --inputbox "Enter WiFi network name (SSID):" \
            10 $WT_WIDTH "${CON_SSID}" \
            3>&1 1>&2 2>&3) || return 0

        if [ -z "$ssid" ]; then
            whiptail --title "$TITLE" --msgbox "SSID cannot be empty." 8 $WT_WIDTH
            return 0
        fi

        password=$(whiptail --title "$TITLE — WiFi Credentials" \
            --passwordbox "Enter WiFi password for '${ssid}':" \
            10 $WT_WIDTH \
            3>&1 1>&2 2>&3) || return 0
    fi

    # Non-OFFLINE modes: ask DHCP vs static
    if [ "$new_mode" != "offline" ]; then
        local ip_choice
        ip_choice=$(whiptail --title "$TITLE — IP Configuration" \
            --menu "How should the upstream interface get its IP?" \
            12 $WT_WIDTH 2 \
            "dhcp"   "Automatic (DHCP) — recommended" \
            "static" "Static IP — manual configuration" \
            3>&1 1>&2 2>&3) || return 0

        if [ "$ip_choice" = "static" ]; then
            prompt_static_ip "$new_mode" || return 0
        else
            db_clear_static_ip
        fi
    else
        # OFFLINE has no upstream — clear static IP
        db_clear_static_ip
    fi

    # Confirmation
    local iface
    iface=$(mode_interface "$new_mode")
    local confirm_msg="Switch network mode?\n\n"
    confirm_msg+="  New mode:  $(mode_label "$new_mode")\n"
    [ -n "$ssid" ] && confirm_msg+="  WiFi SSID: ${ssid}\n"
    confirm_msg+="  Interface: ${iface}\n"

    db_read_network_config  # re-read to get static IP state after prompt
    if [ "${CON_USE_STATIC}" = "1" ] && [ -n "${CON_STATIC_IP}" ]; then
        confirm_msg+="  Static IP: ${CON_STATIC_IP}/${CON_STATIC_NETMASK}\n"
        confirm_msg+="  Gateway:   ${CON_STATIC_GATEWAY}\n"
    else
        confirm_msg+="  IP method: DHCP (automatic)\n"
    fi

    confirm_msg+="\nWARNING: This will change your network configuration.\n"
    confirm_msg+="You may lose connectivity briefly."

    whiptail --title "$TITLE — Confirm" --yesno "$confirm_msg" 18 $WT_WIDTH || return 0

    # Write mode + credentials to DB
    if ! db_write_mode "$new_mode" "$ssid" "$password"; then
        whiptail --title "$TITLE" --msgbox "Failed to save network mode.\nCheck ${CONSOLE_LOG} for details." 10 $WT_WIDTH
        return 0
    fi

    # Apply changes via boot-lib (T24)
    apply_changes "$new_mode"
}


# ── Menu 2: Static IP Configuration ─────────────────────────────────────────

menu_static_ip() {
    console_log "menu: Static IP"

    if ! db_read_network_config; then
        whiptail --title "$TITLE" --msgbox "Failed to read network configuration." 8 $WT_WIDTH
        return 0
    fi

    if [ "$CON_MODE" = "offline" ]; then
        whiptail --title "$TITLE" --msgbox \
            "Static IP is not available in OFFLINE mode.\n\nOFFLINE mode has no upstream interface." \
            10 $WT_WIDTH
        return 0
    fi

    local iface
    iface=$(mode_interface "$CON_MODE")
    local current_ip
    current_ip=$(get_interface_ip "$iface")

    local info="Current mode: $(mode_label "$CON_MODE")\n"
    info+="Interface: ${iface}\n"
    info+="Current IP: ${current_ip:-none}\n"

    if [ "${CON_USE_STATIC}" = "1" ]; then
        info+="Config: Static (${CON_STATIC_IP})"
    else
        info+="Config: DHCP (automatic)"
    fi

    local choice
    choice=$(whiptail --title "$TITLE — Static IP" \
        --menu "$info\n\nChoose an action:" \
        16 $WT_WIDTH 3 \
        "static" "Set static IP" \
        "dhcp"   "Switch to DHCP (automatic)" \
        "back"   "Back to main menu" \
        3>&1 1>&2 2>&3) || return 0

    case "$choice" in
        static)
            prompt_static_ip "$CON_MODE" || return 0

            whiptail --title "$TITLE — Confirm" --yesno \
                "Apply static IP configuration?\n\nThis will reconfigure the upstream interface." \
                10 $WT_WIDTH || return 0

            console_log "menu: Static IP applying"
            apply_changes "$CON_MODE"
            ;;
        dhcp)
            db_clear_static_ip

            whiptail --title "$TITLE — Confirm" --yesno \
                "Switch to DHCP?\n\nThe upstream interface will request an IP automatically." \
                10 $WT_WIDTH || return 0

            console_log "menu: Static IP switching to DHCP"
            apply_changes "$CON_MODE"
            ;;
    esac
}

# Prompt for static IP fields and write to DB.
# Args: $1=mode (used for display only)
# Returns 0 on success, 1 on cancel.
prompt_static_ip() {
    local mode="$1"
    local iface
    iface=$(mode_interface "$mode")

    # Pre-fill with existing values
    db_read_network_config

    local ip netmask gateway dns1 dns2

    ip=$(whiptail --title "$TITLE — Static IP (${iface})" \
        --inputbox "IP Address (e.g. 192.168.1.100):" \
        10 $WT_WIDTH "${CON_STATIC_IP}" \
        3>&1 1>&2 2>&3) || return 1

    if ! validate_ipv4 "$ip"; then
        whiptail --title "$TITLE" --msgbox "Invalid IP address: ${ip}" 8 $WT_WIDTH
        return 1
    fi

    netmask=$(whiptail --title "$TITLE — Static IP (${iface})" \
        --inputbox "Subnet Mask (default: 255.255.255.0):" \
        10 $WT_WIDTH "${CON_STATIC_NETMASK:-255.255.255.0}" \
        3>&1 1>&2 2>&3) || return 1
    netmask="${netmask:-255.255.255.0}"

    if ! validate_ipv4 "$netmask"; then
        whiptail --title "$TITLE" --msgbox "Invalid subnet mask: ${netmask}" 8 $WT_WIDTH
        return 1
    fi

    gateway=$(whiptail --title "$TITLE — Static IP (${iface})" \
        --inputbox "Gateway (e.g. 192.168.1.1):" \
        10 $WT_WIDTH "${CON_STATIC_GATEWAY}" \
        3>&1 1>&2 2>&3) || return 1

    if ! validate_ipv4 "$gateway"; then
        whiptail --title "$TITLE" --msgbox "Invalid gateway: ${gateway}" 8 $WT_WIDTH
        return 1
    fi

    dns1=$(whiptail --title "$TITLE — Static IP (${iface})" \
        --inputbox "Primary DNS (optional, e.g. 1.1.1.1):" \
        10 $WT_WIDTH "${CON_STATIC_DNS1}" \
        3>&1 1>&2 2>&3) || return 1

    if [ -n "$dns1" ] && ! validate_ipv4 "$dns1"; then
        whiptail --title "$TITLE" --msgbox "Invalid DNS address: ${dns1}" 8 $WT_WIDTH
        return 1
    fi

    dns2=$(whiptail --title "$TITLE — Static IP (${iface})" \
        --inputbox "Secondary DNS (optional, e.g. 8.8.8.8):" \
        10 $WT_WIDTH "${CON_STATIC_DNS2}" \
        3>&1 1>&2 2>&3) || return 1

    if [ -n "$dns2" ] && ! validate_ipv4 "$dns2"; then
        whiptail --title "$TITLE" --msgbox "Invalid DNS address: ${dns2}" 8 $WT_WIDTH
        return 1
    fi

    # Write to DB
    if ! db_write_static_ip 1 "$ip" "$netmask" "$gateway" "$dns1" "$dns2"; then
        whiptail --title "$TITLE" --msgbox "Failed to save static IP configuration." 8 $WT_WIDTH
        return 1
    fi
    return 0
}


# ── Menu 3: WiFi Credentials ────────────────────────────────────────────────

menu_wifi_creds() {
    console_log "menu: WiFi Credentials"
    db_read_network_config

    local masked_pw="(not set)"
    if [ -n "$CON_PASSWORD" ]; then
        masked_pw="$(echo "$CON_PASSWORD" | sed 's/./*/g')"
    fi

    local info="Saved WiFi Credentials\n\n"
    info+="  SSID:     ${CON_SSID:-(not set)}\n"
    info+="  Password: ${masked_pw}\n\n"
    info+="These credentials are used when switching to\n"
    info+="ONLINE_WIFI or SERVER_WIFI mode."

    local choice
    choice=$(whiptail --title "$TITLE — WiFi Credentials" \
        --menu "$info" \
        16 $WT_WIDTH 2 \
        "update" "Update SSID and password" \
        "back"   "Back to main menu" \
        3>&1 1>&2 2>&3) || return 0

    [ "$choice" = "back" ] && return 0

    local ssid password

    ssid=$(whiptail --title "$TITLE — WiFi Credentials" \
        --inputbox "Enter WiFi network name (SSID):" \
        10 $WT_WIDTH "${CON_SSID}" \
        3>&1 1>&2 2>&3) || return 0

    if [ -z "$ssid" ]; then
        whiptail --title "$TITLE" --msgbox "SSID cannot be empty." 8 $WT_WIDTH
        return 0
    fi

    password=$(whiptail --title "$TITLE — WiFi Credentials" \
        --passwordbox "Enter WiFi password for '${ssid}':" \
        10 $WT_WIDTH \
        3>&1 1>&2 2>&3) || return 0

    if ! db_write_wifi_creds "$ssid" "$password"; then
        whiptail --title "$TITLE" --msgbox "Failed to save WiFi credentials." 8 $WT_WIDTH
        return 0
    fi

    whiptail --title "$TITLE" --msgbox \
        "WiFi credentials saved.\n\n  SSID: ${ssid}\n\nCredentials will be used on next WiFi mode switch or reboot." \
        12 $WT_WIDTH
}


# ── Menu 4: System Status ───────────────────────────────────────────────────

menu_system_status() {
    console_log "menu: System Status"
    db_read_network_config

    # B90: Each command wrapped individually — failures show "N/A" instead of crashing
    local mode_str
    mode_str=$(mode_label "$CON_MODE")
    local uptime_str
    uptime_str=$(uptime -p 2>/dev/null || echo "unknown")

    # Network interfaces
    local eth0_ip wlan0_ip wlan1_ip
    eth0_ip=$(get_interface_ip eth0)
    wlan0_ip=$(get_interface_ip wlan0)
    wlan1_ip=$(get_interface_ip wlan1)

    # Internet connectivity
    local internet="No"
    if ping -c1 -W2 1.1.1.1 &>/dev/null; then
        internet="Yes"
    fi

    # Docker status — B90: each subcommand guarded
    local docker_status="Not running"
    local swarm_services="0"
    local running_containers="0"
    if systemctl is-active docker &>/dev/null; then
        docker_status="Running"
        swarm_services=$(docker service ls --format '{{.Name}}' 2>/dev/null | wc -l || echo "0")
        running_containers=$(docker ps -q 2>/dev/null | wc -l || echo "0")
    fi

    # Memory + Disk — B90: guard against missing commands
    local mem_info
    mem_info=$(free -h 2>/dev/null | awk '/^Mem:/{printf "%s / %s (%.0f%%)", $3, $2, $3/$2*100}' || echo "N/A")
    local disk_info
    disk_info=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}' || echo "N/A")

    # CPU temperature
    local cpu_temp="N/A"
    if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        local raw_temp
        raw_temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "")
        if [ -n "$raw_temp" ] && [ "$raw_temp" -gt 0 ] 2>/dev/null; then
            cpu_temp="$(echo "scale=1; $raw_temp / 1000" | bc 2>/dev/null || echo "$((raw_temp / 1000))")C"
        fi
    fi

    local status_text=""
    status_text+="  NETWORK\n"
    status_text+="  Mode:       ${mode_str}\n"
    status_text+="  eth0:       ${eth0_ip:-down}\n"
    status_text+="  wlan0:      ${wlan0_ip:-down}\n"
    status_text+="  wlan1:      ${wlan1_ip:-down}\n"
    status_text+="  Internet:   ${internet}\n"
    status_text+="\n"
    status_text+="  DOCKER\n"
    status_text+="  Status:     ${docker_status}\n"
    status_text+="  Swarm:      ${swarm_services} services\n"
    status_text+="  Containers: ${running_containers} running\n"
    status_text+="\n"
    status_text+="  SYSTEM\n"
    status_text+="  Uptime:     ${uptime_str}\n"
    status_text+="  CPU Temp:   ${cpu_temp}\n"
    status_text+="  Memory:     ${mem_info}\n"
    status_text+="  Disk:       ${disk_info}"

    whiptail --title "$TITLE — System Status" --msgbox "$status_text" 22 $WT_WIDTH
}


# ── Menu 5: Reset to Offline ────────────────────────────────────────────────

menu_reset_offline() {
    console_log "menu: Reset to Offline"

    whiptail --title "$TITLE — Reset to Offline" --yesno \
        "EMERGENCY RESET\n\nThis will:\n\n  - Switch to OFFLINE mode (AP only)\n  - Clear static IP overrides\n  - Restart WiFi access point\n  - Disable NAT/forwarding\n\nThe CubeOS AP will be available immediately after reset.\nConnect via WiFi to http://cubeos.cube\n\nProceed?" \
        18 $WT_WIDTH || return 0

    console_log "menu: Reset to Offline CONFIRMED — applying"

    # Write OFFLINE to DB, clear static IP and WiFi state
    if ! db_write_mode "offline" "" ""; then
        whiptail --title "$TITLE" --msgbox "Failed to write offline mode to database." 10 $WT_WIDTH
        return 0
    fi
    db_clear_static_ip

    # Apply via boot-lib (T24)
    {
        echo 10
        # Stop hostapd before reconfiguration
        systemctl stop hostapd 2>/dev/null || true
        echo 20
        # Apply network mode (writes OFFLINE netplan, disables NAT)
        if ! apply_network_mode 2>>"$CONSOLE_LOG"; then
            console_log_error "reset_offline: apply_network_mode failed"
        fi
        echo 50
        # Configure Pi-hole for OFFLINE (DHCP on all interfaces)
        if ! configure_pihole_dhcp "offline" 2>>"$CONSOLE_LOG"; then
            console_log_error "reset_offline: configure_pihole_dhcp failed"
        fi
        echo 70
        # Restart hostapd with AP configuration
        systemctl start hostapd 2>/dev/null || true
        echo 90
        # Flush any stale iptables NAT rules
        iptables -t nat -F POSTROUTING 2>/dev/null || true
        echo 100
    } | whiptail --title "$TITLE" --gauge "Resetting to OFFLINE mode..." 8 $WT_WIDTH 0

    console_log "menu: Reset to Offline completed"

    whiptail --title "$TITLE" --msgbox \
        "Reset to OFFLINE complete.\n\nThe WiFi access point should now be available.\nConnect to the CubeOS WiFi network and open\nhttp://cubeos.cube in your browser." \
        12 $WT_WIDTH
}


# ── Menu 6: Reboot ──────────────────────────────────────────────────────────

menu_reboot() {
    console_log "menu: Reboot"

    whiptail --title "$TITLE — Reboot" --yesno \
        "Reboot the system?\n\nAll services will restart. This takes about 30-60 seconds." \
        10 $WT_WIDTH || return 0

    console_log "menu: Reboot CONFIRMED"
    CLEAN_EXIT=1
    echo "CubeOS is rebooting..."
    sync
    systemctl reboot
}


# ── Main Menu Loop ──────────────────────────────────────────────────────────

main_menu() {
    while true; do
        # Refresh current state for status bar
        db_read_network_config
        local current_mode
        current_mode=$(mode_label "$CON_MODE")

        local iface
        iface=$(mode_interface "$CON_MODE")
        local current_ip="N/A"
        if [ "$iface" != "none" ] && [ "$iface" != "unknown" ]; then
            current_ip=$(get_interface_ip "$iface")
            current_ip="${current_ip:-no IP}"
        fi

        local ap_ip
        ap_ip=$(get_interface_ip wlan0)
        ap_ip="${ap_ip:-down}"

        local choice
        choice=$(whiptail --title "$TITLE" \
            --menu "Mode: ${current_mode} | AP: ${ap_ip}\n" \
            $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
            "1" "Network Mode" \
            "2" "Static IP Configuration" \
            "3" "WiFi Credentials" \
            "4" "System Status" \
            "5" "Reset to Offline (Safe Mode)" \
            "6" "Reboot" \
            "7" "Exit to Shell" \
            3>&1 1>&2 2>&3) || {
            # B90: ESC/Cancel in main menu = exit gracefully (not crash)
            console_log "menu: Main menu cancelled (ESC/Cancel)"
            break
        }

        case "$choice" in
            1) menu_network_mode ;;
            2) menu_static_ip ;;
            3) menu_wifi_creds ;;
            4) menu_system_status ;;
            5) menu_reset_offline ;;
            6) menu_reboot ;;
            7) console_log "menu: Exit to Shell"; break ;;
        esac
    done
}


# ── Entry Point ──────────────────────────────────────────────────────────────

# Must run as root (network configuration requires it)
if [ "$(id -u)" -ne 0 ]; then
    echo "CubeOS Console requires root privileges."
    echo "Run: sudo cubeos-console"
    exit 1
fi

# Check for whiptail
if ! command -v whiptail &>/dev/null; then
    echo "ERROR: whiptail not found. Cannot start console GUI."
    exit 1
fi

# B90: Check for sqlite3 CLI (replaces python3 dependency)
if ! command -v sqlite3 &>/dev/null; then
    echo "ERROR: sqlite3 not found. Cannot access database."
    echo "Install with: apt-get install sqlite3"
    exit 1
fi

# B93: Wait for boot messages to settle before launching whiptail.
# systemd prints [OK] status lines to tty1 during startup. If the console
# launches too early, these messages overlay the whiptail menu. A brief
# pause + double clear ensures a clean screen.
sleep 2
clear
CLEAN_EXIT=0
main_menu
CLEAN_EXIT=1
clear
echo "Exited CubeOS Console. Type 'cubeos-console' to return."
