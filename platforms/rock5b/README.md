# CubeOS — Radxa ROCK 5B Platform

Builds CubeOS images for Radxa ROCK 5B using Armbian as the base OS.

## Board Specifications

| Spec | Value |
|------|-------|
| **SoC** | Rockchip RK3588 (quad A76 2.4GHz + quad A55 1.8GHz, 6 TOPS NPU) |
| **RAM** | 4GB / 8GB / 16GB LPDDR4x |
| **Storage** | microSD, eMMC socket, M.2 NVMe, SPI flash |
| **WiFi** | None built-in (optional module on some revisions) |
| **Ethernet** | 2.5 Gigabit |
| **Serial** | ttyS2 at 1500000 baud |
| **DTB** | `rockchip/rk3588-rock-5b.dtb` |

> **Note:** This board uses the full RK3588 (not the cost-reduced RK3588S).
> 2.5GbE interface may appear as `eth0`, `end0`, or `enP*` depending on kernel.

## Status

**PLACEHOLDER** — this template will not build successfully until:

1. Base image URL is pinned to a specific Armbian version
2. Partition layout is confirmed on real hardware
3. Power supply compatibility is verified

## Known Issues

- **USB-C PD boot loop:** USB-C Power Delivery is broken on most ROCK 5B revisions, causing boot loops. Workaround: use a fixed 5-24V USB-C power supply (NOT a PD/QC charger). See: https://www.armbian.com/rock-5b/
- **SPI flash conflict:** If the board has a stock OS in SPI flash, Armbian may not boot from SD card. Erase SPI first with `dd if=/dev/zero of=/dev/mtdblock0 bs=4096` or use `armbian-install`.

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
  platforms/rock5b/packer.pkr.hcl
```

## Architecture

- **Base OS:** Armbian (Ubuntu Noble, current kernel)
- **SoC:** Rockchip RK3588
- **Bootloader:** U-Boot with armbianEnv.txt
- **Partition layout:** Single root partition (boot files in /boot on root)
- **Networking:** Wired Ethernet only (2.5 Gigabit, no built-in WiFi)
- **Network manager:** systemd-networkd (NetworkManager disabled)
