# CubeOS — Orange Pi 5 Platform

Builds CubeOS images for Orange Pi 5 using Armbian as the base OS.

## Board Specifications

| Spec | Value |
|------|-------|
| **SoC** | Rockchip RK3588S (quad A76 2.4GHz + quad A55 1.8GHz) |
| **RAM** | 4GB / 8GB / 16GB LPDDR4x |
| **Storage** | microSD, eMMC socket, M.2 NVMe, SPI flash |
| **WiFi** | None built-in (optional AP6275P module) |
| **Ethernet** | Gigabit |
| **Serial** | ttyS2 at 1500000 baud (3-pin debug header) |
| **DTB** | `rockchip/rk3588s-orangepi-5.dtb` |

> **Note:** This board uses the RK3588**S** (cost-reduced variant), not the full RK3588.
> No built-in WiFi — AP mode is not available without the optional module.

## Status

**PLACEHOLDER** — this template will not build successfully until:

1. Base image URL is pinned to a specific Armbian version
2. Partition layout is confirmed on real hardware
3. SPI flash interaction with SD boot is verified

## Known Issues

- **SPI flash conflict:** If the board has a stock OS in SPI flash, Armbian may not boot from SD card. Erase SPI first with `dd if=/dev/zero of=/dev/mtdblock0 bs=4096` or use `armbian-install`.
- Optional WiFi module (AP6275P) requires an Armbian device tree overlay to enable — not managed by CubeOS yet.

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
  platforms/orangepi5/packer.pkr.hcl
```

## Architecture

- **Base OS:** Armbian (Ubuntu Noble, current kernel)
- **SoC:** Rockchip RK3588S
- **Bootloader:** U-Boot with armbianEnv.txt
- **Partition layout:** Single root partition (boot files in /boot on root)
- **Networking:** Wired Ethernet only (no built-in WiFi)
- **Network manager:** systemd-networkd (NetworkManager disabled)
