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

echo "=== [04] CubeOS Setup (alpha.6) ==="

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
    dozzle ollama chromadb registry
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
# AI/ML Ports (6030-6039)
# ===================
OLLAMA_PORT=6030
CHROMADB_PORT=6031
DOCS_INDEXER_PORT=6032

# ===================
# AI Service Endpoints
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

# Cleanup packer temp
rm -rf "$BUNDLE_SRC"

# ---------------------------------------------------------------------------
# Install first-boot scripts from /tmp/cubeos-firstboot/
# ---------------------------------------------------------------------------
echo "[04] Installing first-boot scripts..."

cp /tmp/cubeos-firstboot/cubeos-first-boot.sh       /usr/local/bin/
cp /tmp/cubeos-firstboot/cubeos-normal-boot.sh       /usr/local/bin/
cp /tmp/cubeos-firstboot/cubeos-boot-detect.sh       /usr/local/bin/
cp /tmp/cubeos-firstboot/cubeos-generate-secrets.sh  /usr/local/bin/
cp /tmp/cubeos-firstboot/cubeos-generate-ap-creds.sh /usr/local/bin/
cp /tmp/cubeos-firstboot/cubeos-deploy-stacks.sh     /usr/local/bin/

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
10.42.24.1 logs.cubeos.cube
10.42.24.1 ollama.cubeos.cube
10.42.24.1 registry.cubeos.cube
10.42.24.1 docs.cubeos.cube
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
