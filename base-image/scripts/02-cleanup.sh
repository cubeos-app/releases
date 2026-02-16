#!/bin/bash
# =============================================================================
# 02-cleanup.sh — Golden base image cleanup
# =============================================================================
# Clears caches and temp files. Does NOT zero free space or clear machine-id
# since this is a base image, not a release image. The release pipeline's
# cleanup script handles final prep for distribution.
# =============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export TERM=dumb

echo "=== [BASE-CLEANUP] Cleaning base image ==="

# ---------------------------------------------------------------------------
# APT cleanup
# ---------------------------------------------------------------------------
echo "[BASE-CLEANUP] Cleaning APT cache..."
# B03: Protect util-linux-extra (hwclock) from autoremove
apt-mark manual util-linux-extra 2>/dev/null || true
apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" autoremove -y 2>&1 | tail -5
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /var/cache/apt/archives/*.deb

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
# Zero free space (improves compression of base image)
# ---------------------------------------------------------------------------
echo "[BASE-CLEANUP] Zeroing free space for compression..."
dd if=/dev/zero of=/zero bs=1M 2>/dev/null || true
rm -f /zero
sync

echo "[BASE-CLEANUP] Base image cleanup complete."
