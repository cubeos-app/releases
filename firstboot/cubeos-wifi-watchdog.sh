#!/usr/bin/env bash
# cubeos-wifi-watchdog.sh -- Monitor WiFi client connectivity
# Reverts to offline_hotspot after 5 consecutive failures.
# Installed as systemd timer (every 60s) by 02-networking.sh.

set -euo pipefail

FAIL_COUNT_FILE="/cubeos/data/wifi-watchdog-failures"
MAX_FAILURES=5
DB="/cubeos/data/cubeos.db"

# Only run in wifi_client mode
CURRENT_MODE=$(sqlite3 "$DB" "SELECT mode FROM network_config WHERE id=1;" 2>/dev/null || echo "unknown")
if [ "$CURRENT_MODE" != "wifi_client" ]; then
    # Reset failure count and exit
    rm -f "$FAIL_COUNT_FILE"
    exit 0
fi

# Check connectivity: wlan0 has IP + can ping gateway
WLAN_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "")
GATEWAY=$(ip route show default 2>/dev/null | grep -oP 'via \K[\d.]+' | head -1 || echo "")

if [ -n "$WLAN_IP" ] && [ -n "$GATEWAY" ] && ping -c 1 -W 3 "$GATEWAY" &>/dev/null; then
    # Success -- reset failure count
    rm -f "$FAIL_COUNT_FILE"
    exit 0
fi

# Failure -- increment counter
FAILURES=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo "0")
FAILURES=$((FAILURES + 1))
echo "$FAILURES" > "$FAIL_COUNT_FILE"

logger -t cubeos-wifi-watchdog "WiFi connectivity check failed ($FAILURES/$MAX_FAILURES)"

if [ "$FAILURES" -ge "$MAX_FAILURES" ]; then
    logger -t cubeos-wifi-watchdog "REVERTING to offline_hotspot after $MAX_FAILURES consecutive failures"

    # Revert to AP mode
    systemctl stop wpa_supplicant 2>/dev/null || true
    ip addr flush dev wlan0 2>/dev/null || true

    # Write offline_hotspot netplan
    cat > /etc/netplan/01-cubeos.yaml << 'NETPLAN'
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
      optional: true
    wlan0:
      addresses:
        - 10.42.24.1/24
      optional: true
NETPLAN

    netplan apply 2>/dev/null || true
    systemctl start hostapd 2>/dev/null || true

    # Stop avahi (not needed in AP mode)
    systemctl stop avahi-daemon 2>/dev/null || true

    # Update database
    sqlite3 "$DB" "UPDATE network_config SET mode='offline_hotspot' WHERE id=1;" 2>/dev/null || true

    # Reset failure count
    rm -f "$FAIL_COUNT_FILE"

    logger -t cubeos-wifi-watchdog "Reverted to offline_hotspot -- AP should be active"
fi
