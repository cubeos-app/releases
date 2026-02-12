# =============================================================================
# CubeOS Alpha Image Builder
# =============================================================================
# Builds a flashable ARM64 image for Raspberry Pi 4/5 from Raspberry Pi OS Lite.
#
# Usage (Docker, recommended):
#   docker run --rm --privileged -v /dev:/dev -v ${PWD}:/build \
#     mkaczanowski/packer-builder-arm:latest build /build/packer/cubeos.pkr.hcl
#
# Usage (native, requires root):
#   sudo packer build packer/cubeos.pkr.hcl
# =============================================================================

variable "version" {
  type    = string
  default = "0.1.0-alpha"
}

variable "image_size" {
  type    = string
  default = "8G"
}

# Raspberry Pi OS Lite Bookworm ARM64 (2024-10-22 release)
variable "base_image_url" {
  type    = string
  default = "https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-11-19/2024-11-19-raspios-bookworm-arm64-lite.img.xz"
}

variable "base_image_checksum" {
  type    = string
  default = "https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-11-19/2024-11-19-raspios-bookworm-arm64-lite.img.xz.sha256"
}

source "arm" "cubeos" {
  file_urls             = [var.base_image_url]
  file_checksum_url     = var.base_image_checksum
  file_checksum_type    = "sha256"
  file_target_extension = "xz"
  file_unarchive_cmd    = ["xz", "--decompress", "$ARCHIVE_PATH"]

  image_build_method = "resize"
  image_path         = "cubeos-${var.version}-arm64.img"
  image_size         = var.image_size
  image_type         = "dos"

  # Boot partition — FAT32 at /boot/firmware (Bookworm layout)
  image_partitions {
    name         = "boot"
    type         = "c"
    start_sector = "8192"
    filesystem   = "vfat"
    size         = "512M"
    mountpoint   = "/boot/firmware"
  }

  # Root partition — ext4, fills remaining space
  image_partitions {
    name         = "root"
    type         = "83"
    start_sector = "1056768"
    filesystem   = "ext4"
    size         = "0"
    mountpoint   = "/"
  }

  image_chroot_env             = ["PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"]
  qemu_binary_source_path      = "/usr/bin/qemu-aarch64-static"
  qemu_binary_destination_path = "/usr/bin/qemu-aarch64-static"
}

build {
  sources = ["source.arm.cubeos"]

  # ------------------------------------------------------------------
  # Phase 1: Base system setup (packages, kernel, sysctl)
  # ------------------------------------------------------------------
  provisioner "shell" {
    script = "packer/scripts/01-base-setup.sh"
  }

  # ------------------------------------------------------------------
  # Phase 2: Networking (netplan, hostapd template, iptables)
  # ------------------------------------------------------------------
  provisioner "shell" {
    script = "packer/scripts/02-networking.sh"
  }

  # ------------------------------------------------------------------
  # Phase 3: Docker Engine installation
  # ------------------------------------------------------------------
  provisioner "shell" {
    script = "packer/scripts/03-docker.sh"
  }

  # ------------------------------------------------------------------
  # Phase 4: CubeOS directory structure, configs, coreapps
  # ------------------------------------------------------------------

  # Copy config files into image
  provisioner "file" {
    source      = "configs/"
    destination = "/tmp/cubeos-configs/"
  }

  # Copy first-boot scripts
  provisioner "file" {
    source      = "firstboot/"
    destination = "/tmp/cubeos-firstboot/"
  }

  provisioner "shell" {
    script = "packer/scripts/04-cubeos.sh"
  }

  # ------------------------------------------------------------------
  # Phase 5: Copy pre-downloaded Docker image tarballs
  # ------------------------------------------------------------------
  provisioner "file" {
    source      = "docker-images/"
    destination = "/var/cache/cubeos-images/"
  }

  provisioner "shell" {
    script = "packer/scripts/05-docker-preload.sh"
  }

  # ------------------------------------------------------------------
  # Phase 6: First-boot service installation
  # ------------------------------------------------------------------
  provisioner "shell" {
    script = "packer/scripts/06-firstboot-service.sh"
  }

  # ------------------------------------------------------------------
  # Phase 7: Cleanup and image prep
  # ------------------------------------------------------------------
  provisioner "shell" {
    script = "packer/scripts/07-cleanup.sh"
  }
}
