#!/bin/bash
# =============================================================================
# 07-cleanup.sh — Image cleanup for minimal size
# =============================================================================
# Removes caches, temp files, logs. Prepares image for compression.
# =============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export TERM=dumb

echo "=== [07] Cleanup ==="

# ---------------------------------------------------------------------------
# Remove build artifacts
# ---------------------------------------------------------------------------
echo "[07] Removing build artifacts..."
rm -rf /tmp/cubeos-configs /tmp/cubeos-firstboot

# ---------------------------------------------------------------------------
# APT cleanup
# ---------------------------------------------------------------------------
echo "[07] Cleaning APT cache..."
# B44: NO autoremove here. The golden base image already ran its own autoremove.
# The release packer installs ZERO new packages, so there is nothing to autoremove.
# Previous attempts (alpha.15-17) used apt-mark manual to protect util-linux-extra,
# but apt-mark silently fails under QEMU aarch64 chroot emulation, and the
# subsequent autoremove strips hwclock. The reinstall then also fails because
# the base image already purged APT lists. Removing autoremove entirely is the
# correct fix — it was never needed in the release packer.
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /var/cache/apt/archives/*.deb

# ---------------------------------------------------------------------------
# Log cleanup
# ---------------------------------------------------------------------------
echo "[07] Clearing logs..."
find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
find /var/log -type f -name "*.gz" -delete
find /var/log -type f -name "*.1" -delete
journalctl --vacuum-time=0 2>/dev/null || true

# ---------------------------------------------------------------------------
# Temp files
# ---------------------------------------------------------------------------
echo "[07] Removing temp files..."
rm -rf /tmp/* /var/tmp/*
rm -rf /root/.cache /root/.wget-hsts
rm -rf /home/cubeos/.cache

# ---------------------------------------------------------------------------
# Shell history
# ---------------------------------------------------------------------------
echo "[07] Clearing shell history..."
rm -f /root/.bash_history /home/cubeos/.bash_history
history -c 2>/dev/null || true

# ---------------------------------------------------------------------------
# SSH host keys — regenerated on first boot for uniqueness
# ---------------------------------------------------------------------------
echo "[07] Removing SSH host keys (regenerated on first boot)..."
rm -f /etc/ssh/ssh_host_*

# Create a service to regenerate keys on first boot
cat > /etc/systemd/system/ssh-keygen.service << 'SSHKEYGEN'
[Unit]
Description=Generate SSH Host Keys
Before=ssh.service
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SSHKEYGEN
systemctl enable ssh-keygen.service 2>/dev/null || true

# ---------------------------------------------------------------------------
# Machine ID — regenerated on first boot for uniqueness
# ---------------------------------------------------------------------------
# Writing "uninitialized" is the systemd-recommended approach for images.
# systemd-machine-id-setup regenerates a proper ID on first boot.
# Using truncate -s 0 can cause issues with some systemd services.
# ---------------------------------------------------------------------------
echo "[07] Clearing machine-id (regenerated on first boot)..."
echo "uninitialized" > /etc/machine-id
rm -f /var/lib/dbus/machine-id

# ---------------------------------------------------------------------------
# Cloud-init — must treat next boot as first boot
# ---------------------------------------------------------------------------
# Without this, cloud-init skips growpart (partition expansion), SSH key
# injection from Pi Imager, and other first-boot modules.
#
# B61 NOTE: Cloud-init is no longer the SOLE path to a working user.
# The cubeos user + password are set directly in 02-networking.sh.
# If cloud-init fails completely on boot, SSH still works. Cloud-init
# is kept for: growpart, hostname customization, Pi Imager SSH keys.
# ---------------------------------------------------------------------------
echo "[07] Cleaning cloud-init state..."
# Clean instance state (force first-boot behavior) but DON'T pass --machine-id
# (already handled above — passing both can cause conflicts)
cloud-init clean --logs --seed 2>/dev/null || true

# B61: Ensure the 50-cloud-init.conf SSH override is removed again
# (cloud-init clean may have regenerated it)
rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf

# ---------------------------------------------------------------------------
# Zero free space (dramatically improves xz compression ratio)
# ---------------------------------------------------------------------------
echo "[07] Zeroing free space for compression (this takes a moment)..."
dd if=/dev/zero of=/zero bs=1M 2>/dev/null || true
rm -f /zero
sync

# ---------------------------------------------------------------------------
# B44: Final hwclock verification (soft warning — base image needs rebuild)
# ---------------------------------------------------------------------------
echo "[07] Verifying critical binaries..."
if command -v hwclock &>/dev/null; then
    echo "[07]   hwclock: OK ($(command -v hwclock))"
else
    echo "[07]   WARNING: hwclock not found (util-linux-extra missing from base image)"
    echo "[07]   RTC sync will not work at runtime. Rebuild base image to fix."
fi

echo "[07] Cleanup complete. Image is ready for compression."
