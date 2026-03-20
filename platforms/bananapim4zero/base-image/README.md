# CubeOS Golden Base — BPI-M4 Zero (Armbian)

Builds a golden base image from stock Armbian Noble minimal for the BananaPi BPI-M4 Zero (Allwinner H618).

The golden base pre-installs all system packages (~60+ packages including Docker, hostapd, fail2ban, etc.) so the release pipeline only needs to apply configuration (~5 min instead of ~30 min).

## Build

Same pattern as the Raspberry Pi golden base. Run from the **repo root**:

```bash
# Docker build (recommended):
docker run --rm --privileged -v /dev:/dev -v ${PWD}:/build -w /build \
  mkaczanowski/packer-builder-arm:latest build \
  platforms/bananapim4zero/base-image/cubeos-base-armbian.pkr.hcl

# Or use the build script (builds + uploads to GitLab Package Registry):
./platforms/bananapim4zero/base-image/build.sh
./platforms/bananapim4zero/base-image/build.sh --build-only  # no upload
```

## Output

- `cubeos-base-armbian-noble-arm64.img` (~4-5 GB uncompressed)
- Compressed with `xz -6`: `cubeos-base-armbian-noble-arm64.img.xz` (~1-2 GB)
- Uploaded to GitLab Package Registry as `cubeos-base-armbian/1.0.0`

## Differences from Pi Golden Base

| Feature | Raspberry Pi | BPI-M4 Zero |
|---------|-------------|-------------|
| Stock base | Ubuntu 24.04.3 Server for Pi | Armbian 26.2.1 Noble minimal |
| Partition | FAT boot + ext4 root | Single ext4 root |
| Pi-specific | libraspberrypi-bin, gpiod, pps-tools | Not installed |
| WiFi chip | BCM4345 (built-in) | RTL8821CS (built-in) |
| Same packages | Docker, hostapd, fail2ban, bluez, etc. | Yes — same full package set |

## Rebuild Frequency

Monthly, or when the package list changes. The golden base is NOT rebuilt on every release — only the release image (Tier 2) is.
