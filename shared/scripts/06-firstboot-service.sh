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

# B89: Early netplan writer — prevents stale DHCP leases on mode switch
if [ -f "${FIRSTBOOT_SRC}/cubeos-early-netplan.sh" ]; then
    cp "${FIRSTBOOT_SRC}/cubeos-early-netplan.sh" /usr/local/lib/cubeos/cubeos-early-netplan.sh
    chmod +x /usr/local/lib/cubeos/cubeos-early-netplan.sh
    echo "[06]   Installed cubeos-early-netplan.sh → /usr/local/lib/cubeos/"
else
    echo "[06]   WARNING: cubeos-early-netplan.sh not found in ${FIRSTBOOT_SRC}"
fi

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
TimeoutStartSec=600

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
# NOTE: No After=cubeos-init.service here! The timer fires at T+1200s,
# and this service must start REGARDLESS of cubeos-init's state.
# If cubeos-init is stuck in "activating", After= would deadlock.
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/cubeos-boot-watchdog.service << 'BOOT_WD_SVC'
[Unit]
Description=CubeOS Boot Timeout Watchdog

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
    STATUS=$(systemctl show cubeos-init.service --property=ActiveState --value 2>/dev/null || echo "unknown"); \
    echo "cubeos-init state: $STATUS"; \
    if [ "$STATUS" = "active" ] || [ "$STATUS" = "inactive" ]; then \
        echo "cubeos-init completed (state=$STATUS) — nothing to do"; \
        exit 0; \
    fi; \
    if [ "$STATUS" = "activating" ]; then \
        echo "cubeos-init stuck in activating state for 20min — killing"; \
        systemctl kill cubeos-init.service 2>/dev/null; \
        systemctl reset-failed cubeos-init.service 2>/dev/null; \
        echo "Attempting recovery: cubeos-normal-boot.sh"; \
        /usr/local/bin/cubeos-normal-boot.sh 2>/dev/null || true; \
    fi; \
    if [ "$STATUS" = "failed" ]; then \
        echo "cubeos-init failed — attempting recovery"; \
        systemctl reset-failed cubeos-init.service 2>/dev/null; \
        /usr/local/bin/cubeos-normal-boot.sh 2>/dev/null || true; \
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
# cubeos-early-netplan.service — write correct netplan before networkd starts
# ---------------------------------------------------------------------------
# B89: Prevents stale DHCP leases when user switches network modes.
# Reads persisted mode from SQLite, writes the matching netplan YAML.
# Runs BEFORE systemd-networkd so it picks up the correct config.
# On fresh install (no DB), exits silently — baked-in OFFLINE netplan is used.
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/cubeos-early-netplan.service << 'EARLY_NP_SVC'
[Unit]
Description=CubeOS Early Netplan Writer (B89)
Documentation=https://github.com/cubeos-app
DefaultDependencies=no
After=local-fs.target
Before=systemd-networkd.service systemd-networkd-wait-online.service
ConditionPathExists=/cubeos/data/cubeos.db

[Service]
Type=oneshot
ExecStart=/usr/local/lib/cubeos/cubeos-early-netplan.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
TimeoutStartSec=10

[Install]
WantedBy=sysinit.target
EARLY_NP_SVC

# ---------------------------------------------------------------------------
# Enable services
# ---------------------------------------------------------------------------
systemctl enable cubeos-init.service 2>/dev/null || true
systemctl enable cubeos-early-netplan.service 2>/dev/null || true
# Watchdog timer is started by first-boot script AFTER all services are deployed.
# DO NOT enable here — it would run during first boot and waste I/O.
# systemctl enable cubeos-watchdog.timer 2>/dev/null || true
systemctl enable cubeos-boot-watchdog.timer 2>/dev/null || true

echo "[06] First-boot service installed (timeout=600s, dead man's switch built-in)."
echo "[06] Watchdog: /cubeos/coreapps/scripts/watchdog-health.sh (starts at T+120s, every 60s)."
echo "[06] Boot watchdog: kills cubeos-init if stuck >20 minutes."
echo "[06] Early netplan: writes correct netplan before networkd (B89)."
echo "[06] Recovery: /usr/local/bin/cubeos-deploy-stacks.sh"
