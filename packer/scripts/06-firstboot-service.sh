#!/bin/bash
# =============================================================================
# 06-firstboot-service.sh — Install CubeOS boot orchestration systemd service
# =============================================================================
# Creates cubeos-init.service which detects first-boot vs normal-boot
# and runs the appropriate script.
#
# v3 — VOYAGER EDITION:
#   - Watchdog timer starts INDEPENDENTLY (not After=cubeos-init.service)
#     so it can heal services even if first-boot hangs
#   - cubeos-init uses StandardOutput=journal (no tee needed)
#   - Boot scripts handle their own logging to file
# =============================================================================
set -euo pipefail

echo "=== [06] First-Boot Service Installation ==="

# ---------------------------------------------------------------------------
# Install new scripts that 04-cubeos.sh doesn't handle yet
# Source: Packer copies firstboot/ → /tmp/cubeos-firstboot/
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

# Watchdog health check script
mkdir -p /usr/local/lib/cubeos

if [ -f "${FIRSTBOOT_SRC}/watchdog-health.sh" ]; then
    cp "${FIRSTBOOT_SRC}/watchdog-health.sh" /usr/local/lib/cubeos/watchdog-health.sh
    chmod +x /usr/local/lib/cubeos/watchdog-health.sh
    echo "[06]   Installed watchdog-health.sh → /usr/local/lib/cubeos/"
else
    echo "[06]   ERROR: watchdog-health.sh not found in ${FIRSTBOOT_SRC}!"
    exit 1
fi

# ---------------------------------------------------------------------------
# cubeos-init.service — main boot orchestrator
# ---------------------------------------------------------------------------
# TimeoutStartSec=infinity because first-boot on a 2GB Pi with SD card
# can take 10-15 minutes total. The boot script has its own internal
# dead man's switch (background watchdog) that handles hangs.
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
# CRITICAL: This timer starts INDEPENDENTLY of cubeos-init.service.
# It must NOT have After=cubeos-init.service — otherwise it can't heal
# services if cubeos-init is hung. The OnBootSec=90 gives Docker time
# to start, then the watchdog begins checking every 60s regardless of
# whether first-boot has finished.
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/cubeos-watchdog.service << 'WATCHDOG_SVC'
[Unit]
Description=CubeOS Watchdog Health Check
# NO dependency on cubeos-init — must run even if init hangs
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/cubeos/watchdog-health.sh
TimeoutStartSec=120
WATCHDOG_SVC

cat > /etc/systemd/system/cubeos-watchdog.timer << 'WATCHDOG_TMR'
[Unit]
Description=CubeOS Watchdog Timer
# NO dependency on cubeos-init — starts independently on boot

[Timer]
# Start 90s after boot (Docker needs ~20s, preload needs ~60s)
OnBootSec=90
# Then run every 60s
OnUnitActiveSec=60
AccuracySec=10

[Install]
WantedBy=timers.target
WATCHDOG_TMR

# ---------------------------------------------------------------------------
# cubeos-boot-watchdog.service — one-shot zombie process cleaner
# ---------------------------------------------------------------------------
# Safety net: If cubeos-init.service has been "activating" for more than
# 20 minutes, something is catastrophically wrong. Kill it and let the
# watchdog timer handle recovery.
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
# Run once, 20 minutes after boot
OnBootSec=1200
# One-shot, no repeat
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
echo "[06] Watchdog: starts at T+90s independently of boot (every 60s)."
echo "[06] Boot watchdog: kills cubeos-init if stuck >20 minutes."
echo "[06] Recovery: /usr/local/bin/cubeos-deploy-stacks.sh"
