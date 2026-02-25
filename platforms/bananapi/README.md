# CubeOS — BananaPi M5 Platform

Builds CubeOS images for BananaPi M5 using Armbian as the base OS.

## Status

**PLACEHOLDER** — this template will not build successfully until:

1. Base image URL is verified (Armbian releases change frequently)
2. Partition layout is confirmed on real hardware
3. Golden base package list is verified for Armbian
4. Board-specific armbianEnv.txt settings are validated

## Prerequisites

- Docker with privileged mode
- `packer-builder-arm` plugin
- QEMU aarch64 binfmt registered

## Build

```bash
# From repo root:
docker run --rm --privileged \
  -v /dev:/dev -v $(PWD):/build -w /build \
  mkaczanowski/packer-builder-arm:latest build \
  -var "version=0.2.0-beta.01" \
  platforms/bananapi/packer.pkr.hcl
```

## Architecture

- **Base OS:** Armbian (Ubuntu Noble, current kernel)
- **Bootloader:** U-Boot with armbianEnv.txt
- **Partition layout:** Single root partition (boot files in /boot on root)
- **Networking:** Wired Ethernet only (no onboard WiFi)
- **Network manager:** systemd-networkd (NetworkManager disabled)

## Key Differences from Raspberry Pi

| Feature | Raspberry Pi | BananaPi M5 |
|---------|-------------|-------------|
| Base OS | Ubuntu for Pi (golden base) | Armbian |
| Boot config | config.txt | armbianEnv.txt |
| Partitions | FAT boot + ext4 root | Single ext4 root |
| WiFi AP | hostapd on wlan0 | Not available |
| Build plugin | packer-builder-arm | packer-builder-arm |
