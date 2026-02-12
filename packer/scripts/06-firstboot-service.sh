#!/bin/bash
# =============================================================================
# 06-firstboot-service.sh — Install CubeOS boot orchestration systemd service
# =============================================================================
# Creates cubeos-init.service which detects first-boot vs normal-boot
# and runs the appropriate script.
# =============================================================================
set -euo pipefail

echo "=== [06] First-Boot Service Installation ==="

# ---------------------------------------------------------------------------
# cubeos-init.service — main boot orchestrator
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/cubeos-init.service << 'SYSTEMD'
[Unit]
Description=CubeOS System Initialization
Documentation=https://github.com/cubeos-app
After=docker.service cubeos-docker-preload.service
Wants=docker.service
Before=hostapd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
    BOOT_MODE=$(/usr/local/bin/cubeos-boot-detect.sh); \
    echo "CubeOS boot mode: $BOOT_MODE"; \
    if [ "$BOOT_MODE" = "first-boot" ]; then \
        /usr/local/bin/cubeos-first-boot.sh; \
    else \
        /usr/local/bin/cubeos-normal-boot.sh; \
    fi'
StandardOutput=journal
StandardError=journal
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
SYSTEMD

# ---------------------------------------------------------------------------
# cubeos-watchdog.service — periodic health checks
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/cubeos-watchdog.service << 'WATCHDOG_SVC'
[Unit]
Description=CubeOS Watchdog Health Check
After=cubeos-init.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/cubeos/watchdog-health.sh
WATCHDOG_SVC

cat > /etc/systemd/system/cubeos-watchdog.timer << 'WATCHDOG_TMR'
[Unit]
Description=CubeOS Watchdog Timer
After=cubeos-init.service

[Timer]
OnBootSec=120
OnUnitActiveSec=60
AccuracySec=10

[Install]
WantedBy=timers.target
WATCHDOG_TMR

# ---------------------------------------------------------------------------
# Watchdog health check script
# ---------------------------------------------------------------------------
mkdir -p /usr/local/lib/cubeos

cat > /usr/local/lib/cubeos/watchdog-health.sh << 'HEALTH'
#!/bin/bash
# =============================================================================
# CubeOS Watchdog Health Check
# Runs every 60s. Restarts critical services if they're down.
# =============================================================================

# Maps: container_name → coreapps directory name
declare -A COMPOSE_SERVICES=(
    ["cubeos-pihole"]="pihole"
    ["cubeos-npm"]="npm"
    ["cubeos-hal"]="cubeos-hal"
)

# Maps: stack_name → coreapps directory name
declare -A SWARM_SERVICES=(
    ["cubeos-api"]="cubeos-api"
    ["dashboard"]="cubeos-dashboard"
)

# Check Docker daemon
if ! docker info &>/dev/null; then
    echo "[WATCHDOG] Docker daemon is down! Restarting..."
    systemctl restart docker
    sleep 10
fi

# Check compose services (Pi-hole, NPM, HAL)
for svc in "${!COMPOSE_SERVICES[@]}"; do
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${svc}$"; then
        echo "[WATCHDOG] ${svc} is not running. Checking..."
        # Don't auto-restart if we're in first-boot
        if [ -f /cubeos/data/.setup_complete ]; then
            COMPOSE_FILE="/cubeos/coreapps/${COMPOSE_SERVICES[$svc]}/appconfig/docker-compose.yml"
            if [ -f "$COMPOSE_FILE" ]; then
                echo "[WATCHDOG] Restarting ${svc}..."
                docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null || true
            fi
        fi
    fi
done

# Check Swarm stacks
for stack in "${!SWARM_SERVICES[@]}"; do
    if ! docker stack ls 2>/dev/null | grep -q "^${stack} "; then
        echo "[WATCHDOG] Stack ${stack} missing."
        if [ -f /cubeos/data/.setup_complete ]; then
            COMPOSE_FILE="/cubeos/coreapps/${SWARM_SERVICES[$stack]}/appconfig/docker-compose.yml"
            if [ -f "$COMPOSE_FILE" ]; then
                echo "[WATCHDOG] Re-deploying stack ${stack}..."
                docker stack deploy -c "$COMPOSE_FILE" --resolve-image never "$stack" 2>/dev/null || true
            fi
        fi
    fi
done

# Check disk space (warn if < 500MB free)
FREE_KB=$(df /cubeos/data 2>/dev/null | tail -1 | awk '{print $4}')
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 512000 ]; then
    echo "[WATCHDOG] WARNING: Low disk space! ${FREE_KB}KB free on /cubeos/data"
fi
HEALTH

chmod +x /usr/local/lib/cubeos/watchdog-health.sh

# ---------------------------------------------------------------------------
# Enable services
# ---------------------------------------------------------------------------
systemctl enable cubeos-init.service 2>/dev/null || true
systemctl enable cubeos-watchdog.timer 2>/dev/null || true

echo "[06] First-boot service installed and enabled."
