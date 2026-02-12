#!/bin/bash
# =============================================================================
# download-images.sh — Download ARM64 Docker images via skopeo
# =============================================================================
# Downloads CubeOS core Docker images as tarballs, natively on x86_64.
# No QEMU needed — skopeo fetches the ARM64 manifests directly.
#
# Usage: ./skopeo/download-images.sh [output_dir]
# Output: docker-images/ directory with .tar files
# =============================================================================
set -euo pipefail

OUTPUT_DIR="${1:-docker-images}"
mkdir -p "$OUTPUT_DIR"

echo "============================================================"
echo "  CubeOS Docker Image Downloader (ARM64)"
echo "============================================================"
echo ""

# ---------------------------------------------------------------------------
# Image list — the 5 essential CubeOS services
# ---------------------------------------------------------------------------
# Format: "registry/image:tag|output_filename"
IMAGES=(
    "docker://docker.io/pihole/pihole:latest|pihole.tar"
    "docker://docker.io/jc21/nginx-proxy-manager:latest|npm.tar"
    "docker://ghcr.io/cubeos-app/api:latest|cubeos-api.tar"
    "docker://ghcr.io/cubeos-app/hal:latest|cubeos-hal.tar"
    "docker://ghcr.io/cubeos-app/dashboard:latest|cubeos-dashboard.tar"
)

# ---------------------------------------------------------------------------
# Check for skopeo
# ---------------------------------------------------------------------------
if ! command -v skopeo &>/dev/null; then
    echo "ERROR: skopeo not found."
    echo "Install: apt-get install -y skopeo  or  use the skopeo Docker image"
    exit 1
fi

echo "Using skopeo $(skopeo --version 2>/dev/null || echo 'unknown')"
echo "Output: ${OUTPUT_DIR}/"
echo ""

# ---------------------------------------------------------------------------
# Download each image
# ---------------------------------------------------------------------------
DOWNLOADED=0
FAILED=0
TOTAL=${#IMAGES[@]}

for entry in "${IMAGES[@]}"; do
    SOURCE="${entry%%|*}"
    FILENAME="${entry##*|}"
    IMAGE_NAME=$(echo "$SOURCE" | sed 's|docker://||' | sed 's|docker.io/||')

    echo "[${DOWNLOADED}/${TOTAL}] Downloading ${IMAGE_NAME}..."
    echo "         → ${OUTPUT_DIR}/${FILENAME}"

    if skopeo copy \
        --override-arch arm64 \
        --override-os linux \
        "$SOURCE" \
        "docker-archive:${OUTPUT_DIR}/${FILENAME}:${IMAGE_NAME}" 2>&1; then
        
        SIZE=$(du -h "${OUTPUT_DIR}/${FILENAME}" | cut -f1)
        echo "         OK (${SIZE})"
        DOWNLOADED=$((DOWNLOADED + 1))
    else
        echo "         FAILED!"
        FAILED=$((FAILED + 1))
    fi
    echo ""
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" | cut -f1)

echo "============================================================"
echo "  Download complete: ${DOWNLOADED}/${TOTAL} images"
if [ $FAILED -gt 0 ]; then
    echo "  FAILED: ${FAILED} images"
fi
echo "  Total size: ${TOTAL_SIZE}"
echo "  Output: ${OUTPUT_DIR}/"
echo "============================================================"

# List files
echo ""
ls -lh "${OUTPUT_DIR}"/*.tar

exit $FAILED
