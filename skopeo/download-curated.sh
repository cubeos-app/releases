#!/bin/bash
# =============================================================================
# download-curated.sh — Download curated app ARM64 images via skopeo
# =============================================================================
# Reads curated-apps.txt and downloads each image as an ARM64 tarball.
# These tarballs are later pushed into a temp registry:2 in Phase 1c.
#
# Usage: ./skopeo/download-curated.sh [output_dir]
# Output: curated-images/ directory with .tar files
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/curated-apps.txt"
OUTPUT_DIR="${1:-curated-images}"

mkdir -p "$OUTPUT_DIR"

echo "============================================================"
echo "  CubeOS Curated App Image Downloader (ARM64)"
echo "============================================================"
echo ""

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
if [ ! -f "$MANIFEST" ]; then
    echo "ERROR: Manifest not found: ${MANIFEST}"
    exit 1
fi

if ! command -v skopeo &>/dev/null; then
    echo "ERROR: skopeo not found."
    echo "Install: apt-get install -y skopeo"
    exit 1
fi

echo "Using skopeo $(skopeo --version 2>/dev/null | head -1)"
echo "Manifest: ${MANIFEST}"
echo "Output:   ${OUTPUT_DIR}/"
echo ""

# ---------------------------------------------------------------------------
# Parse manifest and download
# ---------------------------------------------------------------------------
DOWNLOADED=0
FAILED=0
TOTAL=0

while IFS= read -r line; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue

    TOTAL=$((TOTAL + 1))
    SOURCE_IMAGE=$(echo "$line" | cut -d'|' -f1 | xargs)
    TAG=$(echo "$line" | cut -d'|' -f2 | xargs)
    FILENAME=$(echo "$line" | cut -d'|' -f3 | xargs)

    if [ -z "$SOURCE_IMAGE" ] || [ -z "$TAG" ] || [ -z "$FILENAME" ]; then
        echo "WARN: Skipping malformed line: ${line}"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Build the repo name (strip docker.io/ prefix for archive tag)
    REPO_NAME=$(echo "$SOURCE_IMAGE" | sed 's|^docker\.io/||')

    echo "[${DOWNLOADED}/${TOTAL}] Downloading ${REPO_NAME}:${TAG}..."
    echo "         → ${OUTPUT_DIR}/${FILENAME}"

    if skopeo copy \
        --override-arch arm64 \
        --override-os linux \
        --retry-times 3 \
        "docker://${SOURCE_IMAGE}:${TAG}" \
        "docker-archive:${OUTPUT_DIR}/${FILENAME}:${REPO_NAME}:${TAG}" 2>&1; then

        SIZE=$(du -h "${OUTPUT_DIR}/${FILENAME}" | cut -f1)
        echo "         OK (${SIZE})"
        DOWNLOADED=$((DOWNLOADED + 1))
    else
        echo "         FAILED!"
        FAILED=$((FAILED + 1))
    fi
    echo ""
done < "$MANIFEST"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [ "$TOTAL" -eq 0 ]; then
    echo "WARNING: No images found in manifest."
    exit 0
fi

TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" 2>/dev/null | cut -f1)

echo "============================================================"
echo "  Curated download complete: ${DOWNLOADED}/${TOTAL} images"
if [ $FAILED -gt 0 ]; then
    echo "  FAILED: ${FAILED} images"
fi
echo "  Total size: ${TOTAL_SIZE}"
echo "  Output: ${OUTPUT_DIR}/"
echo "============================================================"

ls -lh "${OUTPUT_DIR}"/*.tar 2>/dev/null || true

exit $FAILED
