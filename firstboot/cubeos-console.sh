#!/bin/bash
# =============================================================================
# cubeos-console.sh — CubeOS System Console (whiptail TUI)
# =============================================================================
# Emergency recovery and network management console accessible via HDMI+keyboard
# on tty1. Auto-launched after login on tty1; SSH sessions are NOT affected.
#
# Features:
#   1. Switch between all 6 network modes with WiFi/static IP prompts
#   2. Configure static IP for the current mode's upstream interface
#   3. Access Point settings (SSID + password)
#   4. Update upstream WiFi credentials (SSID + password)
#   5. View system status (network, Docker, resources)
#   6. Emergency reset to offline_hotspot (safe default)
#   7. Factory reset (wipe all data, return to first-boot)
#   8. Clean reboot
#
# Network modes (Phase 6a):
#   offline_hotspot  — AP only, no internet (air-gapped)
#   wifi_router      — AP + upstream via Ethernet
#   wifi_bridge      — AP bridged to upstream WiFi
#   android_tether   — AP + upstream via USB tether
#   eth_client       — Ethernet only, no AP
#   wifi_client      — WiFi station only, no AP
#
# Dependencies: whiptail (pre-installed on Ubuntu), sqlite3 CLI
# Sources cubeos-boot-lib.sh for apply_network_mode() and shared constants.
# =============================================================================

# Only set -u (catch unset variables). Do NOT use -e (whiptail returns
# non-zero on Cancel/Escape) or -o pipefail (causes spurious failures in
# subshells gathering system info).
set -u

# ── Constants ────────────────────────────────────────────────────────────────
readonly DB_PATH="/cubeos/data/cubeos.db"
readonly BOOT_LIB="/usr/local/bin/cubeos-boot-lib.sh"
readonly HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
readonly TITLE="CubeOS System Console"
readonly WT_WIDTH=72
readonly WT_HEIGHT=20
readonly WT_LIST_HEIGHT=10
readonly CONSOLE_LOG="/var/log/cubeos-console.log"
readonly CONSOLE_LOG_MAX_BYTES=1048576  # 1MB

# ── Console Logging ──────────────────────────────────────────────────────────

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
    # Direct boot-lib log output to the console log file (not /dev/null).
    # boot-lib's log() writes to LOG_FILE and stderr.
    export LOG_FILE="$CONSOLE_LOG"
    # shellcheck source=/usr/local/bin/cubeos-boot-lib.sh
    source "$BOOT_LIB"
else
    echo "ERROR: Boot library not found at $BOOT_LIB"
    echo "CubeOS may not be properly installed."
    exit 1
fi

# ── Unexpected Exit Trap ─────────────────────────────────────────────────────
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

# ── SQLite Helpers ───────────────────────────────────────────────────────────
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
        CON_MODE="offline_hotspot"
        return 0
    fi

    local db_output
    db_output=$(sqlite3 -separator '|' "$DB_PATH" \
        "SELECT mode, wifi_ssid, wifi_password, use_static_ip, static_ip_address, static_ip_netmask, static_ip_gateway, static_dns_primary, static_dns_secondary FROM network_config WHERE id = 1;" 2>/dev/null) || {
        console_log_error "db_read_network_config: sqlite3 query failed"
        CON_MODE="offline_hotspot"
        return 0
    }

    if [ -z "$db_output" ]; then
        CON_MODE="offline_hotspot"
        return 0
    fi

    # Parse pipe-separated fields using IFS
    local IFS='|'
    # shellcheck disable=SC2086
    set -- $db_output
    CON_MODE="${1:-offline_hotspot}"
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

    CON_MODE="${CON_MODE:-offline_hotspot}"
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

# Human-readable mode name for the 6 CubeOS network modes.
mode_label() {
    case "$1" in
        offline_hotspot) echo "Offline Hotspot" ;;
        wifi_router)     echo "WiFi Router" ;;
        wifi_bridge)     echo "WiFi Bridge" ;;
        android_tether)  echo "Android Tether" ;;
        eth_client)      echo "Ethernet Client" ;;
        wifi_client)     echo "WiFi Client" ;;
        *)               echo "$1" ;;
    esac
}

# Get the upstream interface for a given mode (matches boot-lib).
mode_interface() {
    case "$1" in
        wifi_router|eth_client) echo "eth0" ;;
        wifi_bridge)            echo "wlan1" ;;
        wifi_client)            echo "wlan0" ;;
        android_tether)         echo "usb0" ;;
        offline_hotspot)        echo "none" ;;
        *)                      echo "unknown" ;;
    esac
}

# Returns 0 if the mode runs an AP (hostapd), 1 otherwise.
mode_has_ap() {
    case "$1" in
        offline_hotspot|wifi_router|wifi_bridge|android_tether) return 0 ;;
        *) return 1 ;;
    esac
}

# Returns 0 if the mode needs upstream WiFi credentials.
mode_needs_wifi() {
    case "$1" in
        wifi_router|wifi_bridge|wifi_client) return 0 ;;
        *) return 1 ;;
    esac
}

# Get current AP SSID from hostapd.conf.
get_ap_ssid() {
    grep '^ssid=' "$HOSTAPD_CONF" 2>/dev/null | cut -d= -f2
}

# Get current AP password from hostapd.conf.
get_ap_password() {
    grep '^wpa_passphrase=' "$HOSTAPD_CONF" 2>/dev/null | cut -d= -f2
}

# Get current IP on an interface
get_interface_ip() {
    local iface="$1"
    ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1
}

# ── Apply Changes ───────────────────────────────────────────────────────────
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
        if mode_has_ap "$mode"; then
            systemctl restart hostapd 2>/dev/null || true
        fi
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
        "offline_hotspot" "Offline Hotspot — air-gapped, AP only" \
        "wifi_router"     "WiFi Router — AP + upstream via Ethernet" \
        "wifi_bridge"     "WiFi Bridge — transparent bridge via WiFi" \
        "eth_client"      "Ethernet Client — no AP, eth0 only" \
        "wifi_client"     "WiFi Client — no AP, connect to WiFi" \
        "android_tether"  "Android Tether — AP + upstream via USB" \
        3>&1 1>&2 2>&3) || { console_log "menu: Network Mode cancelled"; return 0; }

    local new_mode="$choice"
    local ssid=""
    local password=""

    console_log "menu: Network Mode selected=${new_mode}"

    # Modes with upstream WiFi require SSID + password
    if mode_needs_wifi "$new_mode"; then
        ssid=$(whiptail --title "$TITLE — Upstream WiFi Credentials" \
            --inputbox "Enter upstream WiFi network name (SSID):" \
            10 $WT_WIDTH "${CON_SSID}" \
            3>&1 1>&2 2>&3) || return 0

        if [ -z "$ssid" ]; then
            whiptail --title "$TITLE" --msgbox "SSID cannot be empty." 8 $WT_WIDTH
            return 0
        fi

        password=$(whiptail --title "$TITLE — Upstream WiFi Credentials" \
            --passwordbox "Enter WiFi password for '${ssid}':" \
            10 $WT_WIDTH \
            3>&1 1>&2 2>&3) || return 0
    fi

    # Modes with an upstream interface: ask DHCP vs static
    # offline_hotspot has no upstream; android_tether gets DHCP from phone
    if [ "$new_mode" != "offline_hotspot" ] && [ "$new_mode" != "android_tether" ]; then
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
        # No upstream — clear static IP
        db_clear_static_ip
    fi

    # Confirmation
    local iface
    iface=$(mode_interface "$new_mode")
    local confirm_msg="Switch network mode?\n\n"
    confirm_msg+="  New mode:  $(mode_label "$new_mode")\n"
    [ -n "$ssid" ] && confirm_msg+="  WiFi SSID: ${ssid}\n"
    [ "$iface" != "none" ] && confirm_msg+="  Interface: ${iface}\n"

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

    # Apply changes via boot-lib
    apply_changes "$new_mode"
}


# ── Menu 2: Static IP Configuration ─────────────────────────────────────────

menu_static_ip() {
    console_log "menu: Static IP"

    if ! db_read_network_config; then
        whiptail --title "$TITLE" --msgbox "Failed to read network configuration." 8 $WT_WIDTH
        return 0
    fi

    if [ "$CON_MODE" = "offline_hotspot" ] || [ "$CON_MODE" = "android_tether" ]; then
        whiptail --title "$TITLE" --msgbox \
            "Static IP is not available in $(mode_label "$CON_MODE") mode.\n\nThis mode has no configurable upstream interface." \
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


# ── Menu 3: Access Point Settings ────────────────────────────────────────────

menu_ap_settings() {
    console_log "menu: Access Point Settings"

    db_read_network_config

    if ! mode_has_ap "$CON_MODE"; then
        whiptail --title "$TITLE" --msgbox \
            "Access Point is not active in $(mode_label "$CON_MODE") mode.\n\nSwitch to a mode with AP (e.g. Offline Hotspot,\nWiFi Router) to configure the access point." \
            10 $WT_WIDTH
        return 0
    fi

    local current_ssid current_pass masked_pass
    current_ssid=$(get_ap_ssid)
    current_pass=$(get_ap_password)
    current_ssid="${current_ssid:-(unknown)}"

    masked_pass="(not set)"
    if [ -n "$current_pass" ]; then
        masked_pass="$(echo "$current_pass" | sed 's/./*/g')"
    fi

    local info="Current Access Point Settings\n\n"
    info+="  SSID:     ${current_ssid}\n"
    info+="  Password: ${masked_pass}\n"

    local choice
    choice=$(whiptail --title "$TITLE — Access Point Settings" \
        --menu "$info" \
        16 $WT_WIDTH 3 \
        "ssid"     "Change AP network name (SSID)" \
        "password" "Change AP password" \
        "back"     "Back to main menu" \
        3>&1 1>&2 2>&3) || return 0

    case "$choice" in
        ssid)
            local new_ssid
            new_ssid=$(whiptail --title "$TITLE — AP SSID" \
                --inputbox "Enter new AP network name (SSID):\n\n(1-32 characters, visible to WiFi clients)" \
                12 $WT_WIDTH "${current_ssid}" \
                3>&1 1>&2 2>&3) || return 0

            if [ -z "$new_ssid" ]; then
                whiptail --title "$TITLE" --msgbox "SSID cannot be empty." 8 $WT_WIDTH
                return 0
            fi
            if [ "${#new_ssid}" -gt 32 ]; then
                whiptail --title "$TITLE" --msgbox "SSID too long (max 32 characters)." 8 $WT_WIDTH
                return 0
            fi

            whiptail --title "$TITLE — Confirm" --yesno \
                "Change AP SSID?\n\n  Old: ${current_ssid}\n  New: ${new_ssid}\n\nHostapd will be restarted.\nConnected WiFi clients will be disconnected." \
                14 $WT_WIDTH || return 0

            sed -i "s/^ssid=.*/ssid=${new_ssid}/" "$HOSTAPD_CONF" 2>/dev/null || {
                whiptail --title "$TITLE" --msgbox "Failed to update hostapd.conf" 8 $WT_WIDTH
                return 0
            }
            systemctl restart hostapd 2>/dev/null || true
            console_log "AP SSID changed: ${current_ssid} -> ${new_ssid}"

            whiptail --title "$TITLE" --msgbox \
                "AP SSID changed to: ${new_ssid}\n\nReconnect WiFi clients to the new network name." \
                10 $WT_WIDTH
            ;;
        password)
            local new_pass
            new_pass=$(whiptail --title "$TITLE — AP Password" \
                --inputbox "Enter new AP password:\n\n(8-63 characters, WPA2)" \
                12 $WT_WIDTH "" \
                3>&1 1>&2 2>&3) || return 0

            if [ "${#new_pass}" -lt 8 ]; then
                whiptail --title "$TITLE" --msgbox "Password too short (minimum 8 characters)." 8 $WT_WIDTH
                return 0
            fi
            if [ "${#new_pass}" -gt 63 ]; then
                whiptail --title "$TITLE" --msgbox "Password too long (maximum 63 characters)." 8 $WT_WIDTH
                return 0
            fi

            whiptail --title "$TITLE — Confirm" --yesno \
                "Change AP password?\n\nHostapd will be restarted.\nConnected WiFi clients will be disconnected." \
                12 $WT_WIDTH || return 0

            sed -i "s/^wpa_passphrase=.*/wpa_passphrase=${new_pass}/" "$HOSTAPD_CONF" 2>/dev/null || {
                whiptail --title "$TITLE" --msgbox "Failed to update hostapd.conf" 8 $WT_WIDTH
                return 0
            }
            systemctl restart hostapd 2>/dev/null || true
            console_log "AP password changed"

            whiptail --title "$TITLE" --msgbox \
                "AP password changed.\n\nReconnect WiFi clients with the new password." \
                10 $WT_WIDTH
            ;;
    esac
}


# ── Menu 4: WiFi Credentials (upstream) ─────────────────────────────────────

menu_wifi_creds() {
    console_log "menu: WiFi Credentials"
    db_read_network_config

    local masked_pw="(not set)"
    if [ -n "$CON_PASSWORD" ]; then
        masked_pw="$(echo "$CON_PASSWORD" | sed 's/./*/g')"
    fi

    local info="Saved Upstream WiFi Credentials\n\n"
    info+="  SSID:     ${CON_SSID:-(not set)}\n"
    info+="  Password: ${masked_pw}\n\n"
    info+="These credentials are used when switching to\n"
    info+="WiFi Router, WiFi Bridge, or WiFi Client mode."

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
        --inputbox "Enter upstream WiFi network name (SSID):" \
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


# ── Menu 5: System Status ───────────────────────────────────────────────────

menu_system_status() {
    console_log "menu: System Status"
    db_read_network_config

    local mode_str
    mode_str=$(mode_label "$CON_MODE")
    local uptime_str
    uptime_str=$(uptime -p 2>/dev/null || echo "unknown")

    # Network interfaces
    local eth0_ip wlan0_ip wlan1_ip
    eth0_ip=$(get_interface_ip eth0)
    wlan0_ip=$(get_interface_ip wlan0)
    wlan1_ip=$(get_interface_ip wlan1)

    # AP SSID (if AP mode)
    local ap_ssid_str=""
    if mode_has_ap "$CON_MODE"; then
        local ap_ssid
        ap_ssid=$(get_ap_ssid)
        ap_ssid_str=" (${ap_ssid:-unknown})"
    fi

    # Internet connectivity
    local internet="No"
    if ping -c1 -W2 1.1.1.1 &>/dev/null; then
        internet="Yes"
    fi

    # Docker status
    local docker_status="Not running"
    local swarm_services="0"
    local running_containers="0"
    if systemctl is-active docker &>/dev/null; then
        docker_status="Running"
        swarm_services=$(docker service ls --format '{{.Name}}' 2>/dev/null | wc -l || echo "0")
        running_containers=$(docker ps -q 2>/dev/null | wc -l || echo "0")
    fi

    # Memory + Disk
    local mem_info
    mem_info=$(free -h 2>/dev/null | awk '/^Mem:/{printf "%s / %s (%.0f%%)", $3, $2, $3/$2*100}' || echo "N/A")
    local disk_root
    disk_root=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}' || echo "N/A")
    local disk_data
    disk_data=$(du -sh /cubeos/data 2>/dev/null | awk '{print $1}' || echo "N/A")

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
    status_text+="  wlan0:      ${wlan0_ip:-down}${ap_ssid_str}\n"
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
    status_text+="  Disk /:     ${disk_root}\n"
    status_text+="  Data:       ${disk_data}"

    whiptail --title "$TITLE — System Status" --msgbox "$status_text" 24 $WT_WIDTH
}


# ── Menu 6: Reset to Offline Hotspot ─────────────────────────────────────────

menu_reset_offline() {
    console_log "menu: Reset to Offline Hotspot"

    whiptail --title "$TITLE — Reset to Offline Hotspot" --yesno \
        "EMERGENCY RESET\n\nThis will:\n\n  - Switch to Offline Hotspot mode (AP only)\n  - Clear static IP overrides\n  - Restart WiFi access point\n  - Disable NAT/forwarding\n\nThe CubeOS AP will be available immediately after reset.\nConnect via WiFi to http://cubeos.cube\n\nProceed?" \
        18 $WT_WIDTH || return 0

    console_log "menu: Reset to Offline Hotspot CONFIRMED — applying"

    # Write offline_hotspot to DB, clear static IP and WiFi state
    if ! db_write_mode "offline_hotspot" "" ""; then
        whiptail --title "$TITLE" --msgbox "Failed to write offline_hotspot mode to database." 10 $WT_WIDTH
        return 0
    fi
    db_clear_static_ip

    # Apply via boot-lib
    {
        echo 10
        # Stop hostapd before reconfiguration
        systemctl stop hostapd 2>/dev/null || true
        echo 20
        # Apply network mode (writes offline_hotspot netplan, disables NAT)
        if ! apply_network_mode 2>>"$CONSOLE_LOG"; then
            console_log_error "reset_offline: apply_network_mode failed"
        fi
        echo 50
        # Configure Pi-hole for offline_hotspot (DHCP on all interfaces)
        if ! configure_pihole_dhcp "offline_hotspot" 2>>"$CONSOLE_LOG"; then
            console_log_error "reset_offline: configure_pihole_dhcp failed"
        fi
        echo 70
        # Restart hostapd with AP configuration
        systemctl start hostapd 2>/dev/null || true
        echo 90
        # Flush any stale iptables NAT rules
        iptables -t nat -F POSTROUTING 2>/dev/null || true
        echo 100
    } | whiptail --title "$TITLE" --gauge "Resetting to Offline Hotspot..." 8 $WT_WIDTH 0

    console_log "menu: Reset to Offline Hotspot completed"

    whiptail --title "$TITLE" --msgbox \
        "Reset to Offline Hotspot complete.\n\nThe WiFi access point should now be available.\nConnect to the CubeOS WiFi network and open\nhttp://cubeos.cube in your browser." \
        12 $WT_WIDTH
}


# ── Menu 7: Factory Reset ───────────────────────────────────────────────────

menu_factory_reset() {
    console_log "menu: Factory Reset"

    whiptail --title "$TITLE — Factory Reset" --yesno \
        "FACTORY RESET\n\nThis will PERMANENTLY:\n\n  - Stop and remove ALL Docker stacks\n  - Delete the database and all app data\n  - Remove the setup completion flag\n  - Reset AP to default SSID and password\n\nThe device will reboot into first-boot setup.\nAll configuration and installed apps will be lost.\n\nAre you sure?" \
        20 $WT_WIDTH || return 0

    # Require typing RESET to confirm
    local confirm
    confirm=$(whiptail --title "$TITLE — Factory Reset — FINAL CONFIRMATION" \
        --inputbox "Type RESET to confirm factory reset:" \
        10 $WT_WIDTH "" \
        3>&1 1>&2 2>&3) || return 0

    if [ "$confirm" != "RESET" ]; then
        whiptail --title "$TITLE" --msgbox "Factory reset cancelled.\n\nYou must type exactly RESET to confirm." 10 $WT_WIDTH
        console_log "menu: Factory Reset cancelled (wrong confirmation: '${confirm}')"
        return 0
    fi

    console_log "menu: Factory Reset CONFIRMED — executing"

    {
        echo 5
        # Stop all Docker stacks gracefully
        docker stack ls --format '{{.Name}}' 2>/dev/null | while read -r stack; do
            docker stack rm "$stack" 2>/dev/null || true
        done
        echo 30
        sleep 5
        echo 50
        # Remove app data (preserve system dirs)
        rm -rf /cubeos/data/apps/ 2>/dev/null || true
        echo 60
        # Remove setup flag and DB — triggers first-boot on next boot
        rm -f /cubeos/data/.setup_complete
        rm -f /cubeos/data/cubeos.db
        echo 70
        # Reset hostapd to default SSID based on serial number
        local SERIAL
        SERIAL=$(grep Serial /proc/cpuinfo 2>/dev/null | awk '{print $3}' | tail -c 7 | tr '[:lower:]' '[:upper:]')
        SERIAL="${SERIAL:-000000}"
        sed -i "s/^ssid=.*/ssid=CubeOS-${SERIAL}/" "$HOSTAPD_CONF" 2>/dev/null || true
        sed -i "s/^wpa_passphrase=.*/wpa_passphrase=cubeos123/" "$HOSTAPD_CONF" 2>/dev/null || true
        echo 90
        # Log the reset
        console_log "Factory reset completed — rebooting"
        echo 100
    } | whiptail --title "$TITLE" --gauge "Performing factory reset..." 8 $WT_WIDTH 0

    whiptail --title "$TITLE — Factory Reset" --msgbox \
        "Factory reset complete.\n\nThe device will now reboot into\nfirst-boot setup." \
        10 $WT_WIDTH

    CLEAN_EXIT=1
    sync
    systemctl reboot
}


# ── Menu 8: Reboot ──────────────────────────────────────────────────────────

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
            "3" "Access Point Settings" \
            "4" "WiFi Credentials (upstream)" \
            "5" "System Status" \
            "6" "Reset to Offline (Safe Mode)" \
            "7" "Factory Reset" \
            "8" "Reboot" \
            "9" "Exit to Shell" \
            3>&1 1>&2 2>&3) || {
            # ESC/Cancel in main menu = exit gracefully (not crash)
            console_log "menu: Main menu cancelled (ESC/Cancel)"
            break
        }

        case "$choice" in
            1) menu_network_mode ;;
            2) menu_static_ip ;;
            3) menu_ap_settings ;;
            4) menu_wifi_creds ;;
            5) menu_system_status ;;
            6) menu_reset_offline ;;
            7) menu_factory_reset ;;
            8) menu_reboot ;;
            9) console_log "menu: Exit to Shell"; break ;;
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

# Check for sqlite3 CLI
if ! command -v sqlite3 &>/dev/null; then
    echo "ERROR: sqlite3 not found. Cannot access database."
    echo "Install with: apt-get install sqlite3"
    exit 1
fi

# Wait for boot messages to settle before launching whiptail.
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
