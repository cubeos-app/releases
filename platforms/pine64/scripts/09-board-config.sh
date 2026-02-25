#!/bin/bash
# =============================================================================
# Pine64 board-specific config — armbianEnv.txt, serial console
# =============================================================================
# Armbian uses armbianEnv.txt (in /boot/) instead of config.txt (Pi) or
# GRUB (x86). This script configures board-specific bootloader settings.
#
# Pine64 uses Allwinner A64 SoC — serial console is on UART0 by default.
#
# TODO: Verify armbianEnv.txt settings on real Pine64 hardware
# TODO: Verify UART pin configuration for Pine64
# =============================================================================
set -euo pipefail
echo "=== [09] Pine64 Board Configuration ==="

# Armbian bootloader config
if [ -f /boot/armbianEnv.txt ]; then
    # Enable serial console
    grep -q '^console=serial' /boot/armbianEnv.txt || \
        echo "console=serial" >> /boot/armbianEnv.txt

    # Set verbosity
    sed -i 's/^verbosity=.*/verbosity=1/' /boot/armbianEnv.txt 2>/dev/null || true
fi

# Disable cloud-init after first boot (prevents air-gap timeout delays)
touch /etc/cloud/cloud-init.disabled

# Set CubeOS tier marker
echo "CUBEOS_TIER=full" >> /etc/environment

echo "=== [09] Pine64 Board Configuration: DONE ==="
