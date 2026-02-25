# CubeOS Releases — Image Builder

Build flashable ARM64 SD card images for Raspberry Pi 4/5.

## Architecture

CubeOS uses a **two-tier build system** for fast, reproducible images:

```
┌──────────────────────────────────────────────────────────────┐
│ TIER 1: Golden Base Image (nllei01gpu01, ~20 min, manual)    │
│  Ubuntu 24.04.3 + all system packages → Package Registry     │
│  Rebuilt monthly or when package list changes.                │
├──────────────────────────────────────────────────────────────┤
│ TIER 2: Release Image (CI pipeline, ~5-10 min, automatic)    │
│                                                               │
│  Stage 1: DOWNLOAD (x86 native, ~2 min)                      │
│    skopeo pulls ARM64 Docker images → docker-images/*.tar     │
│                                                               │
│  Stage 2: BUILD (QEMU chroot, ~5 min — no apt-get!)          │
│    Packer takes golden base and applies:                      │
│    ├── 02-networking.sh    Netplan, hostapd, NAT, sysctl      │
│    ├── 04-cubeos.sh        /cubeos dirs, compose files, MOTD  │
│    ├── 05-docker-preload   First-boot image loading service   │
│    ├── 06-firstboot-svc    cubeos-init systemd service        │
│    └── 07-cleanup.sh       Caches, logs, zero free space      │
│                                                               │
│  Post-build: PiShrink → zerofree → xz → sha256               │
│  Output: cubeos-0.1.0-alpha-arm64.img.xz (~1.5 GB)           │
└──────────────────────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites

1. **Golden base image** in GitLab Package Registry (see `base-image/README.md`)
2. **CI variables** set in GitLab:
   - `GHCR_USER` — GitHub username for GHCR
   - `GHCR_TOKEN` — GitHub PAT with `read:packages` scope

### Build via GitLab CI (recommended)

Push to main triggers the release pipeline automatically:

```bash
git push origin main
```

Or push a tag for a formal release:

```bash
git tag v0.1.0-alpha
git push origin v0.1.0-alpha
```

### Build Locally

```bash
# 1. Download golden base from Package Registry
make download-base

# 2. Download ARM64 Docker images (native speed, ~2 min)
make images

# 3. Build image with Packer (~5 min)
make build

# 4. Compress (optional, ~5 min)
make compress
```

## Boot Flow

```
Power On
  │
  ├── Kernel boots (~5s)
  ├── Docker starts (~10s)
  ├── cubeos-docker-preload.service loads tarballs (~30s, first boot only)
  ├── cubeos-init.service detects boot mode
  │
  ├─── FIRST BOOT ──────────────────────────────────
  │  ├── Generate AP creds from wlan0 MAC
  │  ├── Generate device secrets (JWT, etc.)
  │  ├── Docker Swarm init
  │  ├── Deploy: Pi-hole → NPM → HAL → API → Dashboard
  │  ├── Start hostapd (CubeOS-XXYYZZ)
  │  └── Dashboard shows setup wizard
  │       └── User completes wizard → system operational
  │
  └─── NORMAL BOOT ─────────────────────────────────
     ├── Swarm auto-reconciles stacks
     ├── Verify compose services (Pi-hole, NPM, HAL)
     ├── Start hostapd with saved config
     ├── Apply saved network mode (NAT rules)
     └── System operational (~30s)
```

## Default Credentials

| Service   | Username          | Password     | Notes                    |
|-----------|-------------------|--------------|--------------------------|
| Dashboard | admin             | cubeos       | Forced change in wizard  |
| Pi-hole   | —                 | cubeos       | Web admin password       |
| NPM       | admin@cubeos.cube | changeme     | NPM built-in default    |
| SSH       | cubeos            | (key only)   | Password auth disabled   |
| WiFi AP   | —                 | cubeos-XXYYZZ| From wlan0 MAC address  |

## Directory Structure

```
releases/
├── .gitlab-ci.yml                  # CI pipeline (download + build stages)
├── Makefile                        # Local build commands
├── rpi-imager.json                 # Raspberry Pi Imager manifest
├── platforms/
│   ├── raspberrypi/                # Raspberry Pi image builder
│   │   ├── packer.pkr.hcl         # Pi Packer config (source "arm")
│   │   ├── scripts/
│   │   │   ├── 02-networking.sh    # Pi-specific: hostapd, netplan, wlan0
│   │   │   └── 09-console-gui.sh  # Pi-specific: framebuffer console
│   │   └── base-image/             # Golden base (built on GPU VM)
│   │       ├── cubeos-base.pkr.hcl
│   │       └── scripts/
│   ├── bananapi/                   # BananaPi M5/M7 (placeholder)
│   ├── pine64/                     # Pine64 (placeholder)
│   └── x86_64/                     # x86_64 Ubuntu Server (placeholder)
├── shared/
│   └── scripts/                    # Platform-agnostic build scripts
│       ├── 04-cubeos.sh            # /cubeos dirs, compose files, MOTD
│       ├── 05-docker-preload.sh    # Image tarball loading service
│       ├── 06-firstboot-service.sh # systemd init + watchdog services
│       ├── 07-cleanup.sh           # Cache cleanup, zero free space
│       └── 08-pihole-seed.sh      # Pi-hole gravity DB seeding
├── firstboot/                      # Runtime boot scripts (all platforms)
│   ├── cubeos-boot-detect.sh       # First vs normal boot detection
│   ├── cubeos-first-boot.sh        # First boot orchestrator
│   ├── cubeos-normal-boot.sh       # Normal boot script
│   ├── cubeos-generate-ap-creds.sh # MAC-based WiFi credentials
│   └── cubeos-generate-secrets.sh  # JWT/API secret generation
├── curl/                           # Tier 2 installer (platform-agnostic)
├── skopeo/
│   └── download-images.sh          # ARM64 Docker image downloader
├── configs/                        # Config templates (copied to /cubeos/config/)
└── assets/                         # Icons for Pi Imager manifest
```

## Testing with Raspberry Pi Imager

```bash
# Test with custom repository
rpi-imager --repo file:///path/to/releases/rpi-imager.json

# Or flash directly
xzcat cubeos-0.1.0-alpha-arm64.img.xz | sudo dd of=/dev/sdX bs=4M status=progress
```

## Rebuilding the Golden Base

See `base-image/README.md`. In short:

```bash
ssh root@nllei01gpu01
cd /srv/cubeos-base-builder
./build.sh
```

## License

Apache 2.0
