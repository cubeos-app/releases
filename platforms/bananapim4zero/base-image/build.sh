#!/bin/bash
# =============================================================================
# build.sh — Build and optionally upload BPI-M4 Zero golden base image
# =============================================================================
# Usage:
#   ./build.sh                  # Build + upload to GitLab Package Registry
#   ./build.sh --build-only     # Build only, no upload
#
# Run from repo root (not from base-image/ directory).
# Requires: Docker with privileged mode, QEMU aarch64 binfmt registered.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../" && pwd)"

BASE_IMAGE_NAME="cubeos-base-armbian-noble-arm64"
BASE_VERSION="1.0.0"
OUTPUT_IMG="${REPO_ROOT}/${BASE_IMAGE_NAME}.img"
OUTPUT_XZ="${OUTPUT_IMG}.xz"

UPLOAD=true
if [ "${1:-}" = "--build-only" ]; then
    UPLOAD=false
fi

echo "============================================================"
echo "  CubeOS Golden Base Builder — BPI-M4 Zero (Armbian)"
echo "  Version: ${BASE_VERSION}"
echo "  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "============================================================"
echo ""

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
echo "[BUILD] Starting Packer build (expect ~30 min under QEMU)..."
echo "[BUILD] Output: ${OUTPUT_IMG}"
echo ""

cd "$REPO_ROOT"

docker run --rm --privileged \
    -v /dev:/dev \
    -v "${REPO_ROOT}:/build" \
    -w /build \
    mkaczanowski/packer-builder-arm:latest build \
    platforms/bananapim4zero/base-image/cubeos-base-armbian.pkr.hcl

if [ ! -f "$OUTPUT_IMG" ]; then
    echo "[BUILD] FATAL: Packer output not found at ${OUTPUT_IMG}"
    exit 1
fi

echo ""
echo "[BUILD] Packer build complete."
echo "[BUILD] Image size: $(du -sh "$OUTPUT_IMG" | cut -f1)"

# ---------------------------------------------------------------------------
# Compress
# ---------------------------------------------------------------------------
echo "[BUILD] Compressing with xz -6 (this takes a while)..."
rm -f "$OUTPUT_XZ"
xz -6 -T0 -v "$OUTPUT_IMG"
echo "[BUILD] Compressed: $(du -sh "$OUTPUT_XZ" | cut -f1)"

# ---------------------------------------------------------------------------
# Upload to GitLab Package Registry
# ---------------------------------------------------------------------------
if [ "$UPLOAD" = true ]; then
    if [ -z "${GITLAB_TOKEN:-}" ]; then
        echo "[BUILD] WARNING: GITLAB_TOKEN not set. Skipping upload."
        echo "[BUILD] Set GITLAB_TOKEN and re-run, or upload manually."
    else
        GITLAB_URL="https://gitlab.nuclearlighters.net"
        PROJECT_ID="20"  # releases repo

        echo "[BUILD] Uploading to GitLab Package Registry..."
        echo "[BUILD]   Package: cubeos-base-armbian/${BASE_VERSION}"
        echo "[BUILD]   File: ${BASE_IMAGE_NAME}.img.xz"

        curl --fail --progress-bar \
            --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
            --upload-file "$OUTPUT_XZ" \
            "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/packages/generic/cubeos-base-armbian/${BASE_VERSION}/${BASE_IMAGE_NAME}.img.xz"

        echo ""
        echo "[BUILD] Upload complete."
        echo "[BUILD] URL: ${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/packages/generic/cubeos-base-armbian/${BASE_VERSION}/${BASE_IMAGE_NAME}.img.xz"
    fi
else
    echo "[BUILD] --build-only: skipping upload."
fi

# ---------------------------------------------------------------------------
# SHA256
# ---------------------------------------------------------------------------
SHA256=$(sha256sum "$OUTPUT_XZ" | cut -d' ' -f1)
echo ""
echo "============================================================"
echo "  Golden Base Build — COMPLETE"
echo "============================================================"
echo "  File:     ${OUTPUT_XZ}"
echo "  Size:     $(du -sh "$OUTPUT_XZ" | cut -f1)"
echo "  SHA256:   ${SHA256}"
echo ""
echo "  Update packer.pkr.hcl with:"
echo "    base_image_checksum = \"${SHA256}\""
echo "    base_image_checksum_type = \"sha256\""
echo "============================================================"
