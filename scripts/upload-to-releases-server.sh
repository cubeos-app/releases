#!/bin/bash
# =============================================================================
# CubeOS Release Upload — SCP artifacts to releases server
# =============================================================================
# Uploads release artifacts to the DMZ releases server via SCP.
# The server runs stock Chainguard nginx serving files from
# /srv/cubeos-releases/data/.
#
# Usage: CUBEOS_VERSION=0.2.0-beta.01 RELEASES_DEPLOY_HOST=nllei01dmz01 \
#          bash scripts/upload-to-releases-server.sh
#
# Required env vars:
#   CUBEOS_VERSION        — Release version (e.g., 0.2.0-beta.01)
#   RELEASES_DEPLOY_HOST  — DMZ hostname (SSH key auth must be configured)
#
# Expected local files (in current directory):
#   cubeos-{VERSION}-arm64.img.xz          (Full image)
#   cubeos-{VERSION}-arm64.img.xz.sha256   (Full checksum)
#   cubeos-{VERSION}-lite-arm64.img.xz     (Lite image)
#   cubeos-{VERSION}-lite-arm64.img.xz.sha256 (Lite checksum)
#   imager/rpi-imager.json                  (Pi Imager manifest)
#   curl/docker-compose.yml.template        (Compose template)
#   curl/cubeos-cli.sh                      (CLI script)
#
# Result on DMZ:
#   /srv/cubeos-releases/data/releases/{VERSION}/
#     ├── cubeos-full-arm64.img.xz
#     ├── cubeos-full-arm64.img.xz.sha256
#     ├── cubeos-lite-arm64.img.xz
#     ├── cubeos-lite-arm64.img.xz.sha256
#     ├── docker-compose.yml
#     ├── cubeos-cli.sh
#     └── rpi-imager.json
#   /srv/cubeos-releases/data/latest -> releases/{VERSION}/
#   /srv/cubeos-releases/data/SHA256SUMS  (appended)
# =============================================================================

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

VERSION="${CUBEOS_VERSION:?ERROR: CUBEOS_VERSION is required}"
HOST="${RELEASES_DEPLOY_HOST:?ERROR: RELEASES_DEPLOY_HOST is required}"
REMOTE_BASE="/srv/cubeos-releases/data"
REMOTE_DIR="${REMOTE_BASE}/releases/${VERSION}"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

# ─── Helpers ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BOLD}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Upload a file via SCP, print size
upload_file() {
    local src="$1" dst="$2"
    local size
    size=$(du -h "$src" | cut -f1)
    info "Uploading $(basename "$src") ($size) → $dst"
    scp ${SSH_OPTS} "$src" "${HOST}:${dst}"
    ok "$(basename "$src") uploaded"
}

# ─── Validate local files ────────────────────────────────────────────────────

FULL_IMG="cubeos-${VERSION}-arm64.img.xz"
FULL_SHA="${FULL_IMG}.sha256"
LITE_IMG="cubeos-${VERSION}-lite-arm64.img.xz"
LITE_SHA="${LITE_IMG}.sha256"

MISSING=0
for f in "$FULL_IMG" "$FULL_SHA" "$LITE_IMG" "$LITE_SHA"; do
    if [ ! -f "$f" ]; then
        warn "Missing: $f"
        MISSING=$((MISSING + 1))
    fi
done

# Images are optional (may run for curl artifacts only), but warn
if [ "$MISSING" -gt 0 ]; then
    warn "$MISSING image file(s) missing — uploading available artifacts only"
fi

# ─── Create remote directory ─────────────────────────────────────────────────

info "Creating remote directory: ${REMOTE_DIR}"
ssh ${SSH_OPTS} "${HOST}" "mkdir -p ${REMOTE_DIR}"
ok "Remote directory ready"

# ─── Upload artifacts ────────────────────────────────────────────────────────

UPLOADED=0

# Image files
if [ -f "$FULL_IMG" ]; then
    upload_file "$FULL_IMG" "${REMOTE_DIR}/cubeos-full-arm64.img.xz"
    UPLOADED=$((UPLOADED + 1))
fi
if [ -f "$FULL_SHA" ]; then
    upload_file "$FULL_SHA" "${REMOTE_DIR}/cubeos-full-arm64.img.xz.sha256"
    UPLOADED=$((UPLOADED + 1))
fi
if [ -f "$LITE_IMG" ]; then
    upload_file "$LITE_IMG" "${REMOTE_DIR}/cubeos-lite-arm64.img.xz"
    UPLOADED=$((UPLOADED + 1))
fi
if [ -f "$LITE_SHA" ]; then
    upload_file "$LITE_SHA" "${REMOTE_DIR}/cubeos-lite-arm64.img.xz.sha256"
    UPLOADED=$((UPLOADED + 1))
fi

# Pi Imager manifest
if [ -f "imager/rpi-imager.json" ]; then
    upload_file "imager/rpi-imager.json" "${REMOTE_DIR}/rpi-imager.json"
    UPLOADED=$((UPLOADED + 1))
fi

# Curl installer artifacts
if [ -f "curl/docker-compose.yml.template" ]; then
    upload_file "curl/docker-compose.yml.template" "${REMOTE_DIR}/docker-compose.yml"
    UPLOADED=$((UPLOADED + 1))
fi
if [ -f "curl/cubeos-cli.sh" ]; then
    upload_file "curl/cubeos-cli.sh" "${REMOTE_DIR}/cubeos-cli.sh"
    UPLOADED=$((UPLOADED + 1))
fi

if [ "$UPLOADED" -eq 0 ]; then
    error "No files were uploaded — check that build artifacts exist"
fi

# ─── Update 'latest' symlink ─────────────────────────────────────────────────

info "Updating 'latest' symlink → releases/${VERSION}/"
ssh ${SSH_OPTS} "${HOST}" "cd ${REMOTE_BASE} && ln -sfn releases/${VERSION} latest"
ok "Symlink updated"

# ─── Update global SHA256SUMS ────────────────────────────────────────────────

if [ -f "$FULL_SHA" ] || [ -f "$LITE_SHA" ]; then
    info "Updating global SHA256SUMS"
    SUMS=""
    if [ -f "$FULL_SHA" ]; then
        SUMS="${SUMS}$(cat "$FULL_SHA" | sed "s|$|  releases/${VERSION}/cubeos-full-arm64.img.xz|" | awk '{print $1 "  " $NF}')\n"
    fi
    if [ -f "$LITE_SHA" ]; then
        SUMS="${SUMS}$(cat "$LITE_SHA" | sed "s|$|  releases/${VERSION}/cubeos-lite-arm64.img.xz|" | awk '{print $1 "  " $NF}')\n"
    fi
    echo -e "$SUMS" | ssh ${SSH_OPTS} "${HOST}" "cat >> ${REMOTE_BASE}/SHA256SUMS"
    ok "SHA256SUMS updated"
fi

# ─── Verify remote files ─────────────────────────────────────────────────────

info "Verifying remote files..."
REMOTE_FILES=$(ssh ${SSH_OPTS} "${HOST}" "ls -lhS ${REMOTE_DIR}/ 2>/dev/null || echo 'EMPTY'")
if [ "$REMOTE_FILES" = "EMPTY" ]; then
    error "Remote directory is empty after upload!"
fi

# Verify checksums on remote if images were uploaded
if [ -f "$FULL_SHA" ] && [ -f "$FULL_IMG" ]; then
    EXPECTED=$(cut -d' ' -f1 "$FULL_SHA")
    REMOTE_SUM=$(ssh ${SSH_OPTS} "${HOST}" "sha256sum ${REMOTE_DIR}/cubeos-full-arm64.img.xz | cut -d' ' -f1")
    if [ "$EXPECTED" = "$REMOTE_SUM" ]; then
        ok "Full image checksum verified"
    else
        error "Full image checksum mismatch! Expected: $EXPECTED Got: $REMOTE_SUM"
    fi
fi

if [ -f "$LITE_SHA" ] && [ -f "$LITE_IMG" ]; then
    EXPECTED=$(cut -d' ' -f1 "$LITE_SHA")
    REMOTE_SUM=$(ssh ${SSH_OPTS} "${HOST}" "sha256sum ${REMOTE_DIR}/cubeos-lite-arm64.img.xz | cut -d' ' -f1")
    if [ "$EXPECTED" = "$REMOTE_SUM" ]; then
        ok "Lite image checksum verified"
    else
        error "Lite image checksum mismatch! Expected: $EXPECTED Got: $REMOTE_SUM"
    fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "============================================================"
echo "  Upload Complete: CubeOS ${VERSION}"
echo "============================================================"
echo ""
echo "  Remote directory: ${HOST}:${REMOTE_DIR}/"
echo ""
echo "$REMOTE_FILES"
echo ""
echo "  Symlink: ${REMOTE_BASE}/latest → releases/${VERSION}/"
echo "  Files uploaded: ${UPLOADED}"
echo ""
echo "  URLs:"
echo "    https://releases.cubeos.app/releases/${VERSION}/"
echo "    https://releases.cubeos.app/latest/"
echo "============================================================"
