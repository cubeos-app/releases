#!/bin/bash
# =============================================================================
# 06-firstboot-service.sh — Install CubeOS boot orchestration systemd service
# =============================================================================
# Creates cubeos-init.service which detects first-boot vs normal-boot
# and runs the appropriate script.
#
# v4 — ALPHA.6:
#   - Watchdog runs from /cubeos/coreapps/scripts/ (matching Pi 5)
#   - Fallback to /usr/local/lib/cubeos/ for backward compat
#   - Timer starts INDEPENDENTLY of cubeos-init (can heal during first-boot)
# =============================================================================
set -euo pipefail

echo "=== [06] First-Boot Service Installation (alpha.6) ==="

# ---------------------------------------------------------------------------
# Install scripts that 04-cubeos.sh doesn't handle
# ---------------------------------------------------------------------------
FIRSTBOOT_SRC="/tmp/cubeos-firstboot"

echo "[06] Installing additional scripts..."

# Manual stack recovery helper
if [ -f "${FIRSTBOOT_SRC}/cubeos-deploy-stacks.sh" ]; then
    cp "${FIRSTBOOT_SRC}/cubeos-deploy-stacks.sh" /usr/local/bin/cubeos-deploy-stacks.sh
    chmod +x /usr/local/bin/cubeos-deploy-stacks.sh
    echo "[06]   Installed cubeos-deploy-stacks.sh → /usr/local/bin/"
else
    echo "[06]   WARNING: cubeos-deploy-stacks.sh not found in ${FIRSTBOOT_SRC}"
fi

# Watchdog health check — install to BOTH locations:
# 1. /cubeos/coreapps/scripts/ (Pi 5 production path, preferred)
# 2. /usr/local/lib/cubeos/ (backward compat fallback)
mkdir -p /cubeos/coreapps/scripts
mkdir -p /usr/local/lib/cubeos

if [ -f "${FIRSTBOOT_SRC}/watchdog-health.sh" ]; then
    cp "${FIRSTBOOT_SRC}/watchdog-health.sh" /cubeos/coreapps/scripts/watchdog-health.sh
    chmod +x /cubeos/coreapps/scripts/watchdog-health.sh
    # Symlink for backward compat
    ln -sf /cubeos/coreapps/scripts/watchdog-health.sh /usr/local/lib/cubeos/watchdog-health.sh
    echo "[06]   Installed watchdog-health.sh → /cubeos/coreapps/scripts/"
else
    echo "[06]   ERROR: watchdog-health.sh not found in ${FIRSTBOOT_SRC}!"
    exit 1
fi

# ---------------------------------------------------------------------------
# cubeos-init.service — main boot orchestrator
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/cubeos-init.service << 'SYSTEMD'
[Unit]
Description=CubeOS System Initialization
Documentation=https://github.com/cubeos-app
After=docker.service cubeos-docker-preload.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
    BOOT_MODE=$(/usr/local/bin/cubeos-boot-detect.sh); \
    echo "CubeOS boot mode: $BOOT_MODE"; \
    if [ "$BOOT_MODE" = "first-boot" ]; then \
        /usr/local/bin/cubeos-first-boot.sh; \
    else \
        /usr/local/bin/cubeos-normal-boot.sh; \
    fi'
StandardOutput=journal
StandardError=journal
TimeoutStartSec=infinity

[Install]
WantedBy=multi-user.target
SYSTEMD

# ---------------------------------------------------------------------------
# cubeos-watchdog.service — periodic health checks
# ---------------------------------------------------------------------------
# Uses /cubeos/coreapps/scripts/ path (matching Pi 5 production).
# Timer starts INDEPENDENTLY — must NOT have After=cubeos-init.service.
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/cubeos-watchdog.service << 'WATCHDOG_SVC'
[Unit]
Description=CubeOS Watchdog Health Check
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/cubeos/coreapps/scripts/watchdog-health.sh
TimeoutStartSec=120
WATCHDOG_SVC

cat > /etc/systemd/system/cubeos-watchdog.timer << 'WATCHDOG_TMR'
[Unit]
Description=CubeOS Watchdog Timer

[Timer]
OnBootSec=120
OnUnitActiveSec=60
AccuracySec=10

[Install]
WantedBy=timers.target
WATCHDOG_TMR

# ---------------------------------------------------------------------------
# cubeos-boot-watchdog — kills hung cubeos-init after 20 minutes
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/cubeos-boot-watchdog.service << 'BOOT_WD_SVC'
[Unit]
Description=CubeOS Boot Timeout Watchdog
After=cubeos-init.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
    sleep 1200; \
    if systemctl is-active --quiet cubeos-init.service 2>/dev/null; then \
        echo "cubeos-init completed normally"; \
        exit 0; \
    fi; \
    STATUS=$(systemctl show cubeos-init.service --property=ActiveState --value 2>/dev/null); \
    if [ "$STATUS" = "activating" ]; then \
        echo "cubeos-init stuck in activating state for 20min — killing"; \
        systemctl kill cubeos-init.service 2>/dev/null; \
        systemctl reset-failed cubeos-init.service 2>/dev/null; \
    fi'
StandardOutput=journal
StandardError=journal
BOOT_WD_SVC

cat > /etc/systemd/system/cubeos-boot-watchdog.timer << 'BOOT_WD_TMR'
[Unit]
Description=CubeOS Boot Timeout Watchdog Timer

[Timer]
OnBootSec=1200
Persistent=false

[Install]
WantedBy=timers.target
BOOT_WD_TMR

# ---------------------------------------------------------------------------
# Enable services
# ---------------------------------------------------------------------------
systemctl enable cubeos-init.service 2>/dev/null || true
systemctl enable cubeos-watchdog.timer 2>/dev/null || true
systemctl enable cubeos-boot-watchdog.timer 2>/dev/null || true

echo "[06] First-boot service installed (timeout=infinity, dead man's switch built-in)."
echo "[06] Watchdog: /cubeos/coreapps/scripts/watchdog-health.sh (starts at T+120s, every 60s)."
echo "[06] Boot watchdog: kills cubeos-init if stuck >20 minutes."
echo "[06] Recovery: /usr/local/bin/cubeos-deploy-stacks.sh"
