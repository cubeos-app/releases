# CubeOS x86_64 Platform

Builds CubeOS images for x86_64 systems: Intel NUCs, standard PCs, and VMs (QEMU/KVM, VMware, Proxmox).

## Prerequisites

- Packer >= 1.9
- QEMU with KVM support (`/dev/kvm` must be accessible)
- ~5GB free disk space (ISO + build output)

## Build

```bash
# From the releases repo root:

# Initialize Packer plugins (first time only)
packer init platforms/x86_64/packer.pkr.hcl

# Build the image
packer build \
  -var "version=0.2.0-beta.01" \
  -var "variant=full" \
  platforms/x86_64/packer.pkr.hcl
```

Output: `output-cubeos-x86/cubeos-0.2.0-beta.01-amd64.qcow2`

### Build variables

| Variable | Default | Description |
|----------|---------|-------------|
| `version` | `0.2.0-beta.01` | CubeOS version string |
| `variant` | `full` | `full` or `lite` |
| `image_size` | `20G` | Disk image size |
| `iso_url` | Ubuntu 24.04.4 | Ubuntu Server ISO URL |
| `iso_checksum` | (hardcoded) | SHA-256 of the ISO |

## Test in QEMU

```bash
qemu-system-x86_64 \
  -m 2048 \
  -smp 2 \
  -enable-kvm \
  -drive file=output-cubeos-x86/cubeos-0.2.0-beta.01-amd64.qcow2,format=qcow2 \
  -net nic,model=virtio \
  -net user,hostfwd=tcp::2222-:22,hostfwd=tcp::6010-:6010,hostfwd=tcp::6011-:6011 \
  -nographic
```

SSH into the VM:
```bash
ssh -p 2222 cubeos@localhost
# Password: cubeos
```

Verify:
```bash
cat /etc/cubeos-version
docker info
ls /cubeos/
echo $CUBEOS_PLATFORM  # should print x86_64
```

## Convert to other formats

```bash
# VMware (vmdk)
qemu-img convert -f qcow2 -O vmdk cubeos-0.2.0-beta.01-amd64.qcow2 cubeos-0.2.0-beta.01-amd64.vmdk

# Hyper-V (vhdx)
qemu-img convert -f qcow2 -O vhdx cubeos-0.2.0-beta.01-amd64.qcow2 cubeos-0.2.0-beta.01-amd64.vhdx

# Raw (for dd to USB/SSD)
qemu-img convert -f qcow2 -O raw cubeos-0.2.0-beta.01-amd64.qcow2 cubeos-0.2.0-beta.01-amd64.img
```

## Architecture differences from Raspberry Pi

| Aspect | Raspberry Pi | x86_64 |
|--------|-------------|--------|
| Packer builder | `packer-builder-arm` (chroot) | `qemu` (full VM) |
| Base | Golden base `.img` | Ubuntu 24.04 Server ISO |
| Bootloader | U-Boot / config.txt | GRUB |
| WiFi AP | hostapd on wlan0 | Not available |
| Console | HDMI + whiptail TUI | Serial (ttyS0) + VGA |
| Output format | Raw `.img` | qcow2 |
| Docker images | ARM64 | AMD64 |

## File structure

```
platforms/x86_64/
├── packer.pkr.hcl           # QEMU-based Packer template
├── scripts/
│   ├── 02-networking.sh     # x86 networking (no hostapd)
│   └── 09-post-install.sh   # GRUB config, serial console
├── http/
│   ├── user-data            # cloud-init autoinstall
│   └── meta-data            # empty (required by cloud-init)
├── base-image/
│   └── README.md            # explains x86 doesn't use golden base
└── README.md                # this file
```

Shared scripts used from `shared/scripts/`:
- `04-cubeos.sh` — directory structure, config, coreapps
- `05-docker-preload.sh` — Docker image preloading
- `06-firstboot-service.sh` — systemd firstboot service
- `07-cleanup.sh` — image cleanup
- `08-pihole-seed.sh` — Pi-hole gravity.db seed
