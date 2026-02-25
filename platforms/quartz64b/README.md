# CubeOS — Pine64 Quartz64 Model B Platform

Builds CubeOS images for Quartz64 Model B using Armbian as the base OS.

## Board Specifications

| Spec | Value |
|------|-------|
| **SoC** | Rockchip RK3566 (quad-core Cortex-A55, 1.8GHz) |
| **GPU** | Mali G-52-2EE (Panfrost open source driver) |
| **RAM** | 4GB LPDDR4 |
| **Storage** | microSD, eMMC module socket (up to 128GB), 128Mb SPI flash |
| **WiFi** | Built-in 802.11 b/g/n/ac + Bluetooth 5.0 |
| **Ethernet** | Gigabit |
| **M.2** | PCIe Gen2 x1 (single lane) |
| **Serial** | ttyS2 at 1500000 baud |
| **DTB** | `rockchip/rk3566-quartz64-b.dtb` |

> **Note:** This is a lower power board (A55 cores only, no big A76 cores).
> Well suited for low-power/always-on CubeOS deployments. Has built-in WiFi
> — AP mode support can be added in future versions.

## Status

**PLACEHOLDER** — this template will not build successfully until:

1. Base image URL is pinned to a specific Armbian version
2. Partition layout is confirmed on real hardware
3. WiFi driver compatibility is verified for AP mode

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
  platforms/quartz64b/packer.pkr.hcl
```

## Architecture

- **Base OS:** Armbian (Ubuntu Noble, current kernel)
- **SoC:** Rockchip RK3566
- **Bootloader:** U-Boot with armbianEnv.txt
- **Partition layout:** Single root partition (boot files in /boot on root)
- **Networking:** Wired Ethernet only for now (WiFi AP mode possible in future)
- **Network manager:** systemd-networkd (NetworkManager disabled)

## Key Differences from Other Platforms

| Feature | Raspberry Pi | Orange Pi 5 | ROCK 5B | Quartz64 B |
|---------|-------------|-------------|---------|------------|
| SoC | BCM2711/2712 | RK3588S | RK3588 | RK3566 |
| CPU cores | 4x A76 | 4x A76 + 4x A55 | 4x A76 + 4x A55 | 4x A55 |
| Power | Medium | High | High | Low |
| WiFi | Yes (AP) | No (optional) | No (optional) | Yes (AP possible) |
| Ethernet | GbE | GbE | 2.5GbE | GbE |
| NVMe | No | M.2 | M.2 | PCIe x1 |
| Use case | General | Performance | Performance | Always-on |
