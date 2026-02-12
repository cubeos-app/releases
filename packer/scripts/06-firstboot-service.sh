#!/bin/bash
# =============================================================================
# 06-firstboot-service.sh — Install CubeOS boot orchestration systemd service
# =============================================================================
# Creates cubeos-init.service which detects first-boot vs normal-boot
# and runs the appropriate script.
#
# TIMEOUT NOTES:
#   - cubeos-docker-preload: infinity (npm 1.1GB can take 8+ min on 2GB Pi)
#   - cubeos-init (first boot): infinity (deploys 5 services sequentially)
#   - cubeos-init (normal boot): 300s (just verifies, no heavy loading)
#
# v2: Watchdog health script is now a standalone file (firstboot/watchdog-health.sh)
#     instead of an inline heredoc, so fixes only need one edit.
#     Also installs cubeos-deploy-stacks.sh for manual recovery.
# =============================================================================
set -euo pipefail

echo "=== [06] First-Boot Service Installation ==="

# ---------------------------------------------------------------------------
# Install new scripts that 04-cubeos.sh doesn't handle yet
# Source: Packer copies firstboot/ → /tmp/cubeos-firstboot/
# ---------------------------------------------------------------------------
FIRSTBOOT_SRC="/tmp/cubeos-firstboot"

echo "[06] Installing additional scripts..."

# Manual stack recovery helper (new in v2)
if [ -f "${FIRSTBOOT_SRC}/cubeos-deploy-stacks.sh" ]; then
    cp "${FIRSTBOOT_SRC}/cubeos-deploy-stacks.sh" /usr/local/bin/cubeos-deploy-stacks.sh
    chmod +x /usr/local/bin/cubeos-deploy-stacks.sh
    echo "[06]   Installed cubeos-deploy-stacks.sh → /usr/local/bin/"
else
    echo "[06]   WARNING: cubeos-deploy-stacks.sh not found in ${FIRSTBOOT_SRC}"
fi

# Watchdog health check script (was inline heredoc in v1, now standalone file)
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
# can take 10-15 minutes total. Killing mid-deploy leaves the system in a
# worse state than just letting it finish.
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
cat > /etc/systemd/system/cubeos-watchdog.service << 'WATCHDOG_SVC'
[Unit]
Description=CubeOS Watchdog Health Check
After=cubeos-init.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/cubeos/watchdog-health.sh
WATCHDOG_SVC

cat > /etc/systemd/system/cubeos-watchdog.timer << 'WATCHDOG_TMR'
[Unit]
Description=CubeOS Watchdog Timer
After=cubeos-init.service

[Timer]
OnBootSec=120
OnUnitActiveSec=60
AccuracySec=10

[Install]
WantedBy=timers.target
WATCHDOG_TMR

# ---------------------------------------------------------------------------
# Enable services
# ---------------------------------------------------------------------------
systemctl enable cubeos-init.service 2>/dev/null || true
systemctl enable cubeos-watchdog.timer 2>/dev/null || true

echo "[06] First-boot service installed (timeout=infinity for first-boot resilience)."
echo "[06] Watchdog: /usr/local/lib/cubeos/watchdog-health.sh"
echo "[06] Recovery: /usr/local/bin/cubeos-deploy-stacks.sh"
