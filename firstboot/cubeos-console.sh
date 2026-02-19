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
# Features:
#   1. Switch between all 5 network modes with WiFi/static IP prompts
#   2. Configure static IP for the current mode's upstream interface
#   3. Update WiFi credentials (SSID + password)
#   4. View system status (network, Docker, resources)
#   5. Emergency reset to OFFLINE mode (safe default)
#   6. Clean reboot
#
# Dependencies: whiptail (pre-installed on Ubuntu), python3, sqlite3 CLI
# Sources cubeos-boot-lib.sh for apply_network_mode() and shared constants.
# =============================================================================
set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
readonly DB_PATH="/cubeos/data/cubeos.db"
readonly BOOT_LIB="/usr/local/bin/cubeos-boot-lib.sh"
readonly TITLE="CubeOS System Console"
readonly WT_WIDTH=72
readonly WT_HEIGHT=20
readonly WT_LIST_HEIGHT=10

# ── Source boot-lib for apply_network_mode() and helpers ─────────────────────
if [ -f "$BOOT_LIB" ]; then
    # Redirect log output to /dev/null when sourced from console
    # (boot-lib writes to LOG_FILE which may not exist in interactive use)
    export LOG_FILE="/dev/null"
    # shellcheck source=/usr/local/bin/cubeos-boot-lib.sh
    source "$BOOT_LIB"
else
    echo "ERROR: Boot library not found at $BOOT_LIB"
    echo "CubeOS may not be properly installed."
    exit 1
fi

# ── SQLite Helpers (T23) ─────────────────────────────────────────────────────
# Read/write to SQLite using python3 -c one-liners (matches boot-lib pattern).
# These functions provide safe, shell-escaped access to the network_config table.

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

    eval "$(python3 -c "
import sqlite3
try:
    conn = sqlite3.connect('${DB_PATH}')
    row = conn.execute('SELECT mode, wifi_ssid, wifi_password, use_static_ip, static_ip_address, static_ip_netmask, static_ip_gateway, static_dns_primary, static_dns_secondary FROM network_config WHERE id = 1').fetchone()
    if row:
        print(f'CON_MODE={row[0]}')
        ssid = (row[1] or '').replace(\"'\", \"'\\\"'\\\"'\")
        pw = (row[2] or '').replace(\"'\", \"'\\\"'\\\"'\")
        print(f\"CON_SSID='{ssid}'\")
        print(f\"CON_PASSWORD='{pw}'\")
        print(f'CON_USE_STATIC={1 if row[3] else 0}')
        print(f\"CON_STATIC_IP='{row[4] or ''}'\")
        print(f\"CON_STATIC_NETMASK='{row[5] or '255.255.255.0'}'\")
        print(f\"CON_STATIC_GATEWAY='{row[6] or ''}'\")
        print(f\"CON_STATIC_DNS1='{row[7] or ''}'\")
        print(f\"CON_STATIC_DNS2='{row[8] or ''}'\")
    conn.close()
except: pass
" 2>/dev/null)" || true

    CON_MODE="${CON_MODE:-offline}"
}

# Write network mode + WiFi credentials to SQLite.
# Args: $1=mode, $2=ssid (optional), $3=password (optional)
db_write_mode() {
    local mode="$1"
    local ssid="${2:-}"
    local password="${3:-}"

    [ ! -f "$DB_PATH" ] && return 1

    python3 -c "
import sqlite3
conn = sqlite3.connect('${DB_PATH}')
conn.execute('''UPDATE network_config
    SET mode = ?, wifi_ssid = ?, wifi_password = ?
    WHERE id = 1''', ('${mode}', '''${ssid}''', '''${password}'''))
conn.commit()
conn.close()
" 2>/dev/null
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

    [ ! -f "$DB_PATH" ] && return 1

    python3 -c "
import sqlite3
conn = sqlite3.connect('${DB_PATH}')
conn.execute('''UPDATE network_config
    SET use_static_ip = ?, static_ip_address = ?, static_ip_netmask = ?,
        static_ip_gateway = ?, static_dns_primary = ?, static_dns_secondary = ?
    WHERE id = 1''', (${use_static}, '${ip}', '${netmask}', '${gateway}', '${dns1}', '${dns2}'))
conn.commit()
conn.close()
" 2>/dev/null
}

# Write WiFi credentials only (no mode change).
# Args: $1=ssid, $2=password
db_write_wifi_creds() {
    local ssid="$1"
    local password="$2"

    [ ! -f "$DB_PATH" ] && return 1

    python3 -c "
import sqlite3
conn = sqlite3.connect('${DB_PATH}')
conn.execute('''UPDATE network_config
    SET wifi_ssid = ?, wifi_password = ?
    WHERE id = 1''', ('''${ssid}''', '''${password}'''))
conn.commit()
conn.close()
" 2>/dev/null
}

# Clear static IP overrides (reset to DHCP).
db_clear_static_ip() {
    [ ! -f "$DB_PATH" ] && return 1

    python3 -c "
import sqlite3
conn = sqlite3.connect('${DB_PATH}')
conn.execute('''UPDATE network_config
    SET use_static_ip = 0, static_ip_address = '', static_ip_netmask = '255.255.255.0',
        static_ip_gateway = '', static_dns_primary = '', static_dns_secondary = ''
    WHERE id = 1''')
conn.commit()
conn.close()
" 2>/dev/null
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

    # Show a progress message while applying (whiptail gauge)
    {
        echo 10
        # apply_network_mode reads from DB and writes netplan + applies
        apply_network_mode 2>/dev/null || true
        echo 50
        # Configure Pi-hole DHCP scope for the new mode
        configure_pihole_dhcp "$mode" 2>/dev/null || true
        echo 80
        # For AP modes, restart hostapd to pick up any changes
        case "$mode" in
            offline|online_eth|online_wifi)
                systemctl restart hostapd 2>/dev/null || true
                ;;
        esac
        echo 100
    } | whiptail --title "$TITLE" --gauge "Applying network configuration..." 8 $WT_WIDTH 0

    whiptail --title "$TITLE" --msgbox \
        "Network configuration applied.\n\nMode: $(mode_label "$mode")\n\nChanges take full effect immediately.\nA reboot is recommended for best stability." \
        12 $WT_WIDTH
}


# ── Menu 1: Network Mode ────────────────────────────────────────────────────

menu_network_mode() {
    db_read_network_config

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
        3>&1 1>&2 2>&3) || return 0

    local new_mode="$choice"
    local ssid=""
    local password=""

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
    db_write_mode "$new_mode" "$ssid" "$password"

    # Apply changes via boot-lib (T24)
    apply_changes "$new_mode"
}


# ── Menu 2: Static IP Configuration ─────────────────────────────────────────

menu_static_ip() {
    db_read_network_config

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

            apply_changes "$CON_MODE"
            ;;
        dhcp)
            db_clear_static_ip

            whiptail --title "$TITLE — Confirm" --yesno \
                "Switch to DHCP?\n\nThe upstream interface will request an IP automatically." \
                10 $WT_WIDTH || return 0

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
    db_write_static_ip 1 "$ip" "$netmask" "$gateway" "$dns1" "$dns2"
    return 0
}


# ── Menu 3: WiFi Credentials ────────────────────────────────────────────────

menu_wifi_creds() {
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

    db_write_wifi_creds "$ssid" "$password"

    whiptail --title "$TITLE" --msgbox \
        "WiFi credentials saved.\n\n  SSID: ${ssid}\n\nCredentials will be used on next WiFi mode switch or reboot." \
        12 $WT_WIDTH
}


# ── Menu 4: System Status ───────────────────────────────────────────────────

menu_system_status() {
    db_read_network_config

    # Gather system info
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

    # Docker status
    local docker_status="Not running"
    local swarm_services=0
    local running_containers=0
    if systemctl is-active docker &>/dev/null; then
        docker_status="Running"
        swarm_services=$(docker service ls --format '{{.Name}}' 2>/dev/null | wc -l)
        running_containers=$(docker ps -q 2>/dev/null | wc -l)
    fi

    # Memory + Disk
    local mem_info
    mem_info=$(free -h 2>/dev/null | awk '/^Mem:/{printf "%s / %s (%.0f%%)", $3, $2, $3/$2*100}')
    local disk_info
    disk_info=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}')

    # CPU temperature
    local cpu_temp="N/A"
    if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        local raw_temp
        raw_temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
        if [ -n "$raw_temp" ]; then
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
    whiptail --title "$TITLE — Reset to Offline" --yesno \
        "EMERGENCY RESET\n\nThis will:\n\n  - Switch to OFFLINE mode (AP only)\n  - Clear static IP overrides\n  - Restart WiFi access point\n  - Disable NAT/forwarding\n\nThe CubeOS AP will be available immediately after reset.\nConnect via WiFi to http://cubeos.cube\n\nProceed?" \
        18 $WT_WIDTH || return 0

    # Write OFFLINE to DB, clear static IP and WiFi state
    db_write_mode "offline" "" ""
    db_clear_static_ip

    # Apply via boot-lib (T24)
    {
        echo 10
        # Stop hostapd before reconfiguration
        systemctl stop hostapd 2>/dev/null || true
        echo 20
        # Apply network mode (writes OFFLINE netplan, disables NAT)
        apply_network_mode 2>/dev/null || true
        echo 50
        # Configure Pi-hole for OFFLINE (DHCP on all interfaces)
        configure_pihole_dhcp "offline" 2>/dev/null || true
        echo 70
        # Restart hostapd with AP configuration
        systemctl start hostapd 2>/dev/null || true
        echo 90
        # Flush any stale iptables NAT rules
        iptables -t nat -F POSTROUTING 2>/dev/null || true
        echo 100
    } | whiptail --title "$TITLE" --gauge "Resetting to OFFLINE mode..." 8 $WT_WIDTH 0

    whiptail --title "$TITLE" --msgbox \
        "Reset to OFFLINE complete.\n\nThe WiFi access point should now be available.\nConnect to the CubeOS WiFi network and open\nhttp://cubeos.cube in your browser." \
        12 $WT_WIDTH
}


# ── Menu 6: Reboot ──────────────────────────────────────────────────────────

menu_reboot() {
    whiptail --title "$TITLE — Reboot" --yesno \
        "Reboot the system?\n\nAll services will restart. This takes about 30-60 seconds." \
        10 $WT_WIDTH || return 0

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
            3>&1 1>&2 2>&3) || break  # ESC/Cancel exits

        case "$choice" in
            1) menu_network_mode ;;
            2) menu_static_ip ;;
            3) menu_wifi_creds ;;
            4) menu_system_status ;;
            5) menu_reset_offline ;;
            6) menu_reboot ;;
            7) break ;;
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

# Check for python3 (needed for SQLite access)
if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 not found. Cannot access database."
    exit 1
fi

clear
main_menu
clear
echo "Exited CubeOS Console. Type 'cubeos-console' to return."
