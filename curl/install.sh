#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# CubeOS Curl Installer
# Usage: curl -fsSL https://get.cubeos.app | sudo bash
#
# Installs CubeOS as Tier 2 (container mode) on any Linux system.
# Docker Swarm single-node, all services via Docker Compose.
# ═══════════════════════════════════════════════════════════════════════════════

CUBEOS_INSTALLER_VERSION="0.2.0-beta.05"
CUBEOS_VERSION="0.2.0-beta.05"

# ─── Globals (set during pre-flight) ─────────────────────────────────────────
ARCH=""
OS_ID=""
OS_ID_LIKE=""
OS_VERSION_CODENAME=""
PKG_MANAGER=""
DOCKER_REPO_DISTRO=""
SELECTED_IP=""
PIHOLE_DNS_PORT="${PIHOLE_DNS_PORT:-53}"
NPM_HTTP_PORT="${NPM_HTTP_PORT:-80}"
NPM_HTTPS_PORT="${NPM_HTTPS_PORT:-443}"
RESOLVE_DNS_ACTION=""  # "disable", "alternate", "skip"
CUBEOS_WIFI_MANAGED="false"
CUBEOS_AIRGAP_DIR="${CUBEOS_AIRGAP_DIR:-/cubeos/images}"
ADMIN_PASSWORD=""
PIHOLE_PASSWORD=""
NPM_PASSWORD=""
JWT_SECRET=""

# ─── Output helpers ───────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
log_ok()      { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
log_warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
log_error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
log_fatal()   { log_error "$@"; exit 1; }
log_step()    { printf "\n${BOLD}── %s${NC}\n" "$*"; }

prompt_user() {
    local prompt="$1"
    local default="$2"
    local answer=""
    if [ -e /dev/tty ]; then
        printf "%s" "$prompt" > /dev/tty
        read -r answer < /dev/tty
    fi
    if [ -z "$answer" ]; then
        echo "$default"
    else
        echo "$answer"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-02: Pre-flight — root, arch, OS
# ═══════════════════════════════════════════════════════════════════════════════

preflight_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_fatal "Run with sudo: curl -fsSL https://get.cubeos.app | sudo bash"
    fi
    log_ok "Running as root"
}

preflight_arch() {
    local raw_arch
    raw_arch="$(uname -m)"
    case "$raw_arch" in
        aarch64) ARCH="arm64" ;;
        x86_64)  ARCH="amd64" ;;
        *)       log_fatal "Unsupported architecture: $raw_arch (need aarch64 or x86_64)" ;;
    esac
    log_ok "Architecture: $raw_arch ($ARCH)"
}

preflight_os() {
    if [ ! -f /etc/os-release ]; then
        log_fatal "Cannot detect OS — /etc/os-release not found"
    fi
    # shellcheck source=/dev/null
    . /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_ID_LIKE="${ID_LIKE:-}"
    OS_VERSION_CODENAME="${VERSION_CODENAME:-}"

    # Determine supported OS family and Docker repo distro
    case "$OS_ID" in
        ubuntu)
            DOCKER_REPO_DISTRO="ubuntu"
            ;;
        debian)
            DOCKER_REPO_DISTRO="debian"
            ;;
        raspbian|armbian)
            DOCKER_REPO_DISTRO="debian"
            ;;
        pop)
            DOCKER_REPO_DISTRO="ubuntu"
            ;;
        rhel|centos|rocky|almalinux)
            DOCKER_REPO_DISTRO="centos"
            ;;
        fedora)
            DOCKER_REPO_DISTRO="fedora"
            ;;
        *)
            # Check ID_LIKE for derivative distros
            if echo "$OS_ID_LIKE" | grep -qw "ubuntu"; then
                DOCKER_REPO_DISTRO="ubuntu"
            elif echo "$OS_ID_LIKE" | grep -qw "debian"; then
                DOCKER_REPO_DISTRO="debian"
            elif echo "$OS_ID_LIKE" | grep -qw "rhel\|centos\|fedora"; then
                DOCKER_REPO_DISTRO="centos"
            else
                log_fatal "Unsupported OS: $OS_ID (ID_LIKE=$OS_ID_LIKE). Supported: Ubuntu, Debian, Raspbian, Armbian, RHEL, CentOS, Rocky, Alma, Fedora"
            fi
            ;;
    esac

    log_ok "OS: $OS_ID ($DOCKER_REPO_DISTRO family), codename=$OS_VERSION_CODENAME"
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-03: Pre-flight — kernel, RAM, disk
# ═══════════════════════════════════════════════════════════════════════════════

preflight_kernel() {
    local kver major minor
    kver="$(uname -r)"
    major="${kver%%.*}"
    minor="${kver#*.}"
    minor="${minor%%[.-]*}"

    if [ "$major" -lt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -lt 19 ]; }; then
        log_fatal "Kernel $kver is too old. Minimum: 4.19"
    fi
    log_ok "Kernel: $kver"
}

preflight_ram() {
    local mem_kb
    mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    if [ "$mem_kb" -lt 1800000 ]; then
        local mem_mb=$((mem_kb / 1024))
        log_fatal "Insufficient RAM: ${mem_mb}MB. Minimum: 2GB"
    fi
    log_ok "RAM: $((mem_kb / 1024))MB"
}

preflight_disk() {
    local avail_kb
    avail_kb=$(df --output=avail / | tail -1 | tr -d ' ')
    if [ "$avail_kb" -lt 10485760 ]; then
        local avail_gb=$((avail_kb / 1048576))
        log_fatal "Insufficient disk: ${avail_gb}GB free. Minimum: 10GB"
    fi
    log_ok "Disk: $((avail_kb / 1048576))GB free"
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-04: Pre-flight — package manager
# ═══════════════════════════════════════════════════════════════════════════════

preflight_package_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
    else
        log_fatal "CubeOS requires apt (Debian/Ubuntu) or dnf (RHEL/Fedora)"
    fi
    log_ok "Package manager: $PKG_MANAGER"
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-05 + T7a-18: Pre-flight — port conflicts + DNS resolution
# ═══════════════════════════════════════════════════════════════════════════════

preflight_ports() {
    local port_in_use=false

    # Required ports — abort if in use
    for port in 6010 6011 5000; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            local proc
            proc=$(ss -tlnp 2>/dev/null | grep ":${port} " | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1)
            log_error "Port $port is in use by: ${proc:-unknown}"
            port_in_use=true
        fi
    done
    if [ "$port_in_use" = true ]; then
        log_fatal "Required ports (6010, 6011, 5000) must be free. Stop conflicting services and retry."
    fi
    log_ok "Required ports (6010, 6011, 5000) are available"

    # Port 53 — detect systemd-resolved
    if ss -tlnp 2>/dev/null | grep -q ":53 "; then
        local dns_proc
        dns_proc=$(ss -tlnp 2>/dev/null | grep ":53 " | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1)

        if [ "$dns_proc" = "systemd-resolve" ] || [ "$dns_proc" = "systemd-resolved" ]; then
            log_warn "Port 53 is in use by systemd-resolved"
            echo ""
            echo "  Port 53 is in use by systemd-resolved."
            echo "    [1] Disable systemd-resolved (recommended — Pi-hole replaces it)"
            echo "    [2] Run Pi-hole DNS on port 5300 (coexist)"
            echo "    [3] Skip Pi-hole DNS (containers use system DNS)"
            echo ""
            local choice
            choice=$(prompt_user "  Choice [1]: " "1")
            case "$choice" in
                2)
                    RESOLVE_DNS_ACTION="alternate"
                    PIHOLE_DNS_PORT=5300
                    log_info "Pi-hole DNS will use port 5300"
                    ;;
                3)
                    RESOLVE_DNS_ACTION="skip"
                    PIHOLE_DNS_PORT=0
                    log_info "Pi-hole DNS disabled — containers use system DNS"
                    ;;
                *)
                    RESOLVE_DNS_ACTION="disable"
                    log_info "systemd-resolved will be disabled before starting services"
                    ;;
            esac
        else
            log_warn "Port 53 is in use by: ${dns_proc:-unknown}. Pi-hole DNS may not start."
            PIHOLE_DNS_PORT=5300
        fi
    else
        log_ok "Port 53 is available"
    fi

    # Optional ports — warn only
    for port in 80 443; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            local proc
            proc=$(ss -tlnp 2>/dev/null | grep ":${port} " | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1)
            log_warn "Port $port is in use by: ${proc:-unknown}. NPM may not bind this port."
        fi
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-06: Pre-flight — LXC nesting
# ═══════════════════════════════════════════════════════════════════════════════

preflight_lxc() {
    if grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        log_warn "Running inside LXC container"
        if ! command -v docker &>/dev/null || ! docker info &>/dev/null 2>&1; then
            log_fatal "Docker cannot start in LXC. Enable nesting: pct set <VMID> -features nesting=1,keyctl=1"
        fi
        log_ok "LXC nesting verified — Docker works"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-07: Pre-flight — SELinux / AppArmor
# ═══════════════════════════════════════════════════════════════════════════════

preflight_security() {
    if command -v getenforce &>/dev/null; then
        local selinux_status
        selinux_status=$(getenforce 2>/dev/null || echo "unknown")
        if [ "$selinux_status" = "Enforcing" ]; then
            log_warn "SELinux is enforcing. CubeOS HAL may need permissive mode for hardware access."
        else
            log_info "SELinux: $selinux_status"
        fi
    fi
    if command -v aa-status &>/dev/null; then
        local profiles
        profiles=$(aa-status --profiled 2>/dev/null || echo "0")
        log_info "AppArmor: $profiles profiles loaded"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-08: Pre-flight — existing CubeOS
# ═══════════════════════════════════════════════════════════════════════════════

preflight_existing() {
    local existing=false
    if [ -f /cubeos/config/defaults.env ]; then
        existing=true
    fi
    if systemctl is-enabled cubeos.service &>/dev/null 2>&1; then
        existing=true
    fi
    if [ "$existing" = true ]; then
        local installed_ver="unknown"
        if [ -f /cubeos/config/defaults.env ]; then
            installed_ver=$(grep '^CUBEOS_VERSION=' /cubeos/config/defaults.env 2>/dev/null | cut -d= -f2 || echo "unknown")
        fi
        echo ""
        echo "  CubeOS v${installed_ver} is already installed."
        echo "    [1] Update to latest version"
        echo "    [2] Reinstall (preserves data)"
        echo "    [3] Uninstall CubeOS"
        echo "    [4] Exit"
        echo ""
        local choice
        choice=$(prompt_user "  Choice: " "4")
        case "$choice" in
            1)
                if command -v cubeos &>/dev/null; then
                    exec cubeos update
                else
                    log_error "cubeos CLI not found. Reinstall first (option 2)."
                    exit 1
                fi
                ;;
            2)
                log_info "Reinstalling CubeOS (preserving data)..."
                # Create config-only backup
                if command -v cubeos &>/dev/null; then
                    cubeos backup --exclude-data || true
                fi
                # Stop existing services
                docker compose -f /cubeos/docker-compose.yml down 2>/dev/null || true
                # Remove compose and systemd (will be regenerated)
                rm -f /cubeos/docker-compose.yml
                systemctl disable --now cubeos.service 2>/dev/null || true
                rm -f /etc/systemd/system/cubeos.service
                systemctl daemon-reload 2>/dev/null || true
                # DON'T exit — fall through to normal install flow
                # Secrets and dirs already exist, those functions are idempotent
                return 0
                ;;
            3)
                if command -v cubeos &>/dev/null; then
                    exec cubeos uninstall
                else
                    # Inline minimal uninstall
                    log_warn "cubeos CLI not found. Performing basic uninstall..."
                    docker compose -f /cubeos/docker-compose.yml down 2>/dev/null || true
                    docker swarm leave --force 2>/dev/null || true
                    systemctl disable --now cubeos.service 2>/dev/null || true
                    rm -f /etc/systemd/system/cubeos.service
                    systemctl daemon-reload 2>/dev/null || true
                    local remove_data
                    remove_data=$(prompt_user "  Remove /cubeos/data/? [y/N]: " "n")
                    if [ "$remove_data" = "y" ] || [ "$remove_data" = "Y" ]; then
                        rm -rf /cubeos/
                    else
                        rm -rf /cubeos/config /cubeos/coreapps /cubeos/apps /cubeos/mounts /cubeos/backups /cubeos/docker-compose.yml /cubeos/.manifest
                    fi
                    log_ok "CubeOS uninstalled."
                    exit 0
                fi
                ;;
            *) log_info "Exiting."; exit 0 ;;
        esac
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-09: Docker installation
# ═══════════════════════════════════════════════════════════════════════════════

install_docker() {
    log_step "Docker"

    # Skip if Docker already works
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        log_ok "Docker is already installed and running"
        return
    fi

    log_info "Installing Docker..."

    if [ "$PKG_MANAGER" = "apt" ]; then
        install_docker_apt
    elif [ "$PKG_MANAGER" = "dnf" ]; then
        install_docker_dnf
    fi

    # Start and enable Docker
    systemctl enable --now docker
    log_ok "Docker installed and started"
}

install_docker_apt() {
    # Remove old packages (ignore failures)
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Install prerequisites
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg

    # Add Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${DOCKER_REPO_DISTRO}/gpg" \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Determine codename — use host OS codename, falling back for derivatives
    local codename="$OS_VERSION_CODENAME"
    if [ -z "$codename" ]; then
        codename=$(lsb_release -cs 2>/dev/null || echo "")
    fi
    if [ -z "$codename" ]; then
        log_fatal "Cannot determine OS codename for Docker repo. Set VERSION_CODENAME in /etc/os-release"
    fi

    # Add Docker repo
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_REPO_DISTRO} ${codename} stable" \
        > /etc/apt/sources.list.d/docker.list

    # Install Docker
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

install_docker_dnf() {
    # Install prerequisites
    dnf install -y dnf-plugins-core

    # Add Docker repo
    dnf config-manager --add-repo "https://download.docker.com/linux/${DOCKER_REPO_DISTRO}/docker-ce.repo"

    # Install Docker
    dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-10: Docker version verification
# ═══════════════════════════════════════════════════════════════════════════════

verify_docker() {
    local version
    version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0.0.0")
    local major="${version%%.*}"

    if [ "$major" -lt 20 ]; then
        log_fatal "Docker 20+ required. Found: $version"
    fi
    log_ok "Docker version: $version"

    # Verify compose plugin
    if ! docker compose version &>/dev/null; then
        log_fatal "Docker Compose plugin not found. Install: apt install docker-compose-plugin"
    fi
    log_ok "Docker Compose: $(docker compose version --short 2>/dev/null)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-11: Swarm init with IP selection
# ═══════════════════════════════════════════════════════════════════════════════

init_swarm() {
    log_step "Docker Swarm"

    # Skip if already in Swarm
    local swarm_state
    swarm_state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "inactive")
    if [ "$swarm_state" = "active" ]; then
        log_ok "Swarm already active"
        # Still need to get the advertise IP
        SELECTED_IP=$(docker info --format '{{.Swarm.NodeAddr}}' 2>/dev/null || echo "")
        if [ -z "$SELECTED_IP" ]; then
            select_ip
        fi
        return
    fi

    select_ip

    log_info "Initializing Swarm on $SELECTED_IP..."
    docker swarm init --advertise-addr "$SELECTED_IP"
    log_ok "Swarm initialized"
}

select_ip() {
    local -a ips
    local line
    while IFS= read -r line; do
        ips+=("$line")
    done < <(ip -4 addr show | awk '/inet / && !/127\.0\.0\.1/ && !/docker/ && !/br-/ && !/veth/' | awk '{print $2}' | cut -d/ -f1)

    if [ ${#ips[@]} -eq 0 ]; then
        log_fatal "No non-loopback IPv4 address found"
    elif [ ${#ips[@]} -eq 1 ]; then
        SELECTED_IP="${ips[0]}"
        log_ok "Using IP: $SELECTED_IP"
    else
        echo ""
        echo "  Multiple IP addresses detected:"
        for i in "${!ips[@]}"; do
            echo "    [$((i + 1))] ${ips[$i]}"
        done
        echo ""
        local choice
        choice=$(prompt_user "  Select IP [1]: " "1")
        local idx=$((choice - 1))
        if [ "$idx" -lt 0 ] || [ "$idx" -ge ${#ips[@]} ]; then
            idx=0
        fi
        SELECTED_IP="${ips[$idx]}"
        log_ok "Using IP: $SELECTED_IP"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-12: Swarm task history limit
# ═══════════════════════════════════════════════════════════════════════════════

configure_swarm() {
    docker swarm update --task-history-limit 1 2>/dev/null || true
    log_ok "Swarm task history limit set to 1"
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-13: Directory structure
# ═══════════════════════════════════════════════════════════════════════════════

create_directories() {
    log_step "Directory structure"

    local dirs=(
        /cubeos/config
        /cubeos/data
        /cubeos/data/registry
        /cubeos/coreapps
        /cubeos/coreapps/pihole/appdata/etc-pihole
        /cubeos/coreapps/npm/appdata/data
        /cubeos/coreapps/npm/appdata/letsencrypt
        /cubeos/coreapps/cubeos-hal/appdata
        /cubeos/apps
        /cubeos/mounts
        /cubeos/backups
        /cubeos/docs
        /cubeos/config/vpn
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
    done

    # Ensure D-Bus socket directory exists (for HAL)
    mkdir -p /run/dbus 2>/dev/null || true

    # Ensure journal directories exist (for HAL log access)
    mkdir -p /var/log/journal 2>/dev/null || true
    mkdir -p /run/log/journal 2>/dev/null || true

    chown -R root:root /cubeos
    chmod 755 /cubeos

    log_ok "Created /cubeos directory structure"
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-14: Secrets generation
# ═══════════════════════════════════════════════════════════════════════════════

generate_secrets() {
    log_step "Secrets"

    # Admin password — prompt or auto-generate
    if [ -n "${CUBEOS_ADMIN_PASSWORD:-}" ]; then
        ADMIN_PASSWORD="$CUBEOS_ADMIN_PASSWORD"
        log_ok "Admin password: from environment"
    elif [ -e /dev/tty ]; then
        echo ""
        local entered
        entered=$(prompt_user "  CubeOS Admin Password (press Enter to auto-generate): " "")
        if [ -n "$entered" ]; then
            ADMIN_PASSWORD="$entered"
            log_ok "Admin password: user-provided"
        else
            ADMIN_PASSWORD=$(openssl rand -base64 12)
            log_ok "Admin password: auto-generated"
        fi
    else
        ADMIN_PASSWORD=$(openssl rand -base64 12)
        log_ok "Admin password: auto-generated (non-interactive)"
    fi

    # Internal secrets — auto-generate or use env overrides
    NPM_PASSWORD="${CUBEOS_NPM_PASSWORD:-$(openssl rand -hex 16)}"
    PIHOLE_PASSWORD="${CUBEOS_PIHOLE_PASSWORD:-$(openssl rand -hex 16)}"
    JWT_SECRET="${CUBEOS_JWT_SECRET:-$(openssl rand -hex 32)}"

    # Write secrets file
    cat > /cubeos/config/secrets.env << EOF
CUBEOS_ADMIN_PASSWORD=${ADMIN_PASSWORD}
CUBEOS_NPM_PASSWORD=${NPM_PASSWORD}
CUBEOS_PIHOLE_PASSWORD=${PIHOLE_PASSWORD}
JWT_SECRET=${JWT_SECRET}
EOF
    chmod 600 /cubeos/config/secrets.env

    log_ok "Secrets written to /cubeos/config/secrets.env"
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-17: WiFi management opt-in
# ═══════════════════════════════════════════════════════════════════════════════

wifi_opt_in() {
    if ls /sys/class/net/*/wireless &>/dev/null 2>&1; then
        echo ""
        local choice
        choice=$(prompt_user "  WiFi hardware detected. Allow CubeOS to manage WiFi? [y/N]: " "n")
        case "$choice" in
            [Yy]*)
                CUBEOS_WIFI_MANAGED="true"
                log_ok "WiFi management: enabled"
                ;;
            *)
                CUBEOS_WIFI_MANAGED="false"
                log_ok "WiFi management: disabled"
                ;;
        esac
    else
        CUBEOS_WIFI_MANAGED="false"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-15: defaults.env generation
# ═══════════════════════════════════════════════════════════════════════════════

generate_defaults_env() {
    local tz
    tz=$(cat /etc/timezone 2>/dev/null || echo "UTC")

    cat > /cubeos/config/defaults.env << EOF
# CubeOS Tier 2 Configuration
# Generated by CubeOS installer v${CUBEOS_INSTALLER_VERSION}
CUBEOS_VERSION=${CUBEOS_VERSION}
CUBEOS_TIER=container
CUBEOS_ACCESS_PROFILE=standard
CUBEOS_NETWORK_MODE=eth_client
CUBEOS_WIFI_MANAGED=${CUBEOS_WIFI_MANAGED}
TZ=${tz}
DOMAIN=cubeos.cube

# Network
GATEWAY_IP=${SELECTED_IP}
SUBNET=10.42.24.0/24

# Infrastructure Ports (6000-6009)
NPM_PORT=6000
PIHOLE_PORT=6001
REGISTRY_PORT=5000

# Platform Ports (6010-6019)
API_PORT=6010
DASHBOARD_PORT=6011
DOZZLE_PORT=6012

# Configurable ports (resolved during install)
PIHOLE_DNS_PORT=${PIHOLE_DNS_PORT}
NPM_HTTP_PORT=${NPM_HTTP_PORT}
NPM_HTTPS_PORT=${NPM_HTTPS_PORT}

# AI/ML Ports (reserved)
OLLAMA_PORT=6030
CHROMADB_PORT=6031
DOCS_INDEXER_PORT=6032

# User Apps
USER_PORT_START=6100
USER_PORT_END=6999

# Directory Paths
CUBEOS_DATA_DIR=/cubeos/data
DATABASE_PATH=/cubeos/data/cubeos.db
CUBEOS_CONFIG_DIR=/cubeos/config
CUBEOS_APPS_DIR=/cubeos/apps
CUBEOS_COREAPPS_DIR=/cubeos/coreapps
CUBEOS_MOUNTS_DIR=/cubeos/mounts
EOF

    log_ok "Defaults written to /cubeos/config/defaults.env"
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-16: docker-compose.yml generation
# ═══════════════════════════════════════════════════════════════════════════════

generate_compose() {
    log_step "Docker Compose"

    # Source defaults for variable substitution
    set -a
    # shellcheck source=/dev/null
    . /cubeos/config/defaults.env
    # shellcheck source=/dev/null
    . /cubeos/config/secrets.env
    set +a

    # Export additional variables needed by template
    export GATEWAY_IP PIHOLE_DNS_PORT PIHOLE_PASSWORD
    export API_PORT="${API_PORT:-6010}"
    export DASHBOARD_PORT="${DASHBOARD_PORT:-6011}"
    export DOZZLE_PORT="${DOZZLE_PORT:-6012}"
    export DOCSINDEX_PORT="${DOCS_INDEXER_PORT:-6032}"
    export REGISTRY_PORT="${REGISTRY_PORT:-5000}"
    export TZ="${TZ:-UTC}"

    # Generate compose from embedded template
    generate_compose_template | envsubst \
        '${GATEWAY_IP} ${API_PORT} ${DASHBOARD_PORT} ${DOZZLE_PORT} ${DOCSINDEX_PORT} ${REGISTRY_PORT} ${PIHOLE_DNS_PORT} ${PIHOLE_PASSWORD} ${TZ}' \
        > /cubeos/docker-compose.yml

    log_ok "Compose file written to /cubeos/docker-compose.yml"
}

generate_compose_template() {
    cat << 'COMPOSE_EOF'
# CubeOS Tier 2 — Docker Compose
# Generated by CubeOS installer — do not edit directly.
# All services run as compose services (no Swarm stacks).
# Images pull from upstream registries (Docker Hub / GHCR).

name: cubeos

services:
  # ── Local Docker Registry (port 5000) ──────────────────────────────────────
  registry:
    image: registry:2
    container_name: cubeos-registry
    hostname: cubeos-registry
    restart: unless-stopped
    ports:
      - "${REGISTRY_PORT}:5000"
    volumes:
      - /cubeos/data/registry:/var/lib/registry
    environment:
      - REGISTRY_HTTP_ADDR=0.0.0.0:5000
      - REGISTRY_STORAGE_DELETE_ENABLED=true
    deploy:
      resources:
        limits:
          memory: 256M
        reservations:
          memory: 64M
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:5000/v2/"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    labels:
      - "cubeos.type=system"
      - "cubeos.category=infrastructure"
      - "cubeos.port=${REGISTRY_PORT}"
      - "cubeos.fqdn=registry.cubeos.cube"
      - "cubeos.deployment=compose"

  # ── Pi-hole DNS (host network, DHCP OFF) ───────────────────────────────────
  pihole:
    image: pihole/pihole:latest
    container_name: cubeos-pihole
    hostname: cubeos-pihole
    restart: unless-stopped
    network_mode: host
    volumes:
      - /cubeos/coreapps/pihole/appdata/etc-pihole:/etc/pihole
    environment:
      - TZ=${TZ}
      - FTLCONF_webserver_port=6001
      - FTLCONF_webserver_api_password=${PIHOLE_PASSWORD}
      - FTLCONF_dns_port=${PIHOLE_DNS_PORT}
      - FTLCONF_dns_listeningMode=all
      - FTLCONF_dns_upstreams=1.1.1.1;8.8.8.8
      - FTLCONF_dns_dnssec=false
      - FTLCONF_dns_domain_name=cubeos.cube
      - FTLCONF_dns_domain_local=true
      - FTLCONF_dns_domainNeeded=true
      - FTLCONF_dns_bogusPriv=true
      - FTLCONF_dns_expandHosts=false
      - FTLCONF_dhcp_active=false
      - FTLCONF_dns_replyWhenBusy=ALLOW
      - FTLCONF_dns_blocking_active=false
    env_file:
      - /cubeos/config/defaults.env
    cap_add:
      - NET_ADMIN
      - NET_RAW
    deploy:
      resources:
        limits:
          memory: 256M
        reservations:
          memory: 128M
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://127.0.0.1:6001/admin/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    labels:
      - "cubeos.type=system"
      - "cubeos.category=infrastructure"
      - "cubeos.port=6001"
      - "cubeos.fqdn=pihole.cubeos.cube"
      - "cubeos.deployment=compose"

  # ── Nginx Proxy Manager (host network) ─────────────────────────────────────
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: cubeos-npm
    hostname: cubeos-npm
    restart: unless-stopped
    network_mode: host
    volumes:
      - /cubeos/coreapps/npm/appdata/data:/data
      - /cubeos/coreapps/npm/appdata/letsencrypt:/etc/letsencrypt
    environment:
      - TZ=${TZ}
    env_file:
      - /cubeos/config/defaults.env
    deploy:
      resources:
        limits:
          memory: 256M
        reservations:
          memory: 64M
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://127.0.0.1:81/api/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    labels:
      - "cubeos.type=system"
      - "cubeos.category=infrastructure"
      - "cubeos.port=81"
      - "cubeos.fqdn=npm.cubeos.cube"
      - "cubeos.deployment=compose"

  # ── CubeOS HAL (host network, privileged, CUBEOS_TIER=container) ───────────
  cubeos-hal:
    image: ghcr.io/cubeos-app/hal:latest
    container_name: cubeos-hal
    restart: unless-stopped
    stop_grace_period: 15s
    network_mode: host
    pid: "host"
    privileged: true
    security_opt:
      - apparmor:unconfined
    cap_add:
      - NET_ADMIN
      - NET_RAW
      - SYS_ADMIN
      - SYS_PTRACE
      - SYS_RAWIO
    volumes:
      - /sys:/sys:rw
      - /proc:/proc:rw
      - /dev:/dev:rw
      - /run/dbus/system_bus_socket:/run/dbus/system_bus_socket
      - /var/log/journal:/var/log/journal:ro
      - /run/log/journal:/run/log/journal:ro
      - /cubeos/coreapps/cubeos-hal/appdata:/data
      - /cubeos/mounts:/cubeos/mounts
      - /cubeos/config/vpn:/cubeos/config/vpn
      - /etc/os-release:/host/etc/os-release:ro
    environment:
      - CUBEOS_TIER=container
      - HAL_PORT=6005
      - HAL_HOST=0.0.0.0
      - TZ=${TZ}
      - DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket
      - HAL_UPS_ENABLED=false
      - HAL_POWER_MONITOR_AUTOSTART=false
      - HAL_I2C_BUS=1
    env_file:
      - /cubeos/config/defaults.env
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:6005/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
    labels:
      - "cubeos.type=system"
      - "cubeos.port=6005"
      - "cubeos.deployment=compose"

  # ── CubeOS API Server (port 6010) ──────────────────────────────────────────
  cubeos-api:
    image: ghcr.io/cubeos-app/api:latest
    container_name: cubeos-api
    hostname: cubeos-api
    restart: unless-stopped
    ports:
      - "${API_PORT}:6010"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /cubeos:/cubeos
      - /sys:/sys:ro
      - /proc:/proc:ro
    environment:
      - TZ=${TZ}
      - CUBEOS_PORT=6010
      - CUBEOS_TIER=container
      - CUBEOS_DATA_DIR=/cubeos/data
      - CUBEOS_DB_PATH=/cubeos/data/cubeos.db
      - HAL_URL=http://${GATEWAY_IP}:6005/hal
    env_file:
      - /cubeos/config/defaults.env
      - /cubeos/config/secrets.env
    deploy:
      resources:
        limits:
          memory: 256M
        reservations:
          memory: 64M
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:6010/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    labels:
      - "cubeos.type=platform"
      - "cubeos.category=platform"
      - "cubeos.port=${API_PORT}"
      - "cubeos.fqdn=api.cubeos.cube"
      - "cubeos.deployment=compose"

  # ── CubeOS Dashboard (port 6011) ───────────────────────────────────────────
  cubeos-dashboard:
    image: ghcr.io/cubeos-app/dashboard:latest
    container_name: cubeos-dashboard
    hostname: cubeos-dashboard
    restart: unless-stopped
    ports:
      - "${DASHBOARD_PORT}:8087"
    environment:
      - TZ=${TZ}
      - API_URL=http://${GATEWAY_IP}:${API_PORT}
    env_file:
      - /cubeos/config/defaults.env
    deploy:
      resources:
        limits:
          memory: 64M
        reservations:
          memory: 32M
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:8087/"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    labels:
      - "cubeos.type=platform"
      - "cubeos.category=platform"
      - "cubeos.port=${DASHBOARD_PORT}"
      - "cubeos.fqdn=cubeos.cube"
      - "cubeos.deployment=compose"

  # ── Dozzle — Container Log Viewer (port 6012) ──────────────────────────────
  dozzle:
    image: amir20/dozzle:latest
    container_name: cubeos-dozzle
    hostname: cubeos-dozzle
    restart: unless-stopped
    ports:
      - "${DOZZLE_PORT}:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - TZ=${TZ}
      - DOZZLE_LEVEL=info
      - DOZZLE_TAILSIZE=300
      - DOZZLE_NO_ANALYTICS=true
    env_file:
      - /cubeos/config/defaults.env
    deploy:
      resources:
        limits:
          memory: 128M
        reservations:
          memory: 48M
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:8080/"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
    labels:
      - "cubeos.type=platform"
      - "cubeos.category=monitoring"
      - "cubeos.port=${DOZZLE_PORT}"
      - "cubeos.fqdn=dozzle.cubeos.cube"
      - "cubeos.deployment=compose"

  # ── CubeOS Document Indexer (port 6032) ─────────────────────────────────────
  cubeos-docsindex:
    image: ghcr.io/cubeos-app/cubeos-docsindex:latest
    container_name: cubeos-docsindex
    hostname: cubeos-docsindex
    restart: unless-stopped
    ports:
      - "${DOCSINDEX_PORT}:8080"
    volumes:
      - /cubeos/docs:/cubeos/docs
    environment:
      - TZ=${TZ}
      - LISTEN_ADDR=:8080
      - DOCS_LOCAL_PATH=/cubeos/docs
      - OLLAMA_HOST=
      - OLLAMA_PORT=
      - CHROMADB_HOST=
      - CHROMADB_PORT=
    env_file:
      - /cubeos/config/defaults.env
    deploy:
      resources:
        limits:
          memory: 256M
        reservations:
          memory: 64M
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:8080/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
    labels:
      - "cubeos.type=ai"
      - "cubeos.category=ai"
      - "cubeos.port=${DOCSINDEX_PORT}"
      - "cubeos.fqdn=docs.cubeos.cube"
      - "cubeos.deployment=compose"
COMPOSE_EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-18: Apply systemd-resolved resolution (deferred from pre-flight)
# ═══════════════════════════════════════════════════════════════════════════════

resolve_systemd_resolved() {
    case "$RESOLVE_DNS_ACTION" in
        disable)
            log_info "Disabling systemd-resolved..."
            systemctl disable --now systemd-resolved 2>/dev/null || true
            rm -f /etc/resolv.conf
            cat > /etc/resolv.conf << 'EOF'
# Managed by CubeOS — Pi-hole handles DNS
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
            log_ok "systemd-resolved disabled, temporary DNS set to 1.1.1.1"
            ;;
        alternate)
            log_info "Pi-hole DNS configured on port $PIHOLE_DNS_PORT (systemd-resolved unchanged)"
            ;;
        skip)
            log_info "Pi-hole DNS disabled — system DNS unchanged"
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-19: Connectivity pre-test
# ═══════════════════════════════════════════════════════════════════════════════

connectivity_test() {
    log_step "Connectivity"

    if [ "${CUBEOS_SKIP_DOWNLOAD:-false}" = "true" ]; then
        log_warn "CUBEOS_SKIP_DOWNLOAD=true — skipping connectivity test"
        return
    fi

    # Registry roots return 401/405 — any HTTP response means reachable.
    # Only fail on connection timeout/refused (http_code 000).
    local http_code
    http_code=$(curl -s --max-time 10 --connect-timeout 5 -o /dev/null -w "%{http_code}" "https://ghcr.io/v2/" 2>/dev/null)
    if [ -n "$http_code" ] && [ "$http_code" != "000" ]; then
        log_ok "Container registry reachable"
    else
        http_code=$(curl -s --max-time 10 --connect-timeout 5 -o /dev/null -w "%{http_code}" "https://registry.hub.docker.com/v2/" 2>/dev/null)
        if [ -n "$http_code" ] && [ "$http_code" != "000" ]; then
            log_ok "Container registry reachable (fallback)"
        else
            log_fatal "Cannot reach container registry. Check internet connection or set CUBEOS_SKIP_DOWNLOAD=true for air-gap mode"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-20: Pull and start services
# ═══════════════════════════════════════════════════════════════════════════════

pull_and_start() {
    log_step "Starting CubeOS services"

    # Apply DNS resolution if needed (before starting Pi-hole)
    resolve_systemd_resolved

    if [ "${CUBEOS_SKIP_DOWNLOAD:-false}" != "true" ]; then
        log_info "Pulling container images (this may take several minutes)..."
        docker compose -f /cubeos/docker-compose.yml pull
        log_ok "All images pulled"
    else
        # Air-gap mode: load images from local tarballs
        local airgap_dir="${CUBEOS_AIRGAP_DIR:-/cubeos/images}"
        if [ -d "$airgap_dir" ]; then
            log_info "Air-gap mode: loading images from $airgap_dir..."
            local loaded=0
            for tarball in "$airgap_dir"/*.tar; do
                [ -f "$tarball" ] || continue
                log_info "  Loading $(basename "$tarball")..."
                docker load -i "$tarball" || log_warn "Failed to load: $tarball"
                loaded=$((loaded + 1))
            done
            if [ $loaded -gt 0 ]; then
                log_ok "Loaded $loaded image(s) from $airgap_dir"
            else
                log_warn "No .tar files found in $airgap_dir"
            fi
        else
            log_warn "Air-gap mode: no images directory at $airgap_dir — expecting images pre-loaded"
        fi
    fi

    log_info "Starting services..."
    docker compose -f /cubeos/docker-compose.yml up -d

    # Wait for services to become healthy
    log_info "Waiting for services to start..."
    local timeout=120
    local elapsed=0
    local all_healthy=false

    while [ $elapsed -lt $timeout ]; do
        local running
        running=$(docker compose -f /cubeos/docker-compose.yml ps --format '{{.State}}' 2>/dev/null | grep -c "running" || echo "0")
        local total
        total=$(docker compose -f /cubeos/docker-compose.yml ps --format '{{.State}}' 2>/dev/null | wc -l || echo "0")

        if [ "$running" -ge 6 ]; then
            all_healthy=true
            break
        fi

        sleep 5
        elapsed=$((elapsed + 5))
        printf "  %d/%ds — %s/%s services running\r" "$elapsed" "$timeout" "$running" "$total"
    done
    echo ""

    if [ "$all_healthy" = true ]; then
        log_ok "Services started ($running/$total running)"
    else
        log_warn "Some services may still be starting. Check: docker compose -f /cubeos/docker-compose.yml ps"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-21: Registry verification
# ═══════════════════════════════════════════════════════════════════════════════

verify_registry() {
    local attempts=0
    while [ $attempts -lt 10 ]; do
        if curl -sf "http://localhost:5000/v2/" &>/dev/null; then
            log_ok "Registry is reachable at localhost:5000"
            return
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
    log_warn "Registry not responding yet — it may need more time to start"
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-22: systemd service
# ═══════════════════════════════════════════════════════════════════════════════

install_systemd_service() {
    log_step "Systemd service"

    cat > /etc/systemd/system/cubeos.service << 'EOF'
[Unit]
Description=CubeOS Container Platform
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker compose -f /cubeos/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f /cubeos/docker-compose.yml down
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable cubeos.service
    log_ok "cubeos.service installed and enabled"
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7b-09: Install cubeos CLI
# ═══════════════════════════════════════════════════════════════════════════════

install_cli() {
    log_step "Installing cubeos CLI"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "${script_dir}/cubeos-cli.sh" ]; then
        cp "${script_dir}/cubeos-cli.sh" /usr/local/bin/cubeos
    elif [ -f "/tmp/cubeos-cli.sh" ]; then
        cp /tmp/cubeos-cli.sh /usr/local/bin/cubeos
    else
        # Download from GitHub if running via curl pipe
        curl -fsSL "https://raw.githubusercontent.com/cubeos-app/releases/main/curl/cubeos-cli.sh" \
            -o /usr/local/bin/cubeos 2>/dev/null || {
            log_warn "Could not install cubeos CLI. Install manually later."
            return 0
        }
    fi
    chmod +x /usr/local/bin/cubeos
    log_ok "cubeos CLI installed at /usr/local/bin/cubeos"
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-23: Manifest file
# ═══════════════════════════════════════════════════════════════════════════════

write_manifest() {
    cat > /cubeos/.manifest << EOF
# CubeOS Manifest — installed by curl installer v${CUBEOS_INSTALLER_VERSION}
# Date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
/cubeos/docker-compose.yml
/cubeos/config/defaults.env
/cubeos/config/secrets.env
/etc/systemd/system/cubeos.service
/usr/local/bin/cubeos
/cubeos/.manifest
EOF

    log_ok "Manifest written to /cubeos/.manifest"
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-24: Success banner
# ═══════════════════════════════════════════════════════════════════════════════

print_banner() {
    local pw_display="$ADMIN_PASSWORD"
    cat << EOF

$(printf '\033[1;32m')
+--------------------------------------------------------------+
|                    CubeOS Installed!                         |
+--------------------------------------------------------------+
|                                                              |
|  Dashboard:  http://${SELECTED_IP}:${DASHBOARD_PORT:-6011}
|  Username:   admin
|  Password:   ${pw_display}
|                                                              |
|  API:        http://${SELECTED_IP}:${API_PORT:-6010}
|  Logs:       http://${SELECTED_IP}:${DOZZLE_PORT:-6012}
|                                                              |
|  Management: cubeos status|update|backup|uninstall           |
|                                                              |
+--------------------------------------------------------------+
$(printf '\033[0m')

  Config:   /cubeos/config/defaults.env
  Secrets:  /cubeos/config/secrets.env
  Compose:  /cubeos/docker-compose.yml
  Logs:     docker compose -f /cubeos/docker-compose.yml logs -f

EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7a-01: main() wrapper (Tailscale pattern)
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    set -euo pipefail

    echo ""
    echo "  CubeOS Installer v${CUBEOS_INSTALLER_VERSION}"
    echo "  ─────────────────────────────────"
    echo ""

    # ── Pre-flight checks ────────────────────────────────────────────────────
    log_step "Pre-flight checks"

    preflight_root
    preflight_arch
    preflight_os
    preflight_kernel
    preflight_ram
    preflight_disk
    preflight_package_manager
    preflight_ports
    preflight_lxc
    preflight_security
    preflight_existing

    # ── Docker ───────────────────────────────────────────────────────────────
    install_docker
    verify_docker

    # ── Swarm ────────────────────────────────────────────────────────────────
    init_swarm
    configure_swarm

    # ── Configuration ────────────────────────────────────────────────────────
    create_directories
    generate_secrets
    wifi_opt_in
    generate_defaults_env
    generate_compose

    # ── Deploy ───────────────────────────────────────────────────────────────
    connectivity_test
    pull_and_start
    verify_registry

    # ── Post-install ─────────────────────────────────────────────────────────
    install_systemd_service
    install_cli
    write_manifest
    print_banner
}

main "$@"
