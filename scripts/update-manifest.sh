#!/bin/bash
# =============================================================================
# CubeOS Pi Imager Manifest Generator
# =============================================================================
# Generates rpi-imager.json from built image files.
# Usage: ./update-manifest.sh <version> [--output <path>]
# Example: ./update-manifest.sh 0.2.0
# =============================================================================

set -euo pipefail

VERSION="${1:?Usage: $0 <version> [--output <path>]}"
OUTPUT="imager/rpi-imager.json"

# Parse optional --output flag
shift
while [ $# -gt 0 ]; do
    case "$1" in
        --output) OUTPUT="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RELEASE_DATE=$(date +%Y-%m-%d)
BASE_URL="https://github.com/cubeos-app/releases/releases/download/v${VERSION}"
ICON_URL="https://releases.cubeos.app/images/cubeos-icon-40x40.png"
WEBSITE="https://cubeos.app"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$(dirname "$OUTPUT")"

# Calculate checksums for Full image
FULL_IMG="cubeos-${VERSION}-arm64"
if [ -f "${FULL_IMG}.img" ] && [ -f "${FULL_IMG}.img.xz" ]; then
    FULL_CHECKSUMS=$(bash "${SCRIPT_DIR}/calculate-checksums.sh" "$FULL_IMG")
    FULL_EXTRACT_SIZE=$(echo "$FULL_CHECKSUMS" | grep extract_size | grep -oP '\d+')
    FULL_EXTRACT_SHA=$(echo "$FULL_CHECKSUMS" | grep extract_sha256 | grep -oP '[a-f0-9]{64}')
    FULL_DL_SIZE=$(echo "$FULL_CHECKSUMS" | grep image_download_size | grep -oP '\d+')
    FULL_DL_SHA=$(echo "$FULL_CHECKSUMS" | grep image_download_sha256 | grep -oP '[a-f0-9]{64}')
else
    echo "WARNING: Full image not found, using placeholders" >&2
    FULL_EXTRACT_SIZE=0; FULL_EXTRACT_SHA="PLACEHOLDER"; FULL_DL_SIZE=0; FULL_DL_SHA="PLACEHOLDER"
fi

# Calculate checksums for Lite image
LITE_IMG="cubeos-${VERSION}-lite-arm64"
if [ -f "${LITE_IMG}.img" ] && [ -f "${LITE_IMG}.img.xz" ]; then
    LITE_CHECKSUMS=$(bash "${SCRIPT_DIR}/calculate-checksums.sh" "$LITE_IMG")
    LITE_EXTRACT_SIZE=$(echo "$LITE_CHECKSUMS" | grep extract_size | grep -oP '\d+')
    LITE_EXTRACT_SHA=$(echo "$LITE_CHECKSUMS" | grep extract_sha256 | grep -oP '[a-f0-9]{64}')
    LITE_DL_SIZE=$(echo "$LITE_CHECKSUMS" | grep image_download_size | grep -oP '\d+')
    LITE_DL_SHA=$(echo "$LITE_CHECKSUMS" | grep image_download_sha256 | grep -oP '[a-f0-9]{64}')
else
    echo "WARNING: Lite image not found, using placeholders" >&2
    LITE_EXTRACT_SIZE=0; LITE_EXTRACT_SHA="PLACEHOLDER"; LITE_DL_SIZE=0; LITE_DL_SHA="PLACEHOLDER"
fi

# Generate manifest
cat > "$OUTPUT" << MANIFEST
{
  "os_list": [
    {
      "name": "CubeOS ${VERSION} (64-bit)",
      "description": "Full installation with offline content, Docker apps, and documentation. Recommended for Pi 4/5 with 4GB+ RAM.",
      "url": "${BASE_URL}/cubeos-${VERSION}-arm64.img.xz",
      "icon": "${ICON_URL}",
      "website": "${WEBSITE}",
      "release_date": "${RELEASE_DATE}",
      "extract_size": ${FULL_EXTRACT_SIZE},
      "extract_sha256": "${FULL_EXTRACT_SHA}",
      "image_download_size": ${FULL_DL_SIZE},
      "image_download_sha256": "${FULL_DL_SHA}",
      "devices": ["pi4-64bit", "pi5-64bit", "pi400-64bit", "cm4-64bit", "cm5-64bit"],
      "init_format": "cloudinit"
    },
    {
      "name": "CubeOS ${VERSION} Lite (64-bit)",
      "description": "Core platform only. Lightweight, fast. Install additional apps from the App Store. For Pi 4/5 with 2GB+ RAM.",
      "url": "${BASE_URL}/cubeos-${VERSION}-lite-arm64.img.xz",
      "icon": "${ICON_URL}",
      "website": "${WEBSITE}",
      "release_date": "${RELEASE_DATE}",
      "extract_size": ${LITE_EXTRACT_SIZE},
      "extract_sha256": "${LITE_EXTRACT_SHA}",
      "image_download_size": ${LITE_DL_SIZE},
      "image_download_sha256": "${LITE_DL_SHA}",
      "devices": ["pi4-64bit", "pi5-64bit", "pi400-64bit", "cm4-64bit", "cm5-64bit"],
      "init_format": "cloudinit"
    }
  ]
}
MANIFEST

echo "Manifest written to: $OUTPUT" >&2
echo "Full image: ${FULL_DL_SIZE} bytes compressed" >&2
echo "Lite image: ${LITE_DL_SIZE} bytes compressed" >&2
