#!/bin/bash
# =============================================================================
# Orange Pi 5 board-specific config — Rockchip RK3588S
# =============================================================================
# Armbian uses armbianEnv.txt (in /boot/) instead of config.txt (Pi) or
# GRUB (x86). This script configures board-specific bootloader settings.
#
# Board: Orange Pi 5
# SoC:   Rockchip RK3588S (quad A76 + quad A55, 8 cores)
# Serial console: ttyS2 at 1500000 baud (Rockchip UART2, 3-pin debug header)
# DTB: rockchip/rk3588s-orangepi-5.dtb
#
# WARNING: If the board has a stock OS installed in SPI flash, Armbian may
# not boot from SD card. The user must erase SPI flash first:
#   dd if=/dev/zero of=/dev/mtdblock0 bs=4096
# Or use Armbian's armbian-install tool to clear SPI.
#
# TODO: Verify armbianEnv.txt settings on real Orange Pi 5 hardware
# TODO: Verify SPI flash interaction with SD boot
# =============================================================================
set -euo pipefail
echo "=== [09] Orange Pi 5 Board Configuration (RK3588S) ==="

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

echo "=== [09] Orange Pi 5 Board Configuration: DONE ==="
