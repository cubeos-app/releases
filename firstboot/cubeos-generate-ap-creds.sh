#!/bin/bash
# =============================================================================
# cubeos-generate-ap-creds.sh — Generate WiFi AP credentials from MAC
# =============================================================================
# Reads wlan0 MAC address, extracts last 6 hex digits, generates:
#   SSID:  CubeOS-XXYYZZ
#   Key:   cubeos-XXYYZZ
#
# Updates /etc/hostapd/hostapd.conf with the generated values.
# Also writes /cubeos/config/ap.env for other scripts to source.
# =============================================================================
set -euo pipefail

AP_IFACE="${1:-wlan0}"
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
AP_ENV="/cubeos/config/ap.env"

echo "[AP] Generating WiFi AP credentials from ${AP_IFACE} MAC address..."

# ---------------------------------------------------------------------------
# Get MAC address
# ---------------------------------------------------------------------------

# Wait for interface to appear (may take a moment on boot)
for i in $(seq 1 30); do
    if [ -f "/sys/class/net/${AP_IFACE}/address" ]; then
        break
    fi
    echo "[AP] Waiting for ${AP_IFACE}..."
    sleep 1
done

if [ ! -f "/sys/class/net/${AP_IFACE}/address" ]; then
    echo "[AP] ERROR: Interface ${AP_IFACE} not found after 30s!"
    echo "[AP] Using fallback credentials."
    MAC_SUFFIX="000000"
else
    # Read MAC and extract last 3 octets (6 hex chars)
    # MAC format: aa:bb:cc:dd:ee:ff → extract DDEEFF
    MAC=$(cat "/sys/class/net/${AP_IFACE}/address" | tr -d ':' | tr '[:lower:]' '[:upper:]')
    MAC_SUFFIX="${MAC: -6}"
    echo "[AP] MAC address: $(cat /sys/class/net/${AP_IFACE}/address)"
    echo "[AP] Suffix: ${MAC_SUFFIX}"
fi

# ---------------------------------------------------------------------------
# Generate credentials
# ---------------------------------------------------------------------------
AP_SSID="CubeOS-${MAC_SUFFIX}"
AP_KEY="cubeos-${MAC_SUFFIX}"

echo "[AP] SSID: ${AP_SSID}"
echo "[AP] Key:  ${AP_KEY}"

# ---------------------------------------------------------------------------
# Update hostapd.conf
# ---------------------------------------------------------------------------
if [ -f "$HOSTAPD_CONF" ]; then
    echo "[AP] Updating ${HOSTAPD_CONF}..."
    sed -i "s/^ssid=.*/ssid=${AP_SSID}/" "$HOSTAPD_CONF"
    sed -i "s/^wpa_passphrase=.*/wpa_passphrase=${AP_KEY}/" "$HOSTAPD_CONF"
else
    echo "[AP] WARNING: ${HOSTAPD_CONF} not found!"
fi

# ---------------------------------------------------------------------------
# Write AP env file (sourced by other scripts and the API)
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$AP_ENV")"

cat > "$AP_ENV" << EOF
# Auto-generated WiFi AP credentials from MAC ${MAC_SUFFIX}
# Generated at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
CUBEOS_AP_SSID=${AP_SSID}
CUBEOS_AP_KEY=${AP_KEY}
CUBEOS_AP_MAC_SUFFIX=${MAC_SUFFIX}
CUBEOS_AP_INTERFACE=${AP_IFACE}
CUBEOS_AP_CHANNEL=6
EOF

echo "[AP] Credentials written to ${AP_ENV}"
