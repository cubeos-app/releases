# CubeOS — BananaPi BPI-M4 Zero Platform

Builds CubeOS images for BananaPi BPI-M4 Zero using Armbian as the base OS.

## Board Specifications

| Spec | Value |
|------|-------|
| **SoC** | Allwinner H618 (quad-core Cortex-A53, 1.5GHz) |
| **RAM** | 4GB |
| **Storage** | 32GB eMMC + microSD slot |
| **WiFi** | Built-in (RTL8821CS, 2.4/5GHz) |
| **Bluetooth** | Built-in (currently broken in Armbian) |
| **Ethernet** | 100Mbps via USB |
| **Serial** | ttyS0 (Allwinner UART0) |

> **Note:** This is a DIFFERENT board from BPI-M5 (Amlogic S905X3, no WiFi, GbE).
> The M4 Zero has WiFi AP capability — future CubeOS versions may support AP
> mode on this platform (similar to Raspberry Pi).

## Status

**PLACEHOLDER** — this template will not build successfully until:

1. Base image URL is pinned to a specific Armbian version
2. Partition layout is confirmed on real hardware
3. eMMC device path (/dev/mmcblk1) is verified
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
  platforms/bananapim4zero/packer.pkr.hcl
```

## Architecture

- **Base OS:** Armbian (Ubuntu Noble, current kernel)
- **SoC:** Allwinner H618
- **Bootloader:** U-Boot with armbianEnv.txt
- **Partition layout:** Single root partition (boot files in /boot on root)
- **Networking:** Wired Ethernet only for now (WiFi AP mode possible in future)
- **Network manager:** systemd-networkd (NetworkManager disabled)

## Key Differences from Other Platforms

| Feature | Raspberry Pi | BPI-M5 | BPI-M4 Zero |
|---------|-------------|--------|-------------|
| SoC | BCM2711/2712 | Amlogic S905X3 | Allwinner H618 |
| Base OS | Ubuntu for Pi | Armbian | Armbian |
| Boot config | config.txt | armbianEnv.txt | armbianEnv.txt |
| Partitions | FAT boot + ext4 root | Single ext4 root | Single ext4 root |
| WiFi | Yes (hostapd AP) | No | Yes (AP possible) |
| eMMC | No | No | 32GB |
| Ethernet | GbE | GbE | 100Mbps USB |
| Serial console | ttyAMA0 | ttyAML0 | ttyS0 |
