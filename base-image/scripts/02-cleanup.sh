#!/bin/bash
# =============================================================================
# 02-cleanup.sh — Golden base image cleanup
# =============================================================================
# Clears caches, removes unnecessary files, and optimizes for compression.
# Does NOT clear machine-id/SSH keys (that's the release pipeline's job).
#
# v2.0 (alpha.21+):
#   - Locale purge (keep en_US only) — saves ~100MB
#   - Doc/manpage removal — saves ~50MB
#   - Comprehensive apt-mark manual for all critical packages
#   - Better zero-fill approach
# =============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export TERM=dumb

echo "=== [BASE-CLEANUP] Cleaning base image (v2.0) ==="

# ---------------------------------------------------------------------------
# Protect ALL critical packages from autoremove
# ---------------------------------------------------------------------------
# Belt-and-suspenders: 01-ubuntu-base.sh already does this, but autoremove
# below could still strip packages if apt-mark failed under QEMU.
# ---------------------------------------------------------------------------
echo "[BASE-CLEANUP] Protecting critical packages..."
for pkg in util-linux-extra sqlite3 i2c-tools gpiod libgpiod2 usbutils \
           v4l-utils pps-tools modemmanager libqmi-utils libmbim-utils \
           usb-modeswitch usb-modeswitch-data gpsd gpsd-clients chrony \
           picocom smartmontools ethtool avahi-daemon wireguard-tools \
           zram-tools exfatprogs ntfs-3g bc wpasupplicant networkd-dispatcher \
           libpam-modules libpam-runtime openssh-server fail2ban \
           python3-pyasyncore python3-pyasynchat; do
    apt-mark manual "$pkg" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# APT cleanup
# ---------------------------------------------------------------------------
echo "[BASE-CLEANUP] Running autoremove..."
apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" autoremove -y 2>&1 | tail -5

echo "[BASE-CLEANUP] Cleaning APT cache..."
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /var/cache/apt/archives/*.deb

# ---------------------------------------------------------------------------
# Post-autoremove verification
# ---------------------------------------------------------------------------
echo "[BASE-CLEANUP] Verifying critical packages survived autoremove..."
MISSING=0
for cmd_pkg in "hwclock:util-linux-extra" "sqlite3:sqlite3" "i2cdetect:i2c-tools" \
               "gpiodetect:gpiod" "lsusb:usbutils" "mmcli:modemmanager" \
               "chronyd:chrony" "fail2ban-server:fail2ban"; do
    cmd="${cmd_pkg%%:*}"
    pkg="${cmd_pkg##*:}"
    if ! command -v "$cmd" &>/dev/null; then
        echo "[BASE-CLEANUP]   MISSING: $cmd ($pkg) — attempting reinstall..."
        apt-get update -q >/dev/null 2>&1 || true
        apt-get install -y --no-install-recommends "$pkg" 2>/dev/null || true
        apt-mark manual "$pkg" 2>/dev/null || true
        MISSING=$((MISSING + 1))
    fi
done
# B65: Verify asynchat/asyncore survived autoremove
if ! python3 -c "import asynchat; import asyncore" 2>/dev/null; then
    echo "[BASE-CLEANUP]   MISSING: asynchat/asyncore (fail2ban deps) — attempting reinstall..."
    apt-get update -q >/dev/null 2>&1 || true
    if ! apt-get install -y --no-install-recommends python3-pyasyncore python3-pyasynchat 2>/dev/null; then
        python3 -m ensurepip --upgrade 2>/dev/null || true
        python3 -m pip install pyasyncore pyasynchat --break-system-packages 2>/dev/null || true
        python3 -m pip cache purge 2>/dev/null || true
        rm -rf /root/.cache/pip 2>/dev/null || true
    fi
    apt-mark manual python3-pyasyncore python3-pyasynchat 2>/dev/null || true
    MISSING=$((MISSING + 1))
fi
if [ "$MISSING" -gt 0 ]; then
    echo "[BASE-CLEANUP]   Reinstalled $MISSING packages stripped by autoremove"
    apt-get clean
    rm -rf /var/lib/apt/lists/*
else
    echo "[BASE-CLEANUP]   All critical packages intact"
fi

# ---------------------------------------------------------------------------
# Locale cleanup — keep only English (saves ~100MB)
# ---------------------------------------------------------------------------
echo "[BASE-CLEANUP] Purging non-English locales..."
find /usr/share/locale -maxdepth 1 -mindepth 1 \
    ! -name 'en' ! -name 'en_US' ! -name 'en_GB' ! -name 'locale.alias' \
    -exec rm -rf {} + 2>/dev/null || true
LOCALE_SIZE=$(du -sh /usr/share/locale 2>/dev/null | cut -f1)
echo "[BASE-CLEANUP]   Locales remaining: $LOCALE_SIZE"

# ---------------------------------------------------------------------------
# Documentation cleanup (saves ~50MB)
# ---------------------------------------------------------------------------
echo "[BASE-CLEANUP] Removing documentation..."
rm -rf /usr/share/doc/*
rm -rf /usr/share/man/*
rm -rf /usr/share/info/*
rm -rf /usr/share/lintian/*
rm -rf /usr/share/groff/*
rm -rf /usr/share/linda/*

# Prevent docs from being installed in future (release pipeline installs nothing)
cat > /etc/dpkg/dpkg.cfg.d/01-nodoc << 'NODOC'
path-exclude /usr/share/doc/*
path-exclude /usr/share/man/*
path-exclude /usr/share/info/*
path-exclude /usr/share/lintian/*
# Keep copyright files (license compliance)
path-include /usr/share/doc/*/copyright
NODOC
echo "[BASE-CLEANUP]   Docs removed + dpkg exclusion configured"

# ---------------------------------------------------------------------------
# Log cleanup
# ---------------------------------------------------------------------------
echo "[BASE-CLEANUP] Clearing logs..."
find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
find /var/log -type f -name "*.gz" -delete
find /var/log -type f -name "*.1" -delete
journalctl --vacuum-time=0 2>/dev/null || true

# ---------------------------------------------------------------------------
# Temp files
# ---------------------------------------------------------------------------
echo "[BASE-CLEANUP] Removing temp files..."
rm -rf /tmp/* /var/tmp/*
rm -rf /root/.cache /root/.wget-hsts

# ---------------------------------------------------------------------------
# Shell history
# ---------------------------------------------------------------------------
rm -f /root/.bash_history
history -c 2>/dev/null || true

# ---------------------------------------------------------------------------
# Size report before zero-fill
# ---------------------------------------------------------------------------
echo ""
echo "[BASE-CLEANUP] Disk usage summary:"
echo "  /usr:         $(du -sh /usr 2>/dev/null | cut -f1)"
echo "  /var:         $(du -sh /var 2>/dev/null | cut -f1)"
echo "  /lib:         $(du -sh /lib 2>/dev/null | cut -f1)"
echo "  Total used:   $(df -h / | awk 'NR==2{print $3}')"
echo "  Free space:   $(df -h / | awk 'NR==2{print $4}')"
TOTAL_PKGS=$(dpkg -l 2>/dev/null | grep -c '^ii' || echo 'unknown')
echo "  Packages:     $TOTAL_PKGS"

# ---------------------------------------------------------------------------
# Zero free space (improves compression of base image)
# ---------------------------------------------------------------------------
echo "[BASE-CLEANUP] Zeroing free space for compression..."
dd if=/dev/zero of=/zero bs=1M 2>/dev/null || true
rm -f /zero
sync

echo "[BASE-CLEANUP] Base image cleanup complete."
