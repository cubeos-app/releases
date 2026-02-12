# CubeOS Releases — Image Builder

Build flashable ARM64 SD card images for Raspberry Pi 4/5.

## Quick Start

### Prerequisites (build machine)

```bash
# Ubuntu 24.04 x86_64
sudo apt install -y qemu-user-static binfmt-support docker.io skopeo

# Register QEMU binfmt handlers
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

### Build Locally

```bash
# 1. Download ARM64 Docker images (native speed, ~2 min)
chmod +x skopeo/download-images.sh
./skopeo/download-images.sh

# 2. Build image with Packer (~15 min)
chmod +x packer/scripts/*.sh firstboot/*.sh
docker run --rm --privileged \
    -v /dev:/dev \
    -v ${PWD}:/build \
    mkaczanowski/packer-builder-arm:latest \
    build /build/packer/cubeos.pkr.hcl

# 3. Compress (optional, ~5 min)
sudo apt install -y pishrink zerofree xz-utils
sudo pishrink.sh cubeos-0.1.0-alpha-arm64.img
xz -6 -T0 cubeos-0.1.0-alpha-arm64.img
```

### Build via GitLab CI

Push a tag to trigger the full pipeline:

```bash
git tag v0.1.0-alpha
git push origin v0.1.0-alpha
```

Or trigger manually from GitLab CI/CD > Pipelines > Run Pipeline.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│ Stage 1: DOWNLOAD (x86 native, ~2 min)                   │
│  skopeo pulls ARM64 images → docker-images/*.tar          │
├──────────────────────────────────────────────────────────┤
│ Stage 2: BUILD (QEMU emulation, ~15 min)                  │
│  packer-builder-arm chroots into Pi OS image              │
│  ├── 01-base-setup.sh    packages, sysctl, SSH, watchdog  │
│  ├── 02-networking.sh    dhcpcd, hostapd, NAT scripts     │
│  ├── 03-docker.sh        Docker CE, daemon config         │
│  ├── 04-cubeos.sh        /cubeos dirs, compose files      │
│  ├── 05-docker-preload   first-boot image loading svc     │
│  ├── 06-firstboot-svc    cubeos-init systemd service      │
│  └── 07-cleanup.sh       caches, logs, zero free space    │
├──────────────────────────────────────────────────────────┤
│ Stage 3: COMPRESS (~5 min)                                │
│  PiShrink → zerofree → xz → sha256                       │
│  Output: cubeos-0.1.0-alpha-arm64.img.xz (~1.5 GB)       │
└──────────────────────────────────────────────────────────┘
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
├── packer/
│   ├── cubeos.pkr.hcl              # Packer build config
│   └── scripts/
│       ├── 01-base-setup.sh        # Packages, kernel, sysctl
│       ├── 02-networking.sh        # dhcpcd, hostapd, NAT
│       ├── 03-docker.sh            # Docker CE installation
│       ├── 04-cubeos.sh            # /cubeos dirs, compose files
│       ├── 05-docker-preload.sh    # Image tarball loading service
│       ├── 06-firstboot-service.sh # systemd init service
│       └── 07-cleanup.sh           # Cache cleanup, zero free
├── firstboot/
│   ├── cubeos-boot-detect.sh       # First vs normal boot detection
│   ├── cubeos-first-boot.sh        # First boot orchestrator
│   ├── cubeos-normal-boot.sh       # Normal boot script
│   ├── cubeos-generate-ap-creds.sh # MAC-based WiFi credentials
│   └── cubeos-generate-secrets.sh  # JWT/API secret generation
├── skopeo/
│   └── download-images.sh          # ARM64 image downloader
├── configs/
│   └── (config templates)
├── rpi-imager.json                 # Raspberry Pi Imager manifest
├── .gitlab-ci.yml                  # CI/CD pipeline
└── README.md                       # This file
```

## Testing with Raspberry Pi Imager

```bash
# Test with custom repository
rpi-imager --repo file:///path/to/releases/rpi-imager.json

# Or flash directly
xzcat cubeos-0.1.0-alpha-arm64.img.xz | sudo dd of=/dev/sdX bs=4M status=progress
```

## GPU VM Runner Setup

```bash
# On the GPU VM (nllei01gpu01), ensure:
sudo apt install -y qemu-user-static binfmt-support

# Register QEMU interpreters
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

# GitLab runner must have privileged mode enabled in config.toml:
# [[runners]]
#   executor = "docker"
#   [runners.docker]
#     privileged = true
#     volumes = ["/dev:/dev", "/cache"]
```

## License

Apache 2.0
