#!/bin/bash
# =============================================================================
# ROCK 5B board-specific config — Rockchip RK3588
# =============================================================================
# Armbian uses armbianEnv.txt (in /boot/) instead of config.txt (Pi) or
# GRUB (x86). This script configures board-specific bootloader settings.
#
# Board: Radxa ROCK 5B
# SoC:   Rockchip RK3588 (quad A76 + quad A55, 8 cores, 6 TOPS NPU)
# Serial console: ttyS2 at 1500000 baud (Rockchip UART2)
# DTB: rockchip/rk3588-rock-5b.dtb
#
# WARNING: If the board has a stock OS in SPI flash, Armbian may not boot
# from SD card. The user must erase SPI flash first.
#
# KNOWN ISSUE: USB-C PD is broken on most ROCK 5B revisions — causes boot
# loops. Workaround: use a fixed 5-24V USB-C supply (NOT PD/QC charger).
#
# TODO: Verify armbianEnv.txt settings on real ROCK 5B hardware
# =============================================================================
set -euo pipefail
echo "=== [09] ROCK 5B Board Configuration (RK3588) ==="

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

echo "=== [09] ROCK 5B Board Configuration: DONE ==="
