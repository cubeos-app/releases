#!/bin/bash
# =============================================================================
# cubeos-diagnose.sh — CubeOS System Diagnostics (read-only)
# =============================================================================
# Non-destructive diagnostic tool for troubleshooting CubeOS installations.
# Safe to run at any time — performs no writes, restarts, or modifications.
#
# Usage: cubeos-diagnose.sh [--json]
# =============================================================================
set -uo pipefail

JSON_OUTPUT=false
[ "${1:-}" = "--json" ] && JSON_OUTPUT=true

# ── Helpers ───────────────────────────────────────────────────────────
section() { echo ""; echo "=== $1 ==="; }
ok()      { echo "  OK:   $*"; }
warn()    { echo "  WARN: $*"; }
fail()    { echo "  FAIL: $*"; }
info()    { echo "  $*"; }

# =============================================================================
echo "============================================================"
echo "  CubeOS Diagnostics"
echo "  $(date)"
echo "============================================================"

# ── Version ───────────────────────────────────────────────────────────
section "Version"
if [ -f /cubeos/config/defaults.env ]; then
    source /cubeos/config/defaults.env 2>/dev/null
    ok "CubeOS ${CUBEOS_VERSION:-unknown}"
else
    fail "defaults.env not found"
fi

# ── System ────────────────────────────────────────────────────────────
section "System"
info "Hostname:  $(hostname)"
info "Uptime:    $(uptime -p 2>/dev/null || uptime)"
info "Kernel:    $(uname -r)"
info "Arch:      $(uname -m)"

if [ -f /proc/device-tree/model ]; then
    info "Hardware:  $(tr -d '\0' < /proc/device-tree/model)"
fi

# ── Memory ────────────────────────────────────────────────────────────
section "Memory"
free -h 2>/dev/null | grep -E "^(Mem|Swap):" | while read -r line; do
    info "$line"
done

if swapon --show 2>/dev/null | grep -q zram; then
    ok "ZRAM swap active"
else
    warn "ZRAM swap not detected"
fi

# ── Disk ──────────────────────────────────────────────────────────────
section "Disk"
df -h / /cubeos 2>/dev/null | tail -n +2 | while read -r line; do
    info "$line"
done

USAGE_PCT=$(df / 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
if [ -n "$USAGE_PCT" ] && [ "$USAGE_PCT" -gt 90 ]; then
    warn "Root filesystem usage above 90% (${USAGE_PCT}%)"
elif [ -n "$USAGE_PCT" ]; then
    ok "Root filesystem usage: ${USAGE_PCT}%"
fi

if [ -d /var/lib/docker ]; then
    info "Docker:    $(du -sh /var/lib/docker 2>/dev/null | cut -f1)"
fi

# ── Network ───────────────────────────────────────────────────────────
section "Network"
# wlan0
if ip link show wlan0 &>/dev/null; then
    WLAN_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oP 'inet \K[\d.]+')
    if [ -n "$WLAN_IP" ]; then
        ok "wlan0: ${WLAN_IP}"
    else
        warn "wlan0: UP but no IP"
    fi
else
    fail "wlan0: not found"
fi

# eth0
if ip link show eth0 &>/dev/null; then
    ETH_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[\d.]+')
    if [ -n "$ETH_IP" ]; then
        ok "eth0: ${ETH_IP}"
    else
        info "eth0: no IP (OFFLINE mode or cable unplugged)"
    fi
fi

# WiFi AP
if iw dev wlan0 info 2>/dev/null | grep -q "type AP"; then
    SSID=$(iw dev wlan0 info 2>/dev/null | grep ssid | awk '{print $2}')
    ok "WiFi AP broadcasting: ${SSID:-unknown}"
else
    warn "WiFi AP not broadcasting"
fi

# DNS
if dig cubeos.cube @127.0.0.1 +short +time=2 +tries=1 &>/dev/null; then
    ok "DNS resolution: cubeos.cube resolves"
else
    warn "DNS resolution: cubeos.cube not resolving (Pi-hole down?)"
fi

# ── Docker ────────────────────────────────────────────────────────────
section "Docker"
if docker info &>/dev/null; then
    ok "Docker daemon running"
    DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
    info "Version:   ${DOCKER_VER:-unknown}"
else
    fail "Docker daemon not running"
fi

# Swarm
if docker info 2>/dev/null | grep -q "Swarm: active"; then
    ok "Swarm: active"
    NODES=$(docker node ls --format '{{.Status}}' 2>/dev/null | grep -c Ready)
    info "Nodes:     ${NODES} ready"
else
    warn "Swarm: not active"
fi

# ── Compose Services ─────────────────────────────────────────────────
section "Compose Services (host network)"
for svc in pihole npm cubeos-hal; do
    CONTAINER="cubeos-${svc}"
    if docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
        ok "${svc}: running"
    else
        fail "${svc}: not running"
    fi
done

# ── Swarm Stacks ─────────────────────────────────────────────────────
section "Swarm Stacks"
if docker info 2>/dev/null | grep -q "Swarm: active"; then
    EXPECTED_STACKS="registry cubeos-api cubeos-dashboard cubeos-docsindex ollama chromadb"
    for stack in $EXPECTED_STACKS; do
        if docker stack ls 2>/dev/null | grep -q "^${stack} "; then
            REPLICAS=$(docker stack services "$stack" --format '{{.Replicas}}' 2>/dev/null | head -1)
            ok "${stack}: deployed (${REPLICAS:-?})"
        else
            fail "${stack}: MISSING"
        fi
    done
else
    warn "Swarm not active — cannot check stacks"
fi

# ── Service Health ────────────────────────────────────────────────────
section "Service Health Checks"

# Pi-hole
if curl -sf http://127.0.0.1:6001/admin/ &>/dev/null; then
    ok "Pi-hole web: responding (port 6001)"
else
    warn "Pi-hole web: not responding"
fi

# API
HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' http://127.0.0.1:6010/health 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    ok "CubeOS API: healthy (port 6010)"
else
    fail "CubeOS API: HTTP ${HTTP_CODE} (port 6010)"
fi

# Dashboard
HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' http://127.0.0.1:6011/ 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    ok "Dashboard: responding (port 6011)"
else
    warn "Dashboard: HTTP ${HTTP_CODE} (port 6011)"
fi

# HAL
HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' http://127.0.0.1:6005/health 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    ok "HAL: healthy (port 6005)"
else
    warn "HAL: HTTP ${HTTP_CODE} (port 6005)"
fi

# NPM
HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' http://127.0.0.1:81/ 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
    ok "NPM: responding (port 81)"
else
    warn "NPM: HTTP ${HTTP_CODE} (port 81)"
fi

# ── Watchdog ──────────────────────────────────────────────────────────
section "Hardware"
if [ -e /dev/watchdog ]; then
    ok "Watchdog: /dev/watchdog present"
else
    info "Watchdog: not available on this hardware"
fi

if [ -e /dev/rtc0 ]; then
    ok "RTC: /dev/rtc0 present"
else
    info "RTC: not available on this hardware"
fi

# Temperature
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    TEMP_RAW=$(cat /sys/class/thermal/thermal_zone0/temp)
    TEMP_C=$(echo "scale=1; ${TEMP_RAW}/1000" | bc 2>/dev/null || echo "${TEMP_RAW}")
    if [ -n "$TEMP_RAW" ] && [ "$TEMP_RAW" -gt 80000 ] 2>/dev/null; then
        warn "CPU temperature: ${TEMP_C}C (HIGH)"
    else
        ok "CPU temperature: ${TEMP_C}C"
    fi
fi

# ── Boot Log ──────────────────────────────────────────────────────────
section "Recent Boot Log"
if [ -f /var/log/cubeos-boot.log ]; then
    info "Last 10 lines of /var/log/cubeos-boot.log:"
    tail -10 /var/log/cubeos-boot.log | while read -r line; do
        info "  $line"
    done
else
    warn "Boot log not found"
fi

# ── Summary ───────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Diagnostics complete"
echo "  Dashboard: http://cubeos.cube  or  http://10.42.24.1"
echo "  Dozzle:    http://dozzle.cubeos.cube  (container logs)"
echo "============================================================"
