#!/bin/bash
# =============================================================================
# 04-cubeos.sh — CubeOS directory structure and configuration
# =============================================================================
# Creates /cubeos directory tree, installs config, copies coreapps compose
# files FROM THE COREAPPS BUNDLE (cloned from GitLab at CI time), writes
# Swarm-compatible daemon.json, and installs first-boot scripts.
#
# v4 (alpha.6):
#   - NO MORE HEREDOCS for compose files — uses coreapps-bundle from CI
#   - Swarm-compatible daemon.json (no live-restore!)
#   - defaults.env matches Pi 5 production format
#   - Additional coreapps directories for all services
#   - Symlink /cubeos/scripts -> /cubeos/coreapps/scripts
# =============================================================================
set -euo pipefail

echo "=== [04] CubeOS Setup (alpha.18) ==="

# ---------------------------------------------------------------------------
# B44: Check for hwclock (util-linux-extra)
# The base image should include this. If missing, warn and continue —
# the packer chroot has no DNS so apt-get won't work here.
# hwclock is only needed at runtime for RTC sync, not for image build.
# ---------------------------------------------------------------------------
echo "[04] Verifying hwclock (util-linux-extra)..."
if command -v hwclock &>/dev/null; then
    echo "[04]   hwclock: OK ($(command -v hwclock))"
else
    echo "[04]   WARNING: hwclock not found (util-linux-extra missing from base image)"
    echo "[04]   RTC sync will not work at runtime. Rebuild base image to fix."
fi

# ---------------------------------------------------------------------------
# Version — injected by CI pipeline, falls back to dev
# ---------------------------------------------------------------------------
CUBEOS_VERSION="${CUBEOS_VERSION:-0.0.0-dev}"
echo "[04] Building CubeOS version: ${CUBEOS_VERSION}"

# ---------------------------------------------------------------------------
# Directory structure
# ---------------------------------------------------------------------------
echo "[04] Creating CubeOS directory structure..."

mkdir -p /cubeos/{config,data,mounts,apps,docs}
mkdir -p /cubeos/data/registry
mkdir -p /cubeos/config/vpn/{wireguard,openvpn}

# Create coreapps directories for ALL services (matching Pi 5)
COREAPPS=(
    pihole npm cubeos-api cubeos-hal cubeos-dashboard
    dozzle registry kiwix
    cubeos-docsindex cubeos-filebrowser
    wireguard openvpn tor
    diagnostics reset terminal backup watchdog
)
for svc in "${COREAPPS[@]}"; do
    mkdir -p "/cubeos/coreapps/${svc}/"{appconfig,appdata}
done
mkdir -p /cubeos/coreapps/scripts
mkdir -p /cubeos/data/watchdog
mkdir -p /cubeos/alerts
mkdir -p /cubeos/static

# Correct ownership
chown -R root:root /cubeos
chmod 755 /cubeos

# Symlink for backward compatibility
ln -sf /cubeos/coreapps/scripts /cubeos/scripts

# ---------------------------------------------------------------------------
# Docker daemon.json — SWARM COMPATIBLE (no live-restore!)
# ---------------------------------------------------------------------------
# CRITICAL: live-restore:true is INCOMPATIBLE with Docker Swarm since 1.12.
# This was Bug #1 in alpha.5. Only set default-address-pools.
# Alpha.9: Pin overlay2 to ensure CI-preloaded storage is always used
# (Docker 29+ may default to containerd image store on fresh installs).
# ---------------------------------------------------------------------------
echo "[04] Writing Swarm-compatible daemon.json..."

mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'DAEMON'
{
  "storage-driver": "overlay2",
  "default-address-pools": [
    {"base": "172.16.0.0/12", "size": 24}
  ]
}
DAEMON

# ---------------------------------------------------------------------------
# Default configuration — /cubeos/config/defaults.env
# ---------------------------------------------------------------------------
echo "[04] Writing defaults.env (version=${CUBEOS_VERSION})..."

cat > /cubeos/config/defaults.env << DEFAULTS
# CubeOS Default Configuration
# This file is sourced by all coreapps
# Generated at image build time: $(date -u +%Y-%m-%dT%H:%M:%SZ)

# ===================
# System Settings
# ===================
CUBEOS_VERSION=${CUBEOS_VERSION}
CUBEOS_COUNTRY_CODE=\${CUBEOS_COUNTRY_CODE:-US}
TZ=UTC
DOMAIN=cubeos.cube

# ===================
# Network Configuration
# ===================
GATEWAY_IP=10.42.24.1
SUBNET=10.42.24.0/24
DHCP_RANGE_START=10.42.24.10
DHCP_RANGE_END=10.42.24.250

# ===================
# Database (REQUIRED for API)
# ===================
DATABASE_PATH=/cubeos/data/cubeos.db

# ===================
# Infrastructure Ports (6000-6009)
# ===================
NPM_PORT=81
PIHOLE_PORT=6001
REGISTRY_PORT=5000

# ===================
# Platform Ports (6010-6019)
# ===================
API_PORT=6010
DASHBOARD_PORT=6011
DOZZLE_PORT=6012

# ===================
# Network Ports (6020-6029)
# ===================
WIREGUARD_PORT=6020
OPENVPN_PORT=6021
TOR_PORT=6022

# ===================
# AI/ML Ports (6030-6039) — services disabled but ports reserved
# ===================
OLLAMA_PORT=6030
CHROMADB_PORT=6031
DOCS_INDEXER_PORT=6032

# ===================
# AI Service Endpoints — services disabled but defaults set
# ===================
OLLAMA_HOST=10.42.24.1
CHROMADB_HOST=10.42.24.1

# ===================
# User Apps (6100-6999)
# ===================
USER_PORT_START=6100
USER_PORT_END=6999

# ===================
# Directory Paths
# ===================
CUBEOS_DATA_DIR=/cubeos/data
CUBEOS_CONFIG_DIR=/cubeos/config
CUBEOS_APPS_DIR=/cubeos/apps
CUBEOS_COREAPPS_DIR=/cubeos/coreapps
CUBEOS_MOUNTS_DIR=/cubeos/mounts
DEFAULTS

chmod 444 /cubeos/config/defaults.env

# ---------------------------------------------------------------------------
# Hostname
# ---------------------------------------------------------------------------
echo "[04] Setting hostname to cubeos..."
echo "cubeos" > /etc/hostname
hostnamectl set-hostname cubeos 2>/dev/null || true

# ---------------------------------------------------------------------------
# Coreapps — copy from CI-cloned bundle (NO MORE HEREDOCS!)
# ---------------------------------------------------------------------------
# The coreapps-bundle was cloned from the cubeos/coreapps GitLab repo at
# CI pipeline time and injected via packer file provisioner to /tmp/cubeos-coreapps/.
# This ensures compose files ALWAYS match what's running on Pi 5 production.
# ---------------------------------------------------------------------------
echo "[04] Installing coreapps from GitLab bundle..."

BUNDLE_SRC="/tmp/cubeos-coreapps"

if [ -d "$BUNDLE_SRC" ]; then
    COPIED=0
    SKIPPED=0

    for svc_dir in "$BUNDLE_SRC"/*/; do
        svc=$(basename "$svc_dir")
        target="/cubeos/coreapps/${svc}"

        # Copy appconfig (compose files, .env)
        if [ -d "${svc_dir}appconfig" ]; then
            mkdir -p "${target}/appconfig"
            cp -r "${svc_dir}appconfig/"* "${target}/appconfig/" 2>/dev/null || true
            echo "[04]   Installed: ${svc}/appconfig/"
            COPIED=$((COPIED + 1))
        fi

        # Copy appdata (pre-populated data like Ollama models)
        if [ -d "${svc_dir}appdata" ]; then
            mkdir -p "${target}/appdata"
            cp -r "${svc_dir}appdata/"* "${target}/appdata/" 2>/dev/null || true
            echo "[04]   Installed: ${svc}/appdata/"
        fi

        # Copy scripts (watchdog, deploy, init-swarm, etc.)
        if [ -d "${svc_dir}scripts" ] || [ "$svc" = "scripts" ]; then
            # Handle both coreapps/scripts/ dir and coreapps/*/scripts/ subdirs
            if [ -d "${svc_dir}" ] && [ "$svc" = "scripts" ]; then
                cp -r "${svc_dir}"* /cubeos/coreapps/scripts/ 2>/dev/null || true
                chmod +x /cubeos/coreapps/scripts/*.sh 2>/dev/null || true
                echo "[04]   Installed: coreapps/scripts/"
            fi
        fi

        # Copy src (HAL openapi.yaml etc.) — read-only reference
        if [ -d "${svc_dir}src" ]; then
            mkdir -p "${target}/src"
            cp -r "${svc_dir}src/"* "${target}/src/" 2>/dev/null || true
        fi
    done

    # Handle top-level scripts directory if it exists in the bundle
    if [ -d "${BUNDLE_SRC}/scripts" ]; then
        cp -r "${BUNDLE_SRC}/scripts/"* /cubeos/coreapps/scripts/ 2>/dev/null || true
        chmod +x /cubeos/coreapps/scripts/*.sh 2>/dev/null || true
        echo "[04]   Installed: scripts/ (top-level)"
    fi

    # Handle top-level files (defaults.env, deploy-coreapps.sh, etc.)
    for f in "${BUNDLE_SRC}"/*.sh "${BUNDLE_SRC}"/*.env; do
        [ -f "$f" ] || continue
        cp "$f" /cubeos/coreapps/
        chmod +x /cubeos/coreapps/*.sh 2>/dev/null || true
    done

    echo "[04] Coreapps bundle installed (${COPIED} services)"
else
    echo "[04] WARNING: No coreapps bundle found at ${BUNDLE_SRC}"
    echo "[04] Compose files will need to be deployed via CI on first connect."
fi

# B05: Handle docs bundle explicitly (bare .md files, not standard appconfig structure)
# Strategy: Create placeholder FIRST (guaranteed), then overlay with real docs.
# This fixes 3-alpha carry-over where all fallback chains silently failed.
echo "[04] Populating /cubeos/docs/..."
mkdir -p /cubeos/docs

# Step 0: ALWAYS create placeholder first (guaranteed baseline)
cat > /cubeos/docs/README.md << 'PLACEHOLDER'
# CubeOS Documentation

Welcome to CubeOS — your self-hosted server operating system.

## Quick Start

1. Open your browser and navigate to `http://cubeos.cube`
2. Complete the setup wizard
3. Start installing apps from the App Store

## Key Features

- **Offline-first**: Works without internet connectivity
- **Docker Swarm**: Self-healing container orchestration
- **WiFi Access Point**: Built-in hotspot for device connections
- **Web Dashboard**: Manage everything from your browser

## Links

- GitHub: https://github.com/cubeos-app
- Documentation: https://docs.cubeos.app
PLACEHOLDER
echo "[04]   Placeholder README.md created (guaranteed baseline)"

# Step 1: Try to overlay with real docs from coreapps bundle
if [ -d "${BUNDLE_SRC}/docs" ] && [ "$(ls -A "${BUNDLE_SRC}/docs" 2>/dev/null)" ]; then
    find "${BUNDLE_SRC}/docs" -maxdepth 1 -name '*.md' -exec cp {} /cubeos/docs/ \; 2>/dev/null || true
    find "${BUNDLE_SRC}/docs" -mindepth 1 -maxdepth 1 -type d ! -name '.git' -exec cp -r {} /cubeos/docs/ \; 2>/dev/null || true
    DOCS_COUNT=$(find /cubeos/docs -name '*.md' 2>/dev/null | wc -l)
    echo "[04]   Pre-populated ${DOCS_COUNT} docs from coreapps bundle"
else
    echo "[04]   No docs in coreapps bundle (${BUNDLE_SRC}/docs not found or empty)"
fi

# Cleanup packer temp
rm -rf "$BUNDLE_SRC"

# ---------------------------------------------------------------------------
# Additional docs sources (overlay on top of guaranteed placeholder)
# ---------------------------------------------------------------------------
DOCS_COUNT=$(find /cubeos/docs -name '*.md' 2>/dev/null | wc -l)
# Only try additional sources if we just have the placeholder (1 file)
if [ "$DOCS_COUNT" -le 1 ]; then
    # Try coreapps/docs if it exists
    if [ -d "/cubeos/coreapps/docs" ] && [ "$(ls -A /cubeos/coreapps/docs 2>/dev/null)" ]; then
        echo "[04] Overlaying /cubeos/docs from coreapps/docs..."
        cp -r /cubeos/coreapps/docs/* /cubeos/docs/ 2>/dev/null || true
        DOCS_COUNT=$(find /cubeos/docs -name '*.md' 2>/dev/null | wc -l)
        echo "[04]   Now ${DOCS_COUNT} markdown files"
    fi
fi
if [ "$DOCS_COUNT" -le 1 ] && [ -d "/tmp/cubeos-docs" ]; then
    echo "[04] Overlaying /cubeos/docs from Packer provisioner..."
    cp -r /tmp/cubeos-docs/* /cubeos/docs/ 2>/dev/null || true
    rm -rf /tmp/cubeos-docs
    DOCS_COUNT=$(find /cubeos/docs -name '*.md' 2>/dev/null | wc -l)
    echo "[04]   Now ${DOCS_COUNT} markdown files"
fi
if [ "$DOCS_COUNT" -le 1 ]; then
    echo "[04] Attempting git clone for docs..."
    if command -v git &>/dev/null; then
        git clone --depth=1 https://github.com/cubeos-app/docs.git /tmp/cubeos-docs-clone 2>/dev/null || true
        if [ -d "/tmp/cubeos-docs-clone" ]; then
            find /tmp/cubeos-docs-clone -name '*.md' -exec cp {} /cubeos/docs/ \; 2>/dev/null || true
            rm -rf /tmp/cubeos-docs-clone
            DOCS_COUNT=$(find /cubeos/docs -name '*.md' 2>/dev/null | wc -l)
        fi
    fi
fi
echo "[04] Final docs count: ${DOCS_COUNT} files in /cubeos/docs/"
# B05 verification: this should NEVER be 0 now
if [ "$DOCS_COUNT" -eq 0 ]; then
    echo "[04] ERROR: /cubeos/docs/ is empty despite placeholder! Filesystem issue?"
    ls -la /cubeos/docs/ 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Install static web assets from /tmp/cubeos-static/
# ---------------------------------------------------------------------------
echo "[04] Installing static web assets..."

if [ -d /tmp/cubeos-static ]; then
    cp -r /tmp/cubeos-static/* /cubeos/static/ 2>/dev/null || true
    STATIC_COUNT=$(find /cubeos/static -type f 2>/dev/null | wc -l)
    echo "[04]   Installed ${STATIC_COUNT} static files to /cubeos/static/"
fi

# ---------------------------------------------------------------------------
# Install first-boot scripts from /tmp/cubeos-firstboot/
# ---------------------------------------------------------------------------
echo "[04] Installing first-boot scripts..."

cp /tmp/cubeos-firstboot/cubeos-boot-lib.sh         /usr/local/bin/
cp /tmp/cubeos-firstboot/cubeos-first-boot.sh       /usr/local/bin/
cp /tmp/cubeos-firstboot/cubeos-normal-boot.sh       /usr/local/bin/
cp /tmp/cubeos-firstboot/cubeos-boot-detect.sh       /usr/local/bin/
cp /tmp/cubeos-firstboot/cubeos-generate-secrets.sh  /usr/local/bin/
cp /tmp/cubeos-firstboot/cubeos-generate-ap-creds.sh /usr/local/bin/
cp /tmp/cubeos-firstboot/cubeos-deploy-stacks.sh     /usr/local/bin/
cp /tmp/cubeos-firstboot/cubeos-diagnose.sh          /usr/local/bin/

chmod +x /usr/local/bin/cubeos-*.sh

# ---------------------------------------------------------------------------
# Config templates
# ---------------------------------------------------------------------------
echo "[04] Installing config templates..."

if [ -d /tmp/cubeos-configs ]; then
    cp -r /tmp/cubeos-configs/* /cubeos/config/ 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Pi-hole custom DNS — seed cubeos.cube resolution
# ---------------------------------------------------------------------------
echo "[04] Seeding Pi-hole custom DNS..."
mkdir -p /cubeos/coreapps/pihole/appdata/etc-pihole/hosts
cat > /cubeos/coreapps/pihole/appdata/etc-pihole/hosts/custom.list << 'DNS'
10.42.24.1 cubeos.cube
10.42.24.1 api.cubeos.cube
10.42.24.1 npm.cubeos.cube
10.42.24.1 pihole.cubeos.cube
10.42.24.1 hal.cubeos.cube
10.42.24.1 dozzle.cubeos.cube
10.42.24.1 registry.cubeos.cube
10.42.24.1 docs.cubeos.cube
10.42.24.1 terminal.cubeos.cube
10.42.24.1 kiwix.cubeos.cube
DNS

# ---------------------------------------------------------------------------
# MOTD
# ---------------------------------------------------------------------------
echo "[04] Writing login banner..."

cat > /etc/motd << 'MOTD'

   ██████╗██╗   ██╗██████╗ ███████╗ ██████╗ ███████╗
  ██╔════╝██║   ██║██╔══██╗██╔════╝██╔═══██╗██╔════╝
  ██║     ██║   ██║██████╔╝█████╗  ██║   ██║███████╗
  ██║     ██║   ██║██╔══██╗██╔══╝  ██║   ██║╚════██║
  ╚██████╗╚██████╔╝██████╔╝███████╗╚██████╔╝███████║
   ╚═════╝ ╚═════╝ ╚═════╝ ╚══════╝ ╚═════╝ ╚══════╝
  
  Dashboard:  http://cubeos.cube  or  http://10.42.24.1
  API:        http://cubeos.cube:6010/health
  Docs:       https://github.com/cubeos-app

MOTD

echo "[04] CubeOS setup complete."
