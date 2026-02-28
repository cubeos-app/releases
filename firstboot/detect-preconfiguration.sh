#!/bin/bash
# =============================================================================
# detect-preconfiguration.sh — Detect and extract pre-configuration from
# flashing tools (Pi Imager, Armbian, custom.toml, LXC/Proxmox)
# =============================================================================
#
# Called early in cubeos-first-boot.sh, BEFORE any CubeOS-specific setup.
# Writes /cubeos/config/preconfiguration.json with extracted settings.
#
# Detection priority: cloud-init → Armbian firstrun → custom.toml → LXC → none
# First match wins.
#
# Exit codes:
#   0 = pre-configuration detected and extracted
#   1 = no pre-configuration found (default CubeOS flow)
#   2 = detection error (parse failure, missing tools, etc.)
# =============================================================================
set -uo pipefail

# Source shared library for logging functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_PATH="${SCRIPT_DIR}/cubeos-boot-lib.sh"
[ -f "$LIB_PATH" ] || LIB_PATH="/usr/local/bin/cubeos-boot-lib.sh"
if [ -f "$LIB_PATH" ]; then
    # Only source if not already sourced (first-boot sources it first)
    if [ -z "${GATEWAY_IP:-}" ]; then
        source "$LIB_PATH"
    fi
fi

# Fallback logging if boot-lib not available
if ! command -v log &>/dev/null; then
    log()      { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
    log_ok()   { log "OK: $*"; }
    log_warn() { log "WARN: $*"; }
    log_fail() { log "FAIL: $*"; }
fi

PRECONFIG_OUTPUT="/cubeos/config/preconfiguration.json"
BOOT_FIRMWARE="/boot/firmware"

# --- Helper: Write preconfiguration.json ---
write_preconfig_json() {
    local source="$1"
    local hostname="${2:-}"
    local timezone="${3:-}"
    local locale="${4:-}"
    local keyboard="${5:-}"
    local wifi_ssid="${6:-}"
    local wifi_password="${7:-}"
    local wifi_country="${8:-}"
    local wifi_hidden="${9:-false}"
    local users_json="${10:-[]}"
    local ssh_enabled="${11:-true}"
    local ssh_pwauth="${12:-true}"

    # Determine network mode hint
    local network_mode_hint="wifi_router"
    local access_profile_hint="standard"
    if [ -n "$wifi_ssid" ]; then
        network_mode_hint="wifi_client"
    elif ip link show eth0 2>/dev/null | grep -q "state UP"; then
        network_mode_hint="eth_client"
    fi

    # Build WiFi JSON block
    local wifi_json="null"
    if [ -n "$wifi_ssid" ]; then
        wifi_json=$(python3 -c "
import json, sys
print(json.dumps({
    'ssid': sys.argv[1],
    'password': sys.argv[2],
    'country': sys.argv[3],
    'hidden': sys.argv[4] == 'true'
}))
" "$wifi_ssid" "$wifi_password" "$wifi_country" "$wifi_hidden" 2>/dev/null || echo "null")
    fi

    local detected_at
    detected_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    python3 -c "
import json, sys
data = {
    'source': sys.argv[1],
    'detected_at': sys.argv[2],
    'hostname': sys.argv[3],
    'timezone': sys.argv[4],
    'locale': sys.argv[5],
    'keyboard_layout': sys.argv[6],
    'wifi': json.loads(sys.argv[7]),
    'users': json.loads(sys.argv[8]),
    'ssh': {
        'enabled': sys.argv[9] == 'true',
        'password_auth': sys.argv[10] == 'true'
    },
    'network_mode_hint': sys.argv[11],
    'access_profile_hint': sys.argv[12]
}
with open(sys.argv[13], 'w') as f:
    json.dump(data, f, indent=2)
" "$source" "$detected_at" "$hostname" "$timezone" "$locale" "$keyboard" \
  "$wifi_json" "$users_json" "$ssh_enabled" "$ssh_pwauth" \
  "$network_mode_hint" "$access_profile_hint" "$PRECONFIG_OUTPUT" 2>/dev/null

    if [ $? -ne 0 ]; then
        log_warn "Failed to write preconfiguration.json via python3"
        return 1
    fi

    chmod 640 "$PRECONFIG_OUTPUT"
    chown root:cubeos "$PRECONFIG_OUTPUT" 2>/dev/null || true
    log_ok "Pre-configuration written: source=$source, hostname=$hostname, wifi_ssid=$wifi_ssid, mode=$network_mode_hint"
}

# --- Detector 1: Cloud-Init (Pi Imager, Proxmox VMs) ---
detect_cloud_init() {
    log "Checking for cloud-init pre-configuration..."

    if ! command -v cloud-init &>/dev/null; then
        log "cloud-init not installed -- skipping"
        return 1
    fi

    # Wait for cloud-init to complete (Pi Imager customizations)
    log "Waiting for cloud-init to complete (60s timeout)..."
    timeout 60 cloud-init status --wait --long 2>/dev/null || true
    # Update heartbeat if first-boot is tracking us
    [ -f "${HEARTBEAT:-/dev/null}" ] && date +%s > "$HEARTBEAT"

    local ci_status
    ci_status=$(cloud-init status 2>/dev/null | grep -oP 'status: \K\w+' || echo "not-found")

    if [ "$ci_status" != "done" ] && [ "$ci_status" != "running" ]; then
        log "cloud-init did not run (status=$ci_status)"
        return 1
    fi

    # Check for user-data with meaningful content
    local user_data="${BOOT_FIRMWARE}/user-data"
    if [ ! -f "$user_data" ]; then
        # Check cloud-init instance dir (Proxmox NoCloud drive)
        user_data="/var/lib/cloud/instance/user-data.txt"
        if [ ! -f "$user_data" ]; then
            log "No cloud-init user-data found"
            return 1
        fi
    fi

    # Check if user-data has content beyond the default #cloud-config header
    local line_count
    line_count=$(grep -cve '^\s*$' "$user_data" 2>/dev/null || echo "0")
    if [ "$line_count" -le 1 ]; then
        log "user-data appears to be default/empty ($line_count non-blank lines)"
        return 1
    fi

    log "cloud-init detected with user-data ($line_count lines). Parsing..."

    # Parse everything with python3 (cloud-init guarantees python3-yaml)
    local parsed
    parsed=$(python3 -c "
import yaml, json, sys

result = {
    'hostname': '',
    'timezone': '',
    'ssh_pwauth': 'true',
    'users': [],
    'wifi_ssid': '',
    'wifi_password': '',
    'wifi_country': ''
}

# Parse user-data
try:
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        data = {}

    result['hostname'] = data.get('hostname', '')
    result['timezone'] = data.get('timezone', '')
    result['ssh_pwauth'] = str(data.get('ssh_pwauth', True)).lower()

    # Parse users
    users = data.get('users', [])
    for u in users:
        if isinstance(u, dict) and u.get('name'):
            entry = {
                'name': u['name'],
                'has_password': bool(u.get('plain_text_passwd') or u.get('hashed_passwd') or u.get('passwd')),
                'ssh_keys': u.get('ssh_authorized_keys', u.get('ssh-authorized-keys', [])),
                'groups': [g.strip() for g in u.get('groups', '').split(',') if g.strip()] if isinstance(u.get('groups'), str) else u.get('groups', [])
            }
            result['users'].append(entry)
except Exception as e:
    print(f'WARN: user-data parse error: {e}', file=sys.stderr)

# Parse network-config for WiFi credentials
network_config = sys.argv[2] if len(sys.argv) > 2 else ''
if network_config:
    try:
        with open(network_config) as f:
            netdata = yaml.safe_load(f)
        wifis = netdata.get('network', {}).get('wifis', {})
        for iface, config in wifis.items():
            aps = config.get('access-points', {})
            for ssid, ap_config in aps.items():
                result['wifi_ssid'] = ssid
                if ap_config and 'password' in ap_config:
                    result['wifi_password'] = ap_config['password']
                break
            break
    except Exception as e:
        print(f'WARN: network-config parse error: {e}', file=sys.stderr)

# Check meta-data for hostname if not in user-data
if not result['hostname']:
    meta_data = sys.argv[3] if len(sys.argv) > 3 else ''
    if meta_data:
        try:
            with open(meta_data) as f:
                meta = yaml.safe_load(f)
            if isinstance(meta, dict):
                result['hostname'] = meta.get('local-hostname', '')
        except:
            pass

# Also try cloud-init query for hostname
if not result['hostname']:
    import subprocess
    try:
        h = subprocess.check_output(['cloud-init', 'query', 'local-hostname'],
                                     stderr=subprocess.DEVNULL, timeout=5).decode().strip()
        if h and h != 'cubeos':
            result['hostname'] = h
    except:
        pass

print(json.dumps(result))
" "$user_data" \
  "${BOOT_FIRMWARE}/network-config" \
  "${BOOT_FIRMWARE}/meta-data" 2>/dev/null || echo "{}")

    if [ "$parsed" = "{}" ]; then
        log_warn "cloud-init parsing returned empty result"
        return 1
    fi

    local hostname timezone ssh_pwauth users_json wifi_ssid wifi_password wifi_country
    hostname=$(echo "$parsed" | jq -r '.hostname // ""')
    timezone=$(echo "$parsed" | jq -r '.timezone // ""')
    ssh_pwauth=$(echo "$parsed" | jq -r '.ssh_pwauth // "true"')
    users_json=$(echo "$parsed" | jq -c '.users // []')
    wifi_ssid=$(echo "$parsed" | jq -r '.wifi_ssid // ""')
    wifi_password=$(echo "$parsed" | jq -r '.wifi_password // ""')
    wifi_country=$(echo "$parsed" | jq -r '.wifi_country // ""')

    if [ -n "$wifi_ssid" ]; then
        log "WiFi configuration found: SSID=$wifi_ssid"
    fi

    write_preconfig_json "cloud-init" \
        "$hostname" "$timezone" "" "" \
        "$wifi_ssid" "$wifi_password" "$wifi_country" "false" \
        "$users_json" "true" "$ssh_pwauth"
    return 0
}

# --- Detector 2: Armbian Firstrun ---
detect_armbian() {
    local firstrun_file="/root/.not_logged_in_yet"
    log "Checking for Armbian firstrun config..."

    if [ ! -f "$firstrun_file" ]; then
        log "No Armbian firstrun file at $firstrun_file"
        return 1
    fi

    # Check for FR_ directives (Armbian's config format)
    if ! grep -q "^FR_" "$firstrun_file" 2>/dev/null; then
        log "Armbian firstrun file exists but has no FR_ directives"
        return 1
    fi

    log "Armbian firstrun config detected. Parsing..."

    local wifi_ssid="" wifi_password="" wifi_country="" timezone="" hostname=""

    wifi_ssid=$(grep -oP "^FR_net_wifi_ssid='?\K[^']*" "$firstrun_file" 2>/dev/null || echo "")
    wifi_password=$(grep -oP "^FR_net_wifi_key='?\K[^']*" "$firstrun_file" 2>/dev/null || echo "")
    wifi_country=$(grep -oP "^FR_net_wifi_countrycode='?\K[^']*" "$firstrun_file" 2>/dev/null || echo "")
    timezone=$(grep -oP "^FR_general_timezone='?\K[^']*" "$firstrun_file" 2>/dev/null || echo "")

    write_preconfig_json "armbian" \
        "$hostname" "$timezone" "" "" \
        "$wifi_ssid" "$wifi_password" "$wifi_country" "false" \
        "[]" "true" "true"
    return 0
}

# --- Detector 3: custom.toml ---
detect_custom_toml() {
    local toml_file="${BOOT_FIRMWARE}/custom.toml"
    log "Checking for custom.toml..."

    if [ ! -f "$toml_file" ]; then
        log "No custom.toml at $toml_file"
        return 1
    fi

    log "custom.toml detected. Parsing..."

    # Parse with Python tomllib (stdlib in Python 3.11+, Ubuntu 24.04 ships 3.12)
    local parsed
    parsed=$(python3 -c "
import tomllib, json, sys
try:
    with open(sys.argv[1], 'rb') as f:
        data = tomllib.load(f)
    result = {
        'hostname': data.get('system', {}).get('hostname', ''),
        'timezone': data.get('locale', {}).get('timezone', ''),
        'keyboard': data.get('locale', {}).get('keymap', ''),
        'username': data.get('user', {}).get('name', ''),
        'has_password': bool(data.get('user', {}).get('password', '')),
        'ssh_enabled': data.get('ssh', {}).get('enabled', True),
        'ssh_keys': data.get('ssh', {}).get('authorized_keys', []),
        'wifi_ssid': data.get('wlan', {}).get('ssid', ''),
        'wifi_password': data.get('wlan', {}).get('password', ''),
        'wifi_country': data.get('wlan', {}).get('country', ''),
    }
    print(json.dumps(result))
except Exception as e:
    print('{}', file=sys.stdout)
    print(f'WARN: Failed to parse custom.toml: {e}', file=sys.stderr)
" "$toml_file" 2>/dev/null || echo "{}")

    if [ "$parsed" = "{}" ]; then
        log_warn "custom.toml parsing failed"
        return 1
    fi

    local hostname timezone keyboard wifi_ssid wifi_password wifi_country username has_password ssh_keys
    hostname=$(echo "$parsed" | jq -r '.hostname // ""')
    timezone=$(echo "$parsed" | jq -r '.timezone // ""')
    keyboard=$(echo "$parsed" | jq -r '.keyboard // ""')
    wifi_ssid=$(echo "$parsed" | jq -r '.wifi_ssid // ""')
    wifi_password=$(echo "$parsed" | jq -r '.wifi_password // ""')
    wifi_country=$(echo "$parsed" | jq -r '.wifi_country // ""')
    username=$(echo "$parsed" | jq -r '.username // ""')
    has_password=$(echo "$parsed" | jq -r '.has_password // false')
    ssh_keys=$(echo "$parsed" | jq -c '.ssh_keys // []')

    local users_json="[]"
    if [ -n "$username" ]; then
        users_json=$(jq -n --arg name "$username" --argjson hp "$has_password" --argjson keys "$ssh_keys" \
            '[{"name": $name, "has_password": $hp, "ssh_keys": $keys, "groups": ["sudo"]}]')
    fi

    write_preconfig_json "custom-toml" \
        "$hostname" "$timezone" "" "$keyboard" \
        "$wifi_ssid" "$wifi_password" "$wifi_country" "false" \
        "$users_json" "true" "true"

    # Rename to prevent re-processing
    mv "$toml_file" "${toml_file}.cubeos-processed" 2>/dev/null || true
    log "Renamed custom.toml -> custom.toml.cubeos-processed"
    return 0
}

# --- Detector 4: LXC Container ---
detect_lxc() {
    log "Checking for LXC container environment..."

    local virt_type
    virt_type=$(systemd-detect-virt 2>/dev/null || echo "none")

    if [ "$virt_type" != "lxc" ]; then
        log "Not in an LXC container (virt=$virt_type)"
        return 1
    fi

    log "LXC container detected. Reading container config..."

    local hostname
    hostname=$(cat /etc/hostname 2>/dev/null | tr -d '[:space:]')

    # LXC containers don't have WiFi — always eth_client
    local ssh_keys="[]"
    if [ -f /root/.ssh/authorized_keys ]; then
        ssh_keys=$(python3 -c "
import json
keys = []
try:
    with open('/root/.ssh/authorized_keys') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                keys.append(line)
except: pass
print(json.dumps(keys))
" 2>/dev/null || echo "[]")
    fi

    local users_json="[]"
    if [ "$ssh_keys" != "[]" ]; then
        users_json=$(jq -n --argjson keys "$ssh_keys" \
            '[{"name": "root", "has_password": true, "ssh_keys": $keys, "groups": []}]')
    fi

    write_preconfig_json "lxc" \
        "$hostname" "" "" "" \
        "" "" "" "false" \
        "$users_json" "true" "true"
    return 0
}

# --- Main Detection Flow ---
main() {
    log "=== Pre-configuration detection starting ==="

    mkdir -p /cubeos/config

    # Detection priority chain — first match wins
    if detect_cloud_init; then
        log_ok "Pre-configuration source: cloud-init"
        return 0
    fi

    if detect_armbian; then
        log_ok "Pre-configuration source: armbian"
        return 0
    fi

    if detect_custom_toml; then
        log_ok "Pre-configuration source: custom-toml"
        return 0
    fi

    if detect_lxc; then
        log_ok "Pre-configuration source: lxc"
        return 0
    fi

    # No pre-configuration found — write "none" marker
    log "No pre-configuration detected. Using default CubeOS flow."
    write_preconfig_json "none" "" "" "" "" "" "" "" "false" "[]" "true" "true"
    return 1
}

main "$@"
