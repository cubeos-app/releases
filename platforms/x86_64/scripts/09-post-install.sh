#!/bin/bash
# =============================================================================
# 09-post-install.sh — x86_64 post-install (GRUB, serial console, cloud-init)
# =============================================================================
# x86-specific post-install steps. This is the x86 equivalent of the Pi's
# 09-console-gui.sh (which installs the whiptail TUI on tty1).
#
# On x86:
#   - Configure GRUB for serial console (headless server support)
#   - Disable cloud-init after first boot (prevents air-gap timeout delays)
#   - Set CubeOS tier marker
#   - No console TUI (x86 uses SSH, not HDMI)
# =============================================================================
set -euo pipefail

echo "=== [09] x86_64 Post-Install ==="

# ---------------------------------------------------------------------------
# GRUB — serial console for headless servers
# ---------------------------------------------------------------------------
# Many x86 CubeOS targets (Intel NUCs, server VMs) run headless.
# Serial console allows access via QEMU -nographic, IPMI SOL, or serial cable.
# Both tty0 (VGA) and ttyS0 (serial) receive output — works with or without
# a monitor attached.
# ---------------------------------------------------------------------------
echo "[09] Configuring GRUB for serial console..."

if [ -f /etc/default/grub ]; then
    # Add serial console alongside VGA
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200n8"/' /etc/default/grub

    # Enable both console and serial terminal
    if grep -q '^GRUB_TERMINAL=' /etc/default/grub; then
        sed -i 's/^GRUB_TERMINAL=.*/GRUB_TERMINAL="console serial"/' /etc/default/grub
    elif grep -q '^#GRUB_TERMINAL=' /etc/default/grub; then
        sed -i 's/^#GRUB_TERMINAL=.*/GRUB_TERMINAL="console serial"/' /etc/default/grub
    else
        echo 'GRUB_TERMINAL="console serial"' >> /etc/default/grub
    fi

    # Serial port configuration
    if ! grep -q '^GRUB_SERIAL_COMMAND=' /etc/default/grub; then
        echo 'GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"' >> /etc/default/grub
    fi

    # Reduce GRUB timeout for faster boot (default 10s is too long for servers)
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub

    # Regenerate GRUB config
    update-grub 2>/dev/null || true
    echo "[09]   GRUB configured: serial console (ttyS0@115200) + VGA (tty0), timeout=3s"
else
    echo "[09]   WARNING: /etc/default/grub not found — skipping GRUB config"
fi

# ---------------------------------------------------------------------------
# Serial getty — enable login on serial console
# ---------------------------------------------------------------------------
echo "[09] Enabling serial console getty (ttyS0)..."
systemctl enable serial-getty@ttyS0.service 2>/dev/null || true
echo "[09]   serial-getty@ttyS0 enabled"

# ---------------------------------------------------------------------------
# Disable cloud-init after first boot
# ---------------------------------------------------------------------------
# On air-gapped x86 servers, cloud-init's NoCloud datasource check on every
# boot adds a 120s timeout delay. Disable it after provisioning is complete.
# ---------------------------------------------------------------------------
echo "[09] Disabling cloud-init for subsequent boots..."
touch /etc/cloud/cloud-init.disabled
echo "[09]   cloud-init disabled (touch /etc/cloud/cloud-init.disabled)"

# ---------------------------------------------------------------------------
# CubeOS tier marker
# ---------------------------------------------------------------------------
# x86 images are always Tier 1 (full) — they own the entire host.
# This env var is read by firstboot scripts and the API.
# ---------------------------------------------------------------------------
echo "[09] Setting CubeOS tier marker..."
if ! grep -q '^CUBEOS_TIER=' /etc/environment 2>/dev/null; then
    echo "CUBEOS_TIER=full" >> /etc/environment
fi
echo "[09]   CUBEOS_TIER=full written to /etc/environment"

# ---------------------------------------------------------------------------
# x86-specific: mark platform
# ---------------------------------------------------------------------------
echo "[09] Setting platform marker..."
if ! grep -q '^CUBEOS_PLATFORM=' /etc/environment 2>/dev/null; then
    echo "CUBEOS_PLATFORM=x86_64" >> /etc/environment
fi
echo "[09]   CUBEOS_PLATFORM=x86_64 written to /etc/environment"

echo "=== [09] x86_64 Post-Install: DONE ==="
