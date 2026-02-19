#!/bin/bash
# =============================================================================
# download-curated.sh — Download curated app ARM64 images via skopeo
# =============================================================================
# Reads curated-apps.txt and downloads each image as an ARM64 tarball.
# These tarballs are later pushed into a temp registry:2 in Phase 1c.
#
# Usage: ./skopeo/download-curated.sh [output_dir]
# Output: curated-images/ directory with .tar files
#
# v1.1 (B66 fix): Added verbose debugging, tarball validation, better errors
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/curated-apps.txt"
OUTPUT_DIR="${1:-curated-images}"
VERBOSE="${CURATED_VERBOSE:-false}"

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
    echo "  Expected at: ${SCRIPT_DIR}/curated-apps.txt"
    echo "  Working dir: $(pwd)"
    ls -la "${SCRIPT_DIR}/" 2>/dev/null || true
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
echo "Verbose:  ${VERBOSE}"
echo ""

# Show manifest contents for debugging
echo "Manifest entries:"
grep -v '^[[:space:]]*#' "$MANIFEST" | grep -v '^$' | while IFS= read -r line; do
    echo "  ${line}"
done
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

    # Build the repo name (strip registry host prefix for archive tag)
    REPO_NAME=$(echo "$SOURCE_IMAGE" | sed 's|^docker\.io/||; s|^ghcr\.io/||')

    echo "[${TOTAL}] Downloading ${SOURCE_IMAGE}:${TAG}..."
    echo "         Repo name: ${REPO_NAME}"
    echo "         → ${OUTPUT_DIR}/${FILENAME}"

    # B66: Check if source image has an ARM64 manifest before downloading
    if [ "$VERBOSE" = "true" ]; then
        echo "         Inspecting source manifest..."
        skopeo inspect --raw "docker://${SOURCE_IMAGE}:${TAG}" 2>&1 | \
            grep -o '"architecture"[[:space:]]*:[[:space:]]*"[^"]*"' | head -5 || \
            echo "         (could not inspect manifest — may be single-arch)"
    fi

    SKOPEO_ARGS="--override-arch arm64 --override-os linux --retry-times 3"

    if [ "$VERBOSE" = "true" ]; then
        echo "         skopeo copy ${SKOPEO_ARGS} docker://${SOURCE_IMAGE}:${TAG} docker-archive:${OUTPUT_DIR}/${FILENAME}:${REPO_NAME}:${TAG}"
    fi

    if skopeo copy \
        --override-arch arm64 \
        --override-os linux \
        --retry-times 3 \
        "docker://${SOURCE_IMAGE}:${TAG}" \
        "docker-archive:${OUTPUT_DIR}/${FILENAME}:${REPO_NAME}:${TAG}" 2>&1; then

        # B66: Validate the tarball is non-empty and is a valid tar archive
        if [ ! -f "${OUTPUT_DIR}/${FILENAME}" ]; then
            echo "         FAILED: tarball not created!"
            FAILED=$((FAILED + 1))
            continue
        fi

        SIZE=$(du -h "${OUTPUT_DIR}/${FILENAME}" | cut -f1)
        SIZE_BYTES=$(stat -c%s "${OUTPUT_DIR}/${FILENAME}" 2>/dev/null || echo 0)

        if [ "$SIZE_BYTES" -lt 1024 ]; then
            echo "         FAILED: tarball too small (${SIZE_BYTES} bytes) — likely corrupt"
            rm -f "${OUTPUT_DIR}/${FILENAME}"
            FAILED=$((FAILED + 1))
            continue
        fi

        # Verify it's a valid tar
        if ! tar tf "${OUTPUT_DIR}/${FILENAME}" &>/dev/null; then
            echo "         FAILED: not a valid tar archive"
            rm -f "${OUTPUT_DIR}/${FILENAME}"
            FAILED=$((FAILED + 1))
            continue
        fi

        echo "         OK (${SIZE})"
        DOWNLOADED=$((DOWNLOADED + 1))
    else
        echo "         FAILED! skopeo exit code: $?"
        # Remove any partial download
        rm -f "${OUTPUT_DIR}/${FILENAME}" 2>/dev/null || true
        FAILED=$((FAILED + 1))
    fi
    echo ""
done < "$MANIFEST"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [ "$TOTAL" -eq 0 ]; then
    echo "WARNING: No images found in manifest."
    echo "  Manifest: ${MANIFEST}"
    echo "  Content:"
    cat "$MANIFEST"
    exit 1
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

ls -lh "${OUTPUT_DIR}"/*.tar 2>/dev/null || echo "  (no tarballs found!)"

# B66: Exit non-zero if ANY image failed — don't ship with partial registry
if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo "ERROR: ${FAILED}/${TOTAL} curated images failed to download."
    echo "The image will ship with an incomplete registry."
    exit 1
fi

exit 0
