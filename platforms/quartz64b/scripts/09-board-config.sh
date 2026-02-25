#!/bin/bash
# =============================================================================
# Quartz64 Model B board-specific config — Rockchip RK3566
# =============================================================================
# Armbian uses armbianEnv.txt (in /boot/) instead of config.txt (Pi) or
# GRUB (x86). This script configures board-specific bootloader settings.
#
# Board: Pine64 Quartz64 Model B
# SoC:   Rockchip RK3566 (quad-core Cortex-A55, 1.8GHz — low power)
# GPU:   Mali G-52-2EE (Panfrost open source driver)
# Serial console: ttyS2 at 1500000 baud (Rockchip UART2)
# DTB: rockchip/rk3566-quartz64-b.dtb
# WiFi: Built-in 802.11ac + BT 5.0 (not configured for AP yet)
#
# This is a lower power board (A55 only, no big A76 cores). Well suited
# for low-power/always-on CubeOS deployments with 4GB RAM.
#
# No SPI flash boot issue — Quartz64 boots cleanly from SD card.
#
# TODO: Verify armbianEnv.txt settings on real Quartz64 Model B hardware
# =============================================================================
set -euo pipefail
echo "=== [09] Quartz64 Model B Board Configuration (RK3566) ==="

# Armbian bootloader config
if [ -f /boot/armbianEnv.txt ]; then
    # Enable serial console on ttyS2 at 1500000 baud (Rockchip UART2)
    grep -q '^console=serial' /boot/armbianEnv.txt || \
        echo "console=serial" >> /boot/armbianEnv.txt

    # Set verbosity
    sed -i 's/^verbosity=.*/verbosity=1/' /boot/armbianEnv.txt 2>/dev/null || true
fi

# Disable cloud-init after first boot (prevents air-gap timeout delays)
touch /etc/cloud/cloud-init.disabled

# Set CubeOS tier marker
echo "CUBEOS_TIER=full" >> /etc/environment

echo "=== [09] Quartz64 Model B Board Configuration: DONE ==="
