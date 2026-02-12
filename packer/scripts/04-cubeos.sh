#!/bin/bash
# =============================================================================
# 04-cubeos.sh — CubeOS directory structure and configuration
# =============================================================================
# Creates /cubeos directory tree, installs config templates, copies coreapps
# compose files, and installs first-boot scripts.
# =============================================================================
set -euo pipefail

echo "=== [04] CubeOS Setup ==="

# ---------------------------------------------------------------------------
# Directory structure
# ---------------------------------------------------------------------------
echo "[04] Creating CubeOS directory structure..."

mkdir -p /cubeos/{config,data,mounts}
mkdir -p /cubeos/coreapps/{pihole,npm,cubeos-api,cubeos-hal,cubeos-dashboard}/{appconfig,appdata}
mkdir -p /cubeos/data/registry
mkdir -p /cubeos/config/vpn/{wireguard,openvpn}
mkdir -p /cubeos/apps

# Correct ownership
chown -R root:root /cubeos
chmod 755 /cubeos

# ---------------------------------------------------------------------------
# Default configuration — /cubeos/config/defaults.env
# ---------------------------------------------------------------------------
echo "[04] Writing defaults.env..."

cat > /cubeos/config/defaults.env << 'DEFAULTS'
# =============================================================================
# CubeOS Default Configuration
# Generated at image build time. Overridden by first-boot and wizard.
# =============================================================================

# --- Core ---
CUBEOS_VERSION=0.1.0-alpha
CUBEOS_DOMAIN=cubeos.cube
CUBEOS_GATEWAY_IP=10.42.24.1
CUBEOS_SUBNET=10.42.24.0/24
CUBEOS_DHCP_START=10.42.24.10
CUBEOS_DHCP_END=10.42.24.250

# --- Timezone ---
TZ=UTC

# --- Networking ---
CUBEOS_NETWORK_MODE=OFFLINE
CUBEOS_AP_INTERFACE=wlan0
CUBEOS_UPSTREAM_INTERFACE=eth0

# --- Ports (strict allocation) ---
PIHOLE_WEB_PORT=6001
NPM_ADMIN_PORT=6000
API_PORT=6010
DASHBOARD_PORT=6011
DOZZLE_PORT=6012
WIREGUARD_PORT=6020
OPENVPN_PORT=6021
TOR_PORT=6022
OLLAMA_PORT=6030
CHROMADB_PORT=6031
REGISTRY_PORT=5000

# --- Pi-hole ---
PIHOLE_PASSWORD=cubeos
PIHOLE_DNS=1.1.1.1;8.8.8.8
PIHOLE_INTERFACE=wlan0
PIHOLE_DHCP=true

# --- NPM ---
NPM_ADMIN_EMAIL=admin@cubeos.cube

# --- Docker ---
DOCKER_REGISTRY=ghcr.io/cubeos-app
DEFAULTS

# ---------------------------------------------------------------------------
# Coreapps Docker Compose files
# ---------------------------------------------------------------------------
echo "[04] Writing coreapps compose files..."

# ─── Pi-hole (Docker Compose — host network required for DHCP) ──────────
cat > /cubeos/coreapps/pihole/appconfig/docker-compose.yml << 'PIHOLE'
version: "3.8"
services:
  pihole:
    container_name: cubeos-pihole
    image: pihole/pihole:latest
    network_mode: host
    restart: unless-stopped
    environment:
      - TZ=${TZ:-UTC}
      - WEBPASSWORD=${PIHOLE_PASSWORD:-cubeos}
      - FTLCONF_LOCAL_IPV4=10.42.24.1
      - WEB_PORT=6001
      - DNSMASQ_LISTENING=all
      - PIHOLE_DNS_=1.1.1.1;8.8.8.8
      - DHCP_ACTIVE=true
      - DHCP_START=10.42.24.10
      - DHCP_END=10.42.24.250
      - DHCP_ROUTER=10.42.24.1
      - PIHOLE_DOMAIN=cubeos.cube
    volumes:
      - /cubeos/coreapps/pihole/appdata/etc-pihole:/etc/pihole
      - /cubeos/coreapps/pihole/appdata/etc-dnsmasq.d:/etc/dnsmasq.d
    cap_add:
      - NET_ADMIN
    healthcheck:
      test: ["CMD", "dig", "+short", "+norecurse", "+retry=0", "@127.0.0.1", "pi.hole"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
PIHOLE

# ─── Pi-hole .env ──────────────────────────────────────────────────────
cat > /cubeos/coreapps/pihole/appconfig/.env << 'PIHOLE_ENV'
TZ=UTC
PIHOLE_PASSWORD=cubeos
PIHOLE_ENV

# ─── NPM (Docker Compose — host network for ports 80/443) ──────────────
cat > /cubeos/coreapps/npm/appconfig/docker-compose.yml << 'NPM'
version: "3.8"
services:
  npm:
    container_name: cubeos-npm
    image: jc21/nginx-proxy-manager:latest
    network_mode: host
    restart: unless-stopped
    environment:
      - TZ=${TZ:-UTC}
      - DB_SQLITE_FILE=/data/database.sqlite
    volumes:
      - /cubeos/coreapps/npm/appdata/data:/data
      - /cubeos/coreapps/npm/appdata/letsencrypt:/etc/letsencrypt
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:81/api/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
NPM

# ─── CubeOS API (Swarm stack) ──────────────────────────────────────────
cat > /cubeos/coreapps/cubeos-api/appconfig/docker-compose.yml << 'API'
version: "3.8"
services:
  cubeos-api:
    image: ghcr.io/cubeos-app/api:latest
    ports:
      - "6010:6010"
    environment:
      - TZ=${TZ:-UTC}
      - CUBEOS_DB_PATH=/data/cubeos.db
      - CUBEOS_CONFIG_PATH=/config
      - CUBEOS_DOMAIN=cubeos.cube
      - CUBEOS_GATEWAY_IP=10.42.24.1
      - CUBEOS_HAL_URL=http://10.42.24.1:6013
      - CUBEOS_PORT=6010
      - CUBEOS_JWT_SECRET_FILE=/run/secrets/jwt_secret
    volumes:
      - /cubeos/data:/data
      - /cubeos/config:/config:ro
      - /var/run/docker.sock:/var/run/docker.sock
      - /cubeos/coreapps:/cubeos/coreapps:ro
    deploy:
      mode: replicated
      replicas: 1
      restart_policy:
        condition: any
        delay: 5s
      resources:
        limits:
          memory: 256M
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:6010/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
API

# ─── CubeOS HAL (Docker Compose — needs host network for hardware) ─────
cat > /cubeos/coreapps/cubeos-hal/appconfig/docker-compose.yml << 'HAL'
version: "3.8"
services:
  cubeos-hal:
    container_name: cubeos-hal
    image: ghcr.io/cubeos-app/hal:latest
    network_mode: host
    privileged: true
    restart: unless-stopped
    environment:
      - TZ=${TZ:-UTC}
      - HAL_PORT=6013
      - HAL_HOST=0.0.0.0
    volumes:
      - /sys:/sys:ro
      - /proc:/proc:ro
      - /dev:/dev
      - /run/dbus:/run/dbus:ro
      - /etc/hostapd:/etc/hostapd
      - /var/run/wpa_supplicant:/var/run/wpa_supplicant
      - /cubeos:/cubeos
      - /tmp:/tmp
      - /:/host:ro
    cap_add:
      - NET_ADMIN
      - SYS_RAWIO
      - SYS_ADMIN
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:6013/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s
HAL

# ─── CubeOS Dashboard (Swarm stack) ────────────────────────────────────
cat > /cubeos/coreapps/cubeos-dashboard/appconfig/docker-compose.yml << 'DASH'
version: "3.8"
services:
  cubeos-dashboard:
    image: ghcr.io/cubeos-app/dashboard:latest
    ports:
      - "6011:80"
    environment:
      - TZ=${TZ:-UTC}
      - VITE_API_URL=http://cubeos.cube:6010
    deploy:
      mode: replicated
      replicas: 1
      restart_policy:
        condition: any
        delay: 5s
      resources:
        limits:
          memory: 128M
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:80/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
DASH

# ---------------------------------------------------------------------------
# Install first-boot scripts from /tmp/cubeos-firstboot/
# ---------------------------------------------------------------------------
echo "[04] Installing first-boot scripts..."

cp /tmp/cubeos-firstboot/cubeos-first-boot.sh    /usr/local/bin/
cp /tmp/cubeos-firstboot/cubeos-normal-boot.sh    /usr/local/bin/
cp /tmp/cubeos-firstboot/cubeos-boot-detect.sh    /usr/local/bin/
cp /tmp/cubeos-firstboot/cubeos-generate-secrets.sh /usr/local/bin/
cp /tmp/cubeos-firstboot/cubeos-generate-ap-creds.sh /usr/local/bin/

chmod +x /usr/local/bin/cubeos-*.sh

# ---------------------------------------------------------------------------
# Install config templates from /tmp/cubeos-configs/
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
echo "10.42.24.1 cubeos.cube" > /cubeos/coreapps/pihole/appdata/etc-pihole/hosts/custom.list

# ---------------------------------------------------------------------------
# MOTD — show CubeOS info on SSH login
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
