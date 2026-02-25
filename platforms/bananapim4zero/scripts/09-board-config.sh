#!/bin/bash
# =============================================================================
# BPI-M4 Zero board-specific config — Allwinner H618
# =============================================================================
# Armbian uses armbianEnv.txt (in /boot/) instead of config.txt (Pi) or
# GRUB (x86). This script configures board-specific bootloader settings.
#
# Board: BananaPi BPI-M4 Zero
# SoC:   Allwinner H618 (quad-core Cortex-A53, 1.5GHz)
# Serial console: ttyS0 (Allwinner UART0)
# Storage: 32GB eMMC (/dev/mmcblk1) + microSD (/dev/mmcblk0)
# WiFi: Built-in (RTL8821CS or similar) — not configured for AP yet
#
# TODO: Verify armbianEnv.txt settings on real BPI-M4 Zero hardware
# TODO: Verify eMMC device path (/dev/mmcblk1)
# =============================================================================
set -euo pipefail
echo "=== [09] BPI-M4 Zero Board Configuration (Allwinner H618) ==="

# Armbian bootloader config
if [ -f /boot/armbianEnv.txt ]; then
    # Enable serial console on ttyS0 (Allwinner UART0)
    grep -q '^console=serial' /boot/armbianEnv.txt || \
        echo "console=serial" >> /boot/armbianEnv.txt

    # Set verbosity
    sed -i 's/^verbosity=.*/verbosity=1/' /boot/armbianEnv.txt 2>/dev/null || true
fi

# Disable cloud-init after first boot (prevents air-gap timeout delays)
touch /etc/cloud/cloud-init.disabled

# eMMC detection — BPI-M4 Zero has 32GB eMMC
# Armbian typically sees eMMC as /dev/mmcblk1 (SD card is /dev/mmcblk0)
# Log eMMC presence for debugging (actual eMMC install handled by firstboot)
if [ -b /dev/mmcblk1 ]; then
    EMMC_SIZE=$(lsblk -b -d -n -o SIZE /dev/mmcblk1 2>/dev/null || echo "unknown")
    echo "  eMMC detected: /dev/mmcblk1 (${EMMC_SIZE} bytes)"
else
    echo "  eMMC not detected (expected /dev/mmcblk1 — may appear at runtime)"
fi

# Set CubeOS tier marker
echo "CUBEOS_TIER=full" >> /etc/environment

echo "=== [09] BPI-M4 Zero Board Configuration: DONE ==="
