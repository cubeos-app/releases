# ALPHA.6 BUGFIX HANDOVER

## Summary

Alpha.5 images fail on fresh flash because the packer-built image has diverged
from the working Pi 5 production configuration. Alpha.6 fixes this by replacing
all stale heredoc compose files with a CI-time clone of the coreapps GitLab repo,
plus fixing 6 specific bugs identified from the Pi 5 snapshot analysis.

## Root Causes Fixed

| # | Bug | Alpha.5 (broken) | Alpha.6 (fixed) |
|---|-----|-------------------|------------------|
| 1 | daemon.json | `live-restore: true` (blocks Swarm) | Only `default-address-pools` |
| 2 | Network name | `cubeos` | `cubeos-network` |
| 3 | Overlay subnet | `172.20.0.0/24` | `10.42.25.0/24` |
| 4 | Swarm init | Stderr swallowed silently | Captured to `$SWARM_OUTPUT`, logged |
| 5 | HAL port | `6013` | `6005` |
| 6 | Dashboard internal port | `80` | `8087` (set in compose, from coreapps repo) |
| 7 | Compose files | Stale heredocs in packer script | Cloned from GitLab at CI time |
| 8 | Watchdog path | `/usr/local/lib/cubeos/` (stale copy) | `/cubeos/coreapps/scripts/` (symlinked) |
| 9 | Pi-hole healthcheck | `dig @127.0.0.1` (v5) | `curl :6001/admin/` (v6) |
| 10 | Stack coverage | Only api + dashboard | All 6: registry, api, dashboard, dozzle, ollama, chromadb |

## Architecture Change: Single Source of Truth

**Before (alpha.5):** Compose files were duplicated as heredocs inside
`packer/scripts/04-cubeos.sh`. Every time a compose file changed in the
coreapps repo, someone had to manually update the heredoc. This never happened,
causing massive drift.

**After (alpha.6):** The CI pipeline clones the `cubeos/coreapps` repo at build
time and injects it into the image via packer file provisioner. `04-cubeos.sh`
simply copies the bundle into `/cubeos/coreapps/`. Zero heredocs for compose
files.

```
CI Pipeline                    Packer Build
───────────                    ────────────
git clone coreapps ──┐
                     ├─→ coreapps-bundle/ ──→ file provisioner ──→ /tmp/cubeos-coreapps/
filter services    ──┘                                                     │
                                             04-cubeos.sh ──→ cp to /cubeos/coreapps/
```

## Files Changed (7 files)

### 1. `packer/cubeos.pkr.hcl`
- Version bumped to `0.1.0-alpha.6`
- Added `coreapps-bundle/` file provisioner block

### 2. `packer/scripts/04-cubeos.sh` (REWRITE)
- Removed ALL compose file heredocs (~165 lines of heredocs → 0)
- Added coreapps bundle copy logic from `/tmp/cubeos-coreapps/`
- Added `/etc/docker/daemon.json` creation (Swarm-compatible, no `live-restore`)
- Added all service directories (docsindex, filebrowser, diagnostics, etc.)
- Added symlink: `/cubeos/scripts` → `/cubeos/coreapps/scripts`
- Expanded `defaults.env` to match Pi 5 production format
- Expanded Pi-hole custom DNS seed entries

### 3. `firstboot/cubeos-first-boot.sh` (v4)
- Network name: `cubeos-network` everywhere
- Overlay subnet: `10.42.25.0/24`
- Swarm init: captures stderr to `$SWARM_OUTPUT` variable, logs on failure
- Removed Docker secrets (API uses env_file)
- HAL wait uses port 6005
- Deploys ALL 6 stacks (was 2)
- Pi-hole healthcheck: `curl :6001/admin/`
- Added `deploy_stack()` helper function

### 4. `firstboot/cubeos-normal-boot.sh` (v4)
- Same network/subnet/port fixes as first-boot
- Swarm recovery captures stderr
- Removed Docker secrets recreation
- Verifies ALL 6 stacks (was 2)

### 5. `firstboot/cubeos-deploy-stacks.sh` (v4)
- Same network/subnet fixes
- Deploys ALL 6 stacks
- Removes old `cubeos` network if found (alpha.5 cleanup)
- Captures swarm init stderr
- Starts compose services before stacks

### 6. `firstboot/watchdog-health.sh` (V4)
- Runs from `/cubeos/coreapps/scripts/` (matching Pi 5)
- Checks compose services: pihole, npm, HAL (port 6005)
- Checks ALL 6 swarm stacks
- Monitors hostapd
- Structured logging to `/cubeos/data/watchdog/`
- Log rotation (keeps under 1MB)
- Disk cleanup at 85% usage
- DNS resolver fallback
- Alert file for dashboard

### 7. `packer/scripts/06-firstboot-service.sh` (v4)
- Watchdog ExecStart: `/cubeos/coreapps/scripts/watchdog-health.sh`
- Installs to both paths with symlink for backward compat
- Timer OnBootSec bumped to 120s (was 90s, gives preload more time)

## CI Pipeline Changes Required

Add this to `.gitlab-ci.yml` **before** the packer build step:

```yaml
build-image:
  stage: build
  variables:
    CUBEOS_VERSION: "0.1.0-alpha.6"
  before_script:
    # Clone coreapps repo and prepare bundle for packer
    - |
      echo "=== Preparing coreapps bundle ==="
      git clone --depth 1 \
        "https://gitlab-ci-token:${CI_JOB_TOKEN}@${CI_SERVER_HOST}/cubeos/coreapps.git" \
        /tmp/coreapps-src

      # Services to include in the image
      SERVICES="pihole npm cubeos-api cubeos-hal cubeos-dashboard dozzle ollama chromadb registry"

      mkdir -p coreapps-bundle
      for svc in $SERVICES; do
        if [ -d "/tmp/coreapps-src/${svc}" ]; then
          mkdir -p "coreapps-bundle/${svc}"
          # Copy appconfig (compose files, .env)
          if [ -d "/tmp/coreapps-src/${svc}/appconfig" ]; then
            cp -r "/tmp/coreapps-src/${svc}/appconfig" "coreapps-bundle/${svc}/"
          fi
        else
          echo "WARNING: Service ${svc} not found in coreapps repo"
        fi
      done

      # Copy scripts directory
      if [ -d "/tmp/coreapps-src/scripts" ]; then
        cp -r /tmp/coreapps-src/scripts coreapps-bundle/
      fi

      echo "=== Coreapps bundle contents ==="
      find coreapps-bundle -type f | sort
      rm -rf /tmp/coreapps-src
  script:
    - |
      docker run --rm --privileged \
        -v /dev:/dev \
        -v ${PWD}:/build \
        mkaczanowski/packer-builder-arm:latest \
        build \
        -var "version=${CUBEOS_VERSION}" \
        -var "base_image_url=file:///build/cubeos-base.img.xz" \
        /build/packer/cubeos.pkr.hcl
```

## Verification Checklist

After flashing alpha.6 image and first boot completes:

```bash
# 1. daemon.json — no live-restore
cat /etc/docker/daemon.json
# Expected: {"default-address-pools": [{"base": "172.16.0.0/12", "size": 24}]}

# 2. Swarm active
docker info 2>/dev/null | grep "Swarm:"
# Expected: Swarm: active

# 3. Correct overlay network
docker network ls | grep cubeos
# Expected: cubeos-network  overlay  swarm

# 4. All services running
docker service ls
# Expected: 6+ services, all showing 1/1

# 5. Compose services
docker ps --format "table {{.Names}}\t{{.Status}}" | grep cubeos
# Expected: cubeos-pihole, cubeos-npm, cubeos-hal all Up

# 6. API health
curl -s http://127.0.0.1:6010/health
# Expected: 200 OK with JSON

# 7. Dashboard accessible
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:6011/
# Expected: 200

# 8. HAL on correct port
curl -s http://127.0.0.1:6005/health
# Expected: 200 OK

# 9. Watchdog path
ls -la /cubeos/coreapps/scripts/watchdog-health.sh
systemctl status cubeos-watchdog.timer
# Expected: file exists, timer active

# 10. No old network
docker network ls | grep -w "cubeos "
# Expected: no output (only cubeos-network should exist)

# 11. Boot log clean
grep -c "✗\|FATAL\|failed" /var/log/cubeos-first-boot.log
# Expected: 0 (or very low)
```

## Rollback

If alpha.6 fails, reflash alpha.5 and SSH in to manually fix:

```bash
# Fix daemon.json
echo '{"default-address-pools": [{"base": "172.16.0.0/12", "size": 24}]}' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker

# Fix network
docker swarm leave --force 2>/dev/null || true
docker swarm init --advertise-addr 10.42.24.1 --task-history-limit 1
docker network create --driver overlay --attachable --subnet 10.42.25.0/24 cubeos-network
```

## What's NOT in Alpha.6

These are known gaps that are not blocking but should be addressed:

1. **Docker version pinning** — Pi 4B got 28.5.2 vs Pi 5's 28.2.2. Consider
   `apt-mark hold docker-ce` in the golden base.
2. **Additional coreapps** — docsindex, filebrowser, diagnostics, reset,
   terminal, backup, watchdog containers are directories only (no images baked in).
3. **env_file path validation** — Compose files reference `env_file:` paths that
   must exist at deploy time. First-boot creates defaults.env before stack deploy,
   but edge cases may exist.
4. **AppArmor** — Pi 5 has `fix-apparmor.sh` in coreapps/scripts. Not called
   during first-boot. May need adding if Ubuntu 24.04 blocks containers.
