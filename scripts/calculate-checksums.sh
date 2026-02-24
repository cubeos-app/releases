#!/bin/bash
# =============================================================================
# CubeOS Checksum Calculator for Pi Imager Manifest
# =============================================================================
# Usage: ./calculate-checksums.sh <image-name-without-extension>
# Example: ./calculate-checksums.sh cubeos-0.2.0-arm64
#
# Outputs JSON fragment suitable for rpi-imager.json manifest.
# Requires both .img and .img.xz to exist.
# =============================================================================

set -euo pipefail

IMAGE_BASE="${1:?Usage: $0 <image-name-without-extension>}"
IMG="${IMAGE_BASE}.img"
XZ="${IMAGE_BASE}.img.xz"

[ -f "$IMG" ] || { echo "ERROR: $IMG not found"; exit 1; }
[ -f "$XZ" ] || { echo "ERROR: $XZ not found"; exit 1; }

EXTRACT_SIZE=$(stat -c%s "$IMG")
EXTRACT_SHA256=$(sha256sum "$IMG" | cut -d' ' -f1)
DOWNLOAD_SIZE=$(stat -c%s "$XZ")
DOWNLOAD_SHA256=$(sha256sum "$XZ" | cut -d' ' -f1)

cat << EOF
{
  "extract_size": ${EXTRACT_SIZE},
  "extract_sha256": "${EXTRACT_SHA256}",
  "image_download_size": ${DOWNLOAD_SIZE},
  "image_download_sha256": "${DOWNLOAD_SHA256}"
}
EOF

# Also write to individual files for CI artifacts
echo "$EXTRACT_SHA256  $IMG" > "${IMAGE_BASE}.img.sha256"
echo "$DOWNLOAD_SHA256  $XZ" > "${IMAGE_BASE}.img.xz.sha256"
echo "Checksums written to ${IMAGE_BASE}.img.sha256 and ${IMAGE_BASE}.img.xz.sha256" >&2
