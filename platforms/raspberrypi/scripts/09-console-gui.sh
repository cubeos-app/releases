#!/bin/bash
# =============================================================================
# 09-console-gui.sh — Install CubeOS Console TUI + auto-launch on tty1
# =============================================================================
# Task: T22 (Network Modes Batch 5)
#
# Installs the cubeos-console.sh whiptail TUI and configures:
#   1. Script installed to /usr/local/bin/cubeos-console
#   2. getty@tty1 override for autologin as cubeos user
#   3. .bashrc hook to auto-launch console on tty1 (not SSH)
#
# The console provides emergency network recovery when the web dashboard
# is unreachable (wrong static IP, bad WiFi creds, etc.).
#
# SSH sessions are NOT affected — the console only launches on the
# physical HDMI console (tty1).
# =============================================================================
set -euo pipefail

echo "=== [09] Console GUI Installation (Network Modes Batch 5) ==="

# ---------------------------------------------------------------------------
# Install cubeos-console script
# ---------------------------------------------------------------------------
FIRSTBOOT_SRC="/tmp/cubeos-firstboot"

if [ -f "${FIRSTBOOT_SRC}/cubeos-console.sh" ]; then
    cp "${FIRSTBOOT_SRC}/cubeos-console.sh" /usr/local/bin/cubeos-console
    chmod +x /usr/local/bin/cubeos-console
    echo "[09]   Installed cubeos-console -> /usr/local/bin/cubeos-console"
else
    echo "[09]   WARNING: cubeos-console.sh not found in ${FIRSTBOOT_SRC}"
    echo "[09]   Console GUI will not be available."
fi

# ---------------------------------------------------------------------------
# Verify whiptail is available (pre-installed on Ubuntu)
# ---------------------------------------------------------------------------
if command -v whiptail &>/dev/null; then
    echo "[09]   whiptail: OK ($(command -v whiptail))"
else
    echo "[09]   WARNING: whiptail not found — console TUI will not work."
    echo "[09]   Install with: apt-get install whiptail"
fi

# ---------------------------------------------------------------------------
# getty@tty1 override — autologin cubeos user on HDMI console
# ---------------------------------------------------------------------------
# This creates a systemd drop-in that overrides the default getty on tty1
# to autologin as the cubeos user. The .bashrc hook (below) then launches
# the console TUI automatically.
#
# IMPORTANT: This only affects tty1 (HDMI output). Other ttys and SSH
# sessions use normal login.
# ---------------------------------------------------------------------------
echo "[09] Configuring getty@tty1 autologin..."

mkdir -p /etc/systemd/system/getty@tty1.service.d

cat > /etc/systemd/system/getty@tty1.service.d/cubeos-console.conf << 'GETTY_OVERRIDE'
[Service]
# Clear the default ExecStart first (required by systemd for overrides)
ExecStart=
# Autologin as cubeos user on tty1 — .bashrc launches console TUI
ExecStart=-/sbin/agetty --autologin cubeos --noclear %I $TERM
Type=idle
GETTY_OVERRIDE

echo "[09]   Created getty@tty1 autologin override"

# ---------------------------------------------------------------------------
# .bashrc hook — launch console TUI on tty1 only
# ---------------------------------------------------------------------------
# This snippet is appended to the cubeos user's .bashrc. It checks if
# the current terminal is tty1 (HDMI console) and launches the console
# TUI automatically. SSH sessions use pts/* terminals and are unaffected.
#
# The sudo is needed because the console script modifies network config
# (netplan, SQLite, iptables). The cubeos user has passwordless sudo.
# ---------------------------------------------------------------------------
echo "[09] Adding .bashrc console auto-launch hook..."

BASHRC_FILE="/home/cubeos/.bashrc"

# Ensure .bashrc exists
touch "$BASHRC_FILE"

# Only add the hook if it doesn't already exist (idempotent)
if ! grep -q "cubeos-console" "$BASHRC_FILE" 2>/dev/null; then
    cat >> "$BASHRC_FILE" << 'BASHRC_HOOK'

# ---------------------------------------------------------------------------
# CubeOS Console TUI — auto-launch on tty1 (HDMI console only)
# SSH sessions (pts/*) are not affected.
# ---------------------------------------------------------------------------
if [ "$(tty)" = "/dev/tty1" ] && command -v cubeos-console &>/dev/null; then
    sudo /usr/local/bin/cubeos-console
fi
BASHRC_HOOK
    echo "[09]   Added cubeos-console hook to ${BASHRC_FILE}"
else
    echo "[09]   cubeos-console hook already present in ${BASHRC_FILE}"
fi

# Ensure correct ownership
chown cubeos:cubeos "$BASHRC_FILE" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo "[09] Console GUI installation complete."
echo "[09]   - Script: /usr/local/bin/cubeos-console"
echo "[09]   - Auto-launch: tty1 only (HDMI console)"
echo "[09]   - SSH sessions: not affected"
echo "[09]   - Run manually: sudo cubeos-console"
