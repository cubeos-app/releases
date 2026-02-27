#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# CubeOS CLI — management commands for CubeOS installations
# Installed to /usr/local/bin/cubeos by the curl installer
#
# Usage: cubeos <command> [options]
# Commands: status, logs, update, backup, restore, uninstall, download, help
# ═══════════════════════════════════════════════════════════════════════════════

CUBEOS_CLI_VERSION="0.2.0-beta.01"
CUBEOS_DIR="/cubeos"
CUBEOS_COMPOSE="/cubeos/docker-compose.yml"
CUBEOS_CONFIG="/cubeos/config/defaults.env"
CUBEOS_SECRETS="/cubeos/config/secrets.env"
CUBEOS_BACKUPS="/cubeos/backups"
CUBEOS_MANIFEST="/cubeos/.manifest"

# Channel URLs (primary + fallback)
CHANNEL_URL_PRIMARY="https://get.cubeos.app/channels"
CHANNEL_URL_FALLBACK="https://raw.githubusercontent.com/cubeos-app/releases/main/manifests/channels"

# ─── Output helpers (same as install.sh) ────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
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

# ─── Utility functions ──────────────────────────────────────────────────────

load_config() {
    if [ -f "$CUBEOS_CONFIG" ]; then
        set -a
        # shellcheck source=/dev/null
        . "$CUBEOS_CONFIG"
        set +a
    fi
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_fatal "This command requires root. Run with: sudo cubeos $*"
    fi
}

require_cubeos() {
    if [ ! -f "$CUBEOS_CONFIG" ]; then
        log_fatal "CubeOS is not installed (missing $CUBEOS_CONFIG)"
    fi
}

verify_sha256() {
    local file="$1" expected="$2"
    local actual
    actual=$(sha256sum "$file" | cut -d' ' -f1)
    if [ "$actual" != "$expected" ]; then
        log_error "SHA256 mismatch for $file"
        log_error "  Expected: $expected"
        log_error "  Got:      $actual"
        log_fatal "Possible tampering or corrupt download. Aborting."
    fi
}

service_fuzzy_match() {
    local input="$1"
    local services
    services=$(docker compose -f "$CUBEOS_COMPOSE" config --services 2>/dev/null)

    # Exact match
    if echo "$services" | grep -qx "$input"; then
        echo "$input"
        return 0
    fi

    # Prefix match with cubeos- prefix
    if echo "$services" | grep -qx "cubeos-${input}"; then
        echo "cubeos-${input}"
        return 0
    fi

    # Substring match
    local match
    match=$(echo "$services" | grep -F "$input" | head -1)
    if [ -n "$match" ]; then
        echo "$match"
        return 0
    fi

    # No match — suggest closest
    log_error "Unknown service: $input"
    log_info "Available services:"
    echo "$services" | while read -r svc; do
        echo "  - $svc"
    done
    return 1
}

fetch_channel_json() {
    local channel="$1"
    local tmpfile
    tmpfile=$(mktemp)

    # Try primary URL
    if curl -fsSL --connect-timeout 10 "${CHANNEL_URL_PRIMARY}/${channel}.json" -o "$tmpfile" 2>/dev/null; then
        echo "$tmpfile"
        return 0
    fi

    # Try fallback URL
    if curl -fsSL --connect-timeout 10 "${CHANNEL_URL_FALLBACK}/${channel}.json" -o "$tmpfile" 2>/dev/null; then
        echo "$tmpfile"
        return 0
    fi

    rm -f "$tmpfile"
    return 1
}

json_value() {
    # Simple JSON value extraction (no jq dependency)
    local json="$1" key="$2"
    echo "$json" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

json_value_raw() {
    # Extract raw JSON value (for objects/arrays)
    local json="$1" key="$2"
    echo "$json" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

version_compare() {
    # Returns: 0 if equal, 1 if $1 > $2, 2 if $1 < $2
    # Strips pre-release suffixes for comparison
    local v1="${1%%-*}" v2="${2%%-*}"
    if [ "$v1" = "$v2" ]; then return 0; fi

    local IFS='.'
    # shellcheck disable=SC2206
    local a=($v1) b=($v2)
    local i
    for i in 0 1 2; do
        local ai="${a[$i]:-0}" bi="${b[$i]:-0}"
        if [ "$ai" -gt "$bi" ] 2>/dev/null; then return 1; fi
        if [ "$ai" -lt "$bi" ] 2>/dev/null; then return 2; fi
    done
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# cmd_status — Show CubeOS service status
# ═══════════════════════════════════════════════════════════════════════════════

cmd_status() {
    require_cubeos
    load_config

    local version="${CUBEOS_VERSION:-unknown}"
    local channel="${CUBEOS_CHANNEL:-stable}"

    printf "\n  ${BOLD}CubeOS v%s — Status${NC}\n" "$version"
    printf "  ────────────────────────────────────────\n"

    # Service status table
    printf "  ${BOLD}%-20s %-10s %-6s %s${NC}\n" "SERVICE" "STATUS" "PORT" "IMAGE VERSION"

    local compose_services
    compose_services=$(docker compose -f "$CUBEOS_COMPOSE" ps --format json 2>/dev/null || echo "")

    if [ -n "$compose_services" ]; then
        echo "$compose_services" | while IFS= read -r line; do
            [ -z "$line" ] && continue
            local name state port image

            # Parse JSON fields — docker compose ps --format json outputs one JSON object per line
            name=$(echo "$line" | sed -n 's/.*"Name":"\([^"]*\)".*/\1/p')
            state=$(echo "$line" | sed -n 's/.*"State":"\([^"]*\)".*/\1/p')
            # Strip cubeos- prefix for display
            local display_name="${name#cubeos-}"

            # Get image from docker inspect
            image=$(docker inspect --format '{{.Config.Image}}' "$name" 2>/dev/null || echo "unknown")
            local image_tag="${image##*:}"
            local image_repo="${image%:*}"
            # Shorten the repo name
            image_repo="${image_repo##*/}"

            # Get published port from labels or container info
            port=$(docker inspect --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}}{{end}}{{end}}' "$name" 2>/dev/null | head -c 5)
            # If host network mode, try labels
            if [ -z "$port" ]; then
                port=$(docker inspect --format '{{index .Config.Labels "cubeos.port"}}' "$name" 2>/dev/null || echo "")
            fi

            local status_color="$RED"
            if [ "$state" = "running" ]; then
                status_color="$GREEN"
            fi

            printf "  %-20s ${status_color}%-10s${NC} %-6s %s:%s\n" \
                "$display_name" "$state" "${port:-—}" "$image_repo" "$image_tag"
        done
    else
        log_warn "No services found. Is CubeOS running?"
    fi

    printf "  ────────────────────────────────────────\n"

    # Swarm status
    local swarm_state
    swarm_state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "unknown")
    local swarm_nodes
    swarm_nodes=$(docker info --format '{{.Swarm.Nodes}}' 2>/dev/null || echo "0")
    printf "  ${BOLD}Swarm:${NC}    %s (%s node%s)\n" "$swarm_state" "$swarm_nodes" "$([ "$swarm_nodes" != "1" ] && echo "s")"

    # Uptime — try cubeos.service first (Tier 1), fall back to /proc/uptime (Tier 2/container)
    local uptime_str="unknown"
    local diff=0
    if systemctl is-active cubeos.service &>/dev/null; then
        local start_ts
        start_ts=$(systemctl show cubeos.service --property=ActiveEnterTimestamp --value 2>/dev/null || echo "")
        if [ -n "$start_ts" ]; then
            local start_epoch now_epoch
            start_epoch=$(date -d "$start_ts" +%s 2>/dev/null || echo "0")
            now_epoch=$(date +%s)
            if [ "$start_epoch" -gt 0 ]; then
                diff=$((now_epoch - start_epoch))
            fi
        fi
    elif [ -f /proc/uptime ]; then
        diff=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo "0")
    fi
    if [ "$diff" -gt 0 ]; then
        local days=$((diff / 86400))
        local hours=$(( (diff % 86400) / 3600 ))
        local mins=$(( (diff % 3600) / 60 ))
        if [ $days -gt 0 ]; then
            uptime_str="${days}d ${hours}h ${mins}m"
        elif [ $hours -gt 0 ]; then
            uptime_str="${hours}h ${mins}m"
        else
            uptime_str="${mins}m"
        fi
    fi
    printf "  ${BOLD}Uptime:${NC}   %s\n" "$uptime_str"

    # Channel
    printf "  ${BOLD}Channel:${NC}  %s\n" "$channel"

    # Disk usage
    if [ -d "$CUBEOS_DIR" ]; then
        local disk_info
        disk_info=$(df -h "$CUBEOS_DIR" | tail -1)
        local disk_used disk_avail
        disk_used=$(echo "$disk_info" | awk '{print $3}')
        disk_avail=$(echo "$disk_info" | awk '{print $4}')
        printf "  ${BOLD}Disk:${NC}     %s used / %s free (%s)\n" "$disk_used" "$disk_avail" "$CUBEOS_DIR"
    fi

    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# cmd_logs — Tail service logs
# ═══════════════════════════════════════════════════════════════════════════════

cmd_logs() {
    require_cubeos

    local service="" follow=false tail_lines=50
    while [ $# -gt 0 ]; do
        case "$1" in
            -f|--follow) follow=true; shift ;;
            -n|--lines)  tail_lines="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: cubeos logs [service] [-f|--follow] [-n|--lines N]"
                echo ""
                echo "  cubeos logs              Tail all service logs (last 50 lines)"
                echo "  cubeos logs api          Tail logs for a specific service"
                echo "  cubeos logs -f           Follow all logs in real-time"
                echo "  cubeos logs api -f       Follow a specific service"
                echo "  cubeos logs -n 100       Show last 100 lines"
                return 0
                ;;
            -*) log_fatal "Unknown option: $1. Use 'cubeos logs --help'" ;;
            *)  service="$1"; shift ;;
        esac
    done

    local args=("--tail" "$tail_lines")
    if [ "$follow" = true ]; then
        args+=("-f")
    fi

    if [ -n "$service" ]; then
        local matched
        matched=$(service_fuzzy_match "$service") || exit 1
        log_info "Showing logs for: $matched"
        docker compose -f "$CUBEOS_COMPOSE" logs "${args[@]}" "$matched"
    else
        docker compose -f "$CUBEOS_COMPOSE" logs "${args[@]}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# cmd_update — Update CubeOS to latest version
# ═══════════════════════════════════════════════════════════════════════════════

cmd_update() {
    require_cubeos
    load_config

    local channel="${CUBEOS_CHANNEL:-stable}"
    local target_version=""
    local check_only=false
    local dry_run=false
    local offline_path=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --channel)  channel="$2"; shift 2 ;;
            --version)  target_version="$2"; shift 2 ;;
            --check)    check_only=true; shift ;;
            --dry-run)  dry_run=true; shift ;;
            --offline)  offline_path="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: cubeos update [options]"
                echo ""
                echo "  cubeos update                   Update to latest on current channel"
                echo "  cubeos update --channel beta    Switch to beta channel and update"
                echo "  cubeos update --version 0.2.1   Update to a specific version"
                echo "  cubeos update --check           Check for updates without applying"
                echo "  cubeos update --dry-run         Show what would change"
                echo "  cubeos update --offline /path/  Apply offline update bundle"
                return 0
                ;;
            *) log_fatal "Unknown option: $1. Use 'cubeos update --help'" ;;
        esac
    done

    require_root "update"

    local current_version="${CUBEOS_VERSION:-0.0.0}"

    # Offline update path
    if [ -n "$offline_path" ]; then
        update_offline "$offline_path"
        return
    fi

    log_step "Checking for updates (channel: $channel)"

    # Step 1: Fetch channel JSON
    local channel_file
    channel_file=$(fetch_channel_json "$channel") || \
        log_fatal "Cannot reach update server. Check internet or use: cubeos update --offline /path/"

    local channel_json
    channel_json=$(cat "$channel_file")
    rm -f "$channel_file"

    local remote_version compose_url compose_sha cli_url cli_sha min_version
    remote_version=$(json_value "$channel_json" "version")
    compose_url=$(json_value "$channel_json" "compose_url")
    compose_sha=$(json_value "$channel_json" "compose_sha256")
    cli_url=$(json_value "$channel_json" "cli_url")
    cli_sha=$(json_value "$channel_json" "cli_sha256")
    min_version=$(json_value "$channel_json" "min_version")

    if [ -n "$target_version" ]; then
        remote_version="$target_version"
    fi

    if [ -z "$remote_version" ]; then
        log_fatal "Could not parse version from channel metadata"
    fi

    # Step 2: Compare versions
    version_compare "$current_version" "$remote_version"
    local cmp=$?

    if [ $cmp -eq 0 ]; then
        log_ok "Already up to date (v${current_version} on ${channel} channel)"
        return 0
    fi

    if [ $cmp -eq 1 ]; then
        log_warn "Installed version (v${current_version}) is newer than ${channel} channel (v${remote_version})"
        log_info "Use --channel dev for development versions"
        return 0
    fi

    # Step 3: Check min_version
    if [ -n "$min_version" ]; then
        version_compare "$current_version" "$min_version"
        if [ $? -eq 2 ]; then
            log_fatal "Current version v${current_version} is below minimum v${min_version}. Manual upgrade required."
        fi
    fi

    log_info "Update available: v${current_version} -> v${remote_version} (${channel})"

    if [ "$check_only" = true ]; then
        return 0
    fi

    if [ "$dry_run" = true ]; then
        log_info "[dry-run] Would download compose from: $compose_url"
        log_info "[dry-run] Would download CLI from: $cli_url"
        log_info "[dry-run] Would pull new images and restart services"
        return 0
    fi

    # Step 4-5: Download new compose and CLI
    log_step "Downloading update"

    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" EXIT

    log_info "Downloading compose template..."
    curl -fsSL "$compose_url" -o "$tmpdir/docker-compose.yml" || \
        log_fatal "Failed to download compose template"

    if [ "$compose_sha" != "placeholder-will-be-updated-by-ci" ] && [ -n "$compose_sha" ]; then
        verify_sha256 "$tmpdir/docker-compose.yml" "$compose_sha"
        log_ok "Compose template SHA256 verified"
    fi

    log_info "Downloading CLI..."
    curl -fsSL "$cli_url" -o "$tmpdir/cubeos-cli.sh" || \
        log_fatal "Failed to download CLI script"

    if [ "$cli_sha" != "placeholder-will-be-updated-by-ci" ] && [ -n "$cli_sha" ]; then
        verify_sha256 "$tmpdir/cubeos-cli.sh" "$cli_sha"
        log_ok "CLI script SHA256 verified"
    fi

    # Step 6: Pre-update backup
    log_step "Creating pre-update backup"
    cmd_backup --pre-update --exclude-data

    # Step 7: Pull new images
    log_step "Pulling new images"
    log_info "Pulling images (this may take several minutes)..."
    cp "$tmpdir/docker-compose.yml" "${CUBEOS_COMPOSE}.new"
    docker compose -f "${CUBEOS_COMPOSE}.new" pull || {
        log_error "Image pull failed. Rolling back..."
        rm -f "${CUBEOS_COMPOSE}.new"
        log_fatal "Update aborted. Previous version unchanged."
    }

    # Step 8: Stop old services
    log_step "Applying update"
    log_info "Stopping services..."
    docker compose -f "$CUBEOS_COMPOSE" down || true

    # Step 9: Replace compose file
    mv "${CUBEOS_COMPOSE}.new" "$CUBEOS_COMPOSE"

    # Step 10: Start new services
    log_info "Starting updated services..."
    docker compose -f "$CUBEOS_COMPOSE" up -d || {
        log_error "Failed to start updated services. Restoring backup..."
        local backup_compose="/cubeos/backups/pre-update-${current_version}/docker-compose.yml"
        if [ -f "$backup_compose" ]; then
            cp "$backup_compose" "$CUBEOS_COMPOSE"
            docker compose -f "$CUBEOS_COMPOSE" up -d || true
        fi
        log_fatal "Update failed. Attempted rollback to v${current_version}."
    }

    # Step 11: Update config
    sed -i "s/^CUBEOS_VERSION=.*/CUBEOS_VERSION=${remote_version}/" "$CUBEOS_CONFIG"
    if grep -q '^CUBEOS_CHANNEL=' "$CUBEOS_CONFIG"; then
        sed -i "s/^CUBEOS_CHANNEL=.*/CUBEOS_CHANNEL=${channel}/" "$CUBEOS_CONFIG"
    else
        echo "CUBEOS_CHANNEL=${channel}" >> "$CUBEOS_CONFIG"
    fi

    # Step 12: Replace CLI
    cp "$tmpdir/cubeos-cli.sh" /usr/local/bin/cubeos
    chmod +x /usr/local/bin/cubeos

    # Step 13: Verify services healthy
    log_info "Waiting for services to become healthy..."
    local timeout=120 elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local running
        running=$(docker compose -f "$CUBEOS_COMPOSE" ps --format '{{.State}}' 2>/dev/null | grep -c "running" || echo "0")
        if [ "$running" -ge 6 ]; then
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        printf "  %d/%ds — %s services running\r" "$elapsed" "$timeout" "$running"
    done
    echo ""

    # Step 14: Success
    log_ok "Update complete: v${current_version} -> v${remote_version} (${channel})"
    echo ""
}

update_offline() {
    local bundle_path="$1"

    if [ ! -d "$bundle_path" ]; then
        log_fatal "Offline bundle directory not found: $bundle_path"
    fi

    local metadata_file="${bundle_path}/metadata.json"
    if [ ! -f "$metadata_file" ]; then
        log_fatal "Missing metadata.json in bundle: $bundle_path"
    fi

    local metadata
    metadata=$(cat "$metadata_file")
    local bundle_version
    bundle_version=$(json_value "$metadata" "version")
    local current_version="${CUBEOS_VERSION:-0.0.0}"

    log_step "Offline update: v${current_version} -> v${bundle_version}"

    # Load images from tarballs
    if [ -d "${bundle_path}/images" ]; then
        log_info "Loading Docker images from bundle..."
        for tarball in "${bundle_path}/images"/*.tar; do
            [ -f "$tarball" ] || continue
            log_info "  Loading $(basename "$tarball")..."
            docker load -i "$tarball" || log_warn "Failed to load: $tarball"
        done
        log_ok "Images loaded"
    fi

    # Pre-update backup
    log_step "Creating pre-update backup"
    cmd_backup --pre-update --exclude-data

    # Replace compose file
    if [ -f "${bundle_path}/docker-compose.yml" ]; then
        log_info "Stopping services..."
        docker compose -f "$CUBEOS_COMPOSE" down || true
        cp "${bundle_path}/docker-compose.yml" "$CUBEOS_COMPOSE"
    fi

    # Start services
    log_info "Starting updated services..."
    docker compose -f "$CUBEOS_COMPOSE" up -d || {
        log_error "Failed to start. Check: docker compose -f $CUBEOS_COMPOSE logs"
        exit 1
    }

    # Replace CLI
    if [ -f "${bundle_path}/cubeos-cli.sh" ]; then
        cp "${bundle_path}/cubeos-cli.sh" /usr/local/bin/cubeos
        chmod +x /usr/local/bin/cubeos
    fi

    # Update version in config
    sed -i "s/^CUBEOS_VERSION=.*/CUBEOS_VERSION=${bundle_version}/" "$CUBEOS_CONFIG"

    # Wait for services
    log_info "Waiting for services..."
    local timeout=120 elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local running
        running=$(docker compose -f "$CUBEOS_COMPOSE" ps --format '{{.State}}' 2>/dev/null | grep -c "running" || echo "0")
        if [ "$running" -ge 6 ]; then break; fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    log_ok "Offline update complete: v${current_version} -> v${bundle_version}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# cmd_backup — Create a backup
# ═══════════════════════════════════════════════════════════════════════════════

cmd_backup() {
    require_cubeos

    local encrypt=false exclude_data=false output="" pre_update=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --encrypt)       encrypt=true; shift ;;
            --exclude-data)  exclude_data=true; shift ;;
            --output)        output="$2"; shift 2 ;;
            --pre-update)    pre_update=true; shift ;;
            -h|--help)
                echo "Usage: cubeos backup [options]"
                echo ""
                echo "  cubeos backup                          Create full backup"
                echo "  cubeos backup --encrypt                Create encrypted backup"
                echo "  cubeos backup --exclude-data           Config only (skip /cubeos/data/)"
                echo "  cubeos backup --output /path/file.tar.gz   Custom output path"
                return 0
                ;;
            *) log_fatal "Unknown option: $1. Use 'cubeos backup --help'" ;;
        esac
    done

    require_root "backup"
    load_config

    local current_version="${CUBEOS_VERSION:-unknown}"
    local datestamp
    datestamp=$(date +%Y%m%d-%H%M%S)

    mkdir -p "$CUBEOS_BACKUPS"

    # Determine output path
    if [ "$pre_update" = true ]; then
        output="${CUBEOS_BACKUPS}/pre-update-${current_version}.tar.gz"
    elif [ -z "$output" ]; then
        output="${CUBEOS_BACKUPS}/cubeos-${datestamp}.tar.gz"
    fi

    log_step "Creating backup"

    # Build list of paths to backup
    local -a backup_paths=()
    backup_paths+=("/cubeos/config")
    backup_paths+=("/cubeos/docker-compose.yml")
    backup_paths+=("/cubeos/.manifest")

    if [ "$exclude_data" = false ]; then
        backup_paths+=("/cubeos/data")
    fi

    # Create tar archive
    local tar_args=("-czf" "$output")
    for p in "${backup_paths[@]}"; do
        if [ -e "$p" ]; then
            tar_args+=("$p")
        fi
    done

    log_info "Archiving to $output..."
    tar "${tar_args[@]}" 2>/dev/null || log_fatal "Failed to create backup archive"

    # Encrypt if requested
    if [ "$encrypt" = true ]; then
        local enc_output="${output}.enc"
        log_info "Encrypting backup..."
        local passphrase
        if [ -e /dev/tty ]; then
            printf "  Enter passphrase: " > /dev/tty
            read -rs passphrase < /dev/tty
            echo "" > /dev/tty
        else
            log_fatal "Encryption requires interactive terminal for passphrase"
        fi
        openssl enc -aes-256-cbc -salt -pbkdf2 -in "$output" -out "$enc_output" -pass "pass:${passphrase}" || \
            log_fatal "Encryption failed"
        rm -f "$output"
        output="$enc_output"
        log_ok "Encrypted backup created"
    fi

    # Display result
    local size
    size=$(du -h "$output" | cut -f1)
    log_ok "Backup created: $output ($size)"

    # Auto-rotate old backups (keep last N, skip pre-update backups)
    if [ "$pre_update" = false ]; then
        local retain="${CUBEOS_BACKUP_RETAIN:-5}"
        local count
        count=$(find "$CUBEOS_BACKUPS" -maxdepth 1 -name "cubeos-*.tar.gz*" ! -name "pre-update-*" | wc -l)
        if [ "$count" -gt "$retain" ]; then
            local to_remove=$((count - retain))
            find "$CUBEOS_BACKUPS" -maxdepth 1 -name "cubeos-*.tar.gz*" ! -name "pre-update-*" -printf '%T+ %p\n' \
                | sort | head -n "$to_remove" | awk '{print $2}' \
                | while read -r old_backup; do
                    rm -f "$old_backup"
                    log_info "Rotated old backup: $(basename "$old_backup")"
                done
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# cmd_restore — Restore from a backup
# ═══════════════════════════════════════════════════════════════════════════════

cmd_restore() {
    require_cubeos

    local dry_run=false config_only=false backup_file=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)      dry_run=true; shift ;;
            --config-only)  config_only=true; shift ;;
            -h|--help)
                echo "Usage: cubeos restore [options] <backup-file>"
                echo ""
                echo "  cubeos restore /path/to/backup.tar.gz         Restore from backup"
                echo "  cubeos restore /path/to/backup.tar.gz.enc     Restore encrypted backup"
                echo "  cubeos restore --dry-run /path/to/backup      List contents only"
                echo "  cubeos restore --config-only /path/to/backup  Restore config only"
                return 0
                ;;
            -*) log_fatal "Unknown option: $1. Use 'cubeos restore --help'" ;;
            *)  backup_file="$1"; shift ;;
        esac
    done

    if [ -z "$backup_file" ]; then
        log_fatal "Backup file required. Usage: cubeos restore <backup-file>"
    fi

    if [ ! -f "$backup_file" ]; then
        log_fatal "Backup file not found: $backup_file"
    fi

    require_root "restore"

    local working_file="$backup_file"

    # Step 1: Decrypt if needed
    if [[ "$backup_file" == *.enc ]]; then
        log_info "Encrypted backup detected"
        local passphrase
        if [ -e /dev/tty ]; then
            printf "  Enter passphrase: " > /dev/tty
            read -rs passphrase < /dev/tty
            echo "" > /dev/tty
        else
            log_fatal "Decryption requires interactive terminal for passphrase"
        fi

        working_file=$(mktemp --suffix=.tar.gz)
        trap "rm -f '$working_file'" EXIT
        openssl enc -d -aes-256-cbc -pbkdf2 -in "$backup_file" -out "$working_file" -pass "pass:${passphrase}" || \
            log_fatal "Decryption failed. Wrong passphrase?"
        log_ok "Backup decrypted"
    fi

    # Verify it's a valid tar.gz
    if ! tar -tzf "$working_file" &>/dev/null; then
        log_fatal "Invalid backup file (not a valid tar.gz archive)"
    fi

    # Dry-run: just list contents
    if [ "$dry_run" = true ]; then
        log_step "Backup contents (dry-run)"
        tar -tzf "$working_file" | head -50
        local total
        total=$(tar -tzf "$working_file" | wc -l)
        echo "  ... $total entries total"
        return 0
    fi

    log_step "Restoring from backup"
    log_info "Source: $backup_file"

    # Step 3: Stop services
    log_info "Stopping services..."
    docker compose -f "$CUBEOS_COMPOSE" down 2>/dev/null || true

    # Step 4: Extract backup
    if [ "$config_only" = true ]; then
        log_info "Restoring config only..."
        tar -xzf "$working_file" -C / --wildcards '*/config/*' '*/docker-compose.yml' '*/.manifest' 2>/dev/null || \
            tar -xzf "$working_file" -C / 2>/dev/null
    else
        log_info "Restoring all files..."
        tar -xzf "$working_file" -C / 2>/dev/null || log_fatal "Failed to extract backup"
    fi
    log_ok "Files restored"

    # Step 5: Start services
    log_info "Starting services..."
    docker compose -f "$CUBEOS_COMPOSE" up -d || {
        log_error "Failed to start services after restore"
        log_info "Check: docker compose -f $CUBEOS_COMPOSE logs"
        exit 1
    }

    # Step 6: Wait for healthy
    log_info "Waiting for services..."
    local timeout=120 elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local running
        running=$(docker compose -f "$CUBEOS_COMPOSE" ps --format '{{.State}}' 2>/dev/null | grep -c "running" || echo "0")
        if [ "$running" -ge 6 ]; then break; fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    log_ok "Restore complete. Services restarted."
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# cmd_uninstall — Remove CubeOS
# ═══════════════════════════════════════════════════════════════════════════════

cmd_uninstall() {
    local skip_confirm=false purge=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --yes)   skip_confirm=true; shift ;;
            --purge) purge=true; skip_confirm=true; shift ;;
            -h|--help)
                echo "Usage: cubeos uninstall [options]"
                echo ""
                echo "  cubeos uninstall          Interactive uninstall"
                echo "  cubeos uninstall --yes    Skip confirmation"
                echo "  cubeos uninstall --purge  Remove everything including data"
                return 0
                ;;
            *) log_fatal "Unknown option: $1. Use 'cubeos uninstall --help'" ;;
        esac
    done

    require_root "uninstall"

    if [ "$skip_confirm" = false ]; then
        echo ""
        echo "  This will remove all CubeOS services and configuration."
        echo "  Data in /cubeos/data/ can optionally be preserved."
        echo ""
        local confirm
        confirm=$(prompt_user "  Continue? [y/N]: " "n")
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            log_info "Uninstall cancelled."
            exit 0
        fi
    fi

    log_step "Uninstalling CubeOS"

    # Step 1: Stop all services
    log_info "Stopping services..."
    if [ -f "$CUBEOS_COMPOSE" ]; then
        docker compose -f "$CUBEOS_COMPOSE" down 2>/dev/null || true
    fi

    # Step 2: Leave Swarm
    log_info "Leaving Docker Swarm..."
    docker swarm leave --force 2>/dev/null || true

    # Step 3: Remove systemd service
    log_info "Removing systemd service..."
    systemctl disable --now cubeos.service 2>/dev/null || true
    rm -f /etc/systemd/system/cubeos.service
    systemctl daemon-reload 2>/dev/null || true

    # Step 4: Remove CLI
    log_info "Removing cubeos CLI..."
    rm -f /usr/local/bin/cubeos

    # Step 5: Handle data
    if [ "$purge" = true ]; then
        log_info "Removing all CubeOS files (including data)..."
        rm -rf /cubeos/
    else
        local remove_data="n"
        if [ "$skip_confirm" = false ]; then
            echo ""
            remove_data=$(prompt_user "  Remove /cubeos/data/? This deletes all application data. [y/N]: " "n")
        fi

        if [ "$remove_data" = "y" ] || [ "$remove_data" = "Y" ]; then
            log_info "Removing all CubeOS files (including data)..."
            rm -rf /cubeos/
        else
            log_info "Removing CubeOS files (preserving /cubeos/data/)..."
            # Read manifest for additional files to clean
            if [ -f "$CUBEOS_MANIFEST" ]; then
                while IFS= read -r line; do
                    # Skip comments and empty lines
                    [[ "$line" =~ ^#.*$ ]] && continue
                    [ -z "$line" ] && continue
                    # Don't remove data dir entries
                    [[ "$line" == /cubeos/data* ]] && continue
                    rm -f "$line" 2>/dev/null || true
                done < "$CUBEOS_MANIFEST"
            fi
            rm -rf /cubeos/config /cubeos/coreapps /cubeos/apps /cubeos/mounts \
                   /cubeos/backups /cubeos/docs /cubeos/docker-compose.yml /cubeos/.manifest \
                   2>/dev/null || true
        fi
    fi

    log_ok "CubeOS uninstalled."
    log_info "Docker Engine was NOT removed (you may have other containers)."
    log_info "To remove Docker: sudo apt remove docker-ce docker-ce-cli containerd.io"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# cmd_download — Prepare an offline update bundle
# ═══════════════════════════════════════════════════════════════════════════════

cmd_download() {
    local target_version="" output_dir="" channel=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --version)  target_version="$2"; shift 2 ;;
            --output)   output_dir="$2"; shift 2 ;;
            --channel)  channel="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: cubeos download [options]"
                echo ""
                echo "  cubeos download --version 0.2.1 --output /path/to/bundle/"
                echo "  cubeos download --channel beta --output /path/to/bundle/"
                echo ""
                echo "Prepares an offline update bundle that can be applied with:"
                echo "  cubeos update --offline /path/to/bundle/"
                return 0
                ;;
            *) log_fatal "Unknown option: $1. Use 'cubeos download --help'" ;;
        esac
    done

    if [ -z "$output_dir" ]; then
        log_fatal "Output directory required. Usage: cubeos download --output /path/"
    fi

    require_root "download"
    load_config

    local ch="${channel:-${CUBEOS_CHANNEL:-stable}}"

    log_step "Preparing offline update bundle"

    # Fetch channel metadata
    local channel_file
    channel_file=$(fetch_channel_json "$ch") || \
        log_fatal "Cannot fetch channel metadata for: $ch"

    local channel_json
    channel_json=$(cat "$channel_file")
    rm -f "$channel_file"

    local remote_version compose_url cli_url
    remote_version=$(json_value "$channel_json" "version")
    compose_url=$(json_value "$channel_json" "compose_url")
    cli_url=$(json_value "$channel_json" "cli_url")

    if [ -n "$target_version" ]; then
        remote_version="$target_version"
    fi

    log_info "Bundle version: v${remote_version} (${ch} channel)"

    # Create output directory
    mkdir -p "${output_dir}/images"

    # Download compose template
    log_info "Downloading compose template..."
    curl -fsSL "$compose_url" -o "${output_dir}/docker-compose.yml" || \
        log_fatal "Failed to download compose template"

    # Download CLI script
    log_info "Downloading CLI script..."
    curl -fsSL "$cli_url" -o "${output_dir}/cubeos-cli.sh" || \
        log_fatal "Failed to download CLI script"
    chmod +x "${output_dir}/cubeos-cli.sh"

    # Pull and save images
    log_info "Pulling and saving Docker images..."

    # Extract image list from channel JSON — parse the images object
    local -a images=()
    # Parse images from the JSON (simplified — handles the known format)
    while IFS= read -r img_line; do
        [ -z "$img_line" ] && continue
        local repo tag
        repo=$(echo "$img_line" | sed -n 's/.*"\([^"]*\)"[[:space:]]*:.*/\1/p')
        tag=$(echo "$img_line" | sed -n 's/.*:[[:space:]]*"\([^"]*\)".*/\1/p')
        if [ -n "$repo" ] && [ -n "$tag" ]; then
            images+=("${repo}:${tag}")
        fi
    done < <(echo "$channel_json" | sed -n '/"images"/,/}/p' | grep '".*":')

    for image in "${images[@]}"; do
        log_info "  Pulling: $image"
        docker pull "$image" 2>/dev/null || {
            log_warn "Failed to pull: $image (skipping)"
            continue
        }
        local safe_name
        safe_name=$(echo "$image" | tr '/:' '__')
        log_info "  Saving: $image"
        docker save "$image" -o "${output_dir}/images/${safe_name}.tar" || \
            log_warn "Failed to save: $image"
    done

    # Write metadata.json
    cat > "${output_dir}/metadata.json" << METAEOF
{
    "version": "${remote_version}",
    "channel": "${ch}",
    "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "compose_sha256": "$(sha256sum "${output_dir}/docker-compose.yml" | cut -d' ' -f1)",
    "cli_sha256": "$(sha256sum "${output_dir}/cubeos-cli.sh" | cut -d' ' -f1)"
}
METAEOF

    # Display result
    local total_size
    total_size=$(du -sh "$output_dir" | cut -f1)
    echo ""
    log_ok "Offline bundle ready: $output_dir ($total_size)"
    echo ""
    echo "  To apply on an air-gapped machine:"
    echo "    1. Copy this directory to the target machine"
    echo "    2. Run: sudo cubeos update --offline $output_dir"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# cmd_help — Show help
# ═══════════════════════════════════════════════════════════════════════════════

cmd_help() {
    cat << 'EOF'

  CubeOS CLI — Management commands for CubeOS installations

  Usage: cubeos <command> [options]

  Commands:
    status      Show service status, versions, and system info
    logs        Tail service logs (all or specific service)
    update      Update CubeOS to the latest version
    backup      Create a backup of CubeOS config and data
    restore     Restore CubeOS from a backup file
    uninstall   Remove CubeOS from this system
    download    Prepare an offline update bundle
    version     Show CLI version
    help        Show this help message

  Examples:
    cubeos status                          Show all services
    cubeos logs api -f                     Follow API logs
    cubeos update --check                  Check for updates
    cubeos update --channel beta           Switch to beta channel
    cubeos backup --encrypt                Create encrypted backup
    cubeos restore /path/to/backup.tar.gz  Restore from backup
    cubeos update --offline /path/         Apply offline update
    cubeos download --output /tmp/bundle/  Prepare offline bundle

EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# cmd_version — Show version
# ═══════════════════════════════════════════════════════════════════════════════

cmd_version() {
    echo "cubeos CLI v${CUBEOS_CLI_VERSION}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Main dispatcher
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    set -euo pipefail

    case "${1:-}" in
        status)    shift; cmd_status "$@" ;;
        logs)      shift; cmd_logs "$@" ;;
        update)    shift; cmd_update "$@" ;;
        backup)    shift; cmd_backup "$@" ;;
        restore)   shift; cmd_restore "$@" ;;
        uninstall) shift; cmd_uninstall "$@" ;;
        download)  shift; cmd_download "$@" ;;
        version|-v|--version) cmd_version ;;
        help|-h|--help) cmd_help ;;
        "")        cmd_help ;;
        *)         log_error "Unknown command: $1"; cmd_help; exit 1 ;;
    esac
}

main "$@"
