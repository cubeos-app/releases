#!/bin/bash
# =============================================================================
# CubeOS Channel Metadata Update
# =============================================================================
# Generates channel JSON (stable/beta/dev) with correct checksums and uploads
# to the website on DMZ. Channel files are served at:
#   https://get.cubeos.app/channels/{channel}.json
#
# Usage:
#   CUBEOS_VERSION=0.2.0-beta.01 CHANNEL=beta \
#     RELEASES_DEPLOY_HOST=nllei01dmz01 WEBSITE_DEPLOY_HOST=nllei01dmz01 \
#     bash scripts/update-channels.sh
#
# Required env vars:
#   CUBEOS_VERSION        — Release version
#   RELEASES_DEPLOY_HOST  — Host where release artifacts are stored
#   WEBSITE_DEPLOY_HOST   — Host where channel metadata is served
#
# Optional env vars:
#   CHANNEL               — Channel name: stable, beta, dev (auto-detected if omitted)
# =============================================================================

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

VERSION="${CUBEOS_VERSION:?ERROR: CUBEOS_VERSION is required}"
RELEASES_HOST="${RELEASES_DEPLOY_HOST:?ERROR: RELEASES_DEPLOY_HOST is required}"
WEBSITE_HOST="${WEBSITE_DEPLOY_HOST:?ERROR: WEBSITE_DEPLOY_HOST is required}"

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

# Remote paths
RELEASES_BASE="/srv/cubeos-releases/data"
WEBSITE_CHANNELS="/srv/cubeos-website/data/channels"

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

# ─── Auto-detect channel from version string ─────────────────────────────────

if [ -z "${CHANNEL:-}" ]; then
    case "$VERSION" in
        *-dev*)   CHANNEL="dev" ;;
        *-alpha*) CHANNEL="beta" ;;
        *-beta*)  CHANNEL="beta" ;;
        *-rc*)    CHANNEL="beta" ;;
        *)        CHANNEL="stable" ;;
    esac
    info "Auto-detected channel: ${CHANNEL} (from version ${VERSION})"
else
    info "Using specified channel: ${CHANNEL}"
fi

RELEASE_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RELEASE_DIR="${RELEASES_BASE}/releases/${VERSION}"

# ─── Fetch checksums from releases server ─────────────────────────────────────

info "Fetching checksums from releases server..."

FULL_SHA=""
LITE_SHA=""
FULL_SIZE=""
LITE_SIZE=""

# Try to read checksums from the remote release directory
FULL_SHA_CONTENT=$(ssh ${SSH_OPTS} "${RELEASES_HOST}" \
    "cat ${RELEASE_DIR}/cubeos-full-arm64.img.xz.sha256 2>/dev/null || echo ''")
LITE_SHA_CONTENT=$(ssh ${SSH_OPTS} "${RELEASES_HOST}" \
    "cat ${RELEASE_DIR}/cubeos-lite-arm64.img.xz.sha256 2>/dev/null || echo ''")

if [ -n "$FULL_SHA_CONTENT" ]; then
    FULL_SHA=$(echo "$FULL_SHA_CONTENT" | cut -d' ' -f1)
    FULL_SIZE=$(ssh ${SSH_OPTS} "${RELEASES_HOST}" \
        "stat -c%s ${RELEASE_DIR}/cubeos-full-arm64.img.xz 2>/dev/null || echo 0")
    ok "Full image: sha256=${FULL_SHA:0:16}... size=${FULL_SIZE}"
else
    warn "Full image not found on releases server"
fi

if [ -n "$LITE_SHA_CONTENT" ]; then
    LITE_SHA=$(echo "$LITE_SHA_CONTENT" | cut -d' ' -f1)
    LITE_SIZE=$(ssh ${SSH_OPTS} "${RELEASES_HOST}" \
        "stat -c%s ${RELEASE_DIR}/cubeos-lite-arm64.img.xz 2>/dev/null || echo 0")
    ok "Lite image: sha256=${LITE_SHA:0:16}... size=${LITE_SIZE}"
else
    warn "Lite image not found on releases server"
fi

# ─── Generate channel JSON ────────────────────────────────────────────────────

CHANNEL_JSON=$(cat <<CHANNEL_EOF
{
  "channel": "${CHANNEL}",
  "version": "${VERSION}",
  "release_date": "${RELEASE_DATE}",
  "base_url": "https://releases.cubeos.app/releases/${VERSION}",
  "images": {
    "full": {
      "filename": "cubeos-full-arm64.img.xz",
      "url": "https://releases.cubeos.app/releases/${VERSION}/cubeos-full-arm64.img.xz",
      "sha256": "${FULL_SHA:-}",
      "size": ${FULL_SIZE:-0}
    },
    "lite": {
      "filename": "cubeos-lite-arm64.img.xz",
      "url": "https://releases.cubeos.app/releases/${VERSION}/cubeos-lite-arm64.img.xz",
      "sha256": "${LITE_SHA:-}",
      "size": ${LITE_SIZE:-0}
    }
  },
  "installer": {
    "compose": "https://releases.cubeos.app/releases/${VERSION}/docker-compose.yml",
    "cli": "https://releases.cubeos.app/releases/${VERSION}/cubeos-cli.sh"
  },
  "rpi_imager": "https://releases.cubeos.app/releases/${VERSION}/rpi-imager.json",
  "changelog": "https://github.com/cubeos-app/releases/releases/tag/v${VERSION}"
}
CHANNEL_EOF
)

info "Generated channel JSON for ${CHANNEL}:"
echo "$CHANNEL_JSON" | head -5
echo "  ..."

# ─── Upload channel JSON to website ──────────────────────────────────────────

info "Uploading ${CHANNEL}.json to website..."
ssh ${SSH_OPTS} "${WEBSITE_HOST}" "mkdir -p ${WEBSITE_CHANNELS}"
echo "$CHANNEL_JSON" | ssh ${SSH_OPTS} "${WEBSITE_HOST}" "cat > ${WEBSITE_CHANNELS}/${CHANNEL}.json"
ok "${CHANNEL}.json uploaded"

# Also update 'latest.json' as an alias for the current channel
info "Updating latest.json → ${CHANNEL} channel"
echo "$CHANNEL_JSON" | ssh ${SSH_OPTS} "${WEBSITE_HOST}" "cat > ${WEBSITE_CHANNELS}/latest.json"
ok "latest.json updated"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "============================================================"
echo "  Channel Update Complete"
echo "============================================================"
echo "  Version:  ${VERSION}"
echo "  Channel:  ${CHANNEL}"
echo "  Date:     ${RELEASE_DATE}"
echo ""
echo "  URLs:"
echo "    https://get.cubeos.app/channels/${CHANNEL}.json"
echo "    https://get.cubeos.app/channels/latest.json"
echo "============================================================"
