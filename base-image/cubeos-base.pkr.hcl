# =============================================================================
# CubeOS Golden Base Image Builder
# =============================================================================
# Takes stock Ubuntu 24.04.3 Server for Raspberry Pi and installs all system
# packages (Docker, hostapd, dnsmasq, fail2ban, watchdog, etc.).
#
# This produces a "golden base" that the release pipeline uses instead of
# stock Ubuntu, eliminating ~17 minutes of apt-get under QEMU emulation
# from every release build.
#
# Run frequency: Monthly, or when the package list changes.
#
# Usage (Docker, recommended):
#   docker run --rm --privileged -v /dev:/dev -v ${PWD}:/build \
#     mkaczanowski/packer-builder-arm:latest build /build/base-image/cubeos-base.pkr.hcl
# =============================================================================

variable "ubuntu_version" {
  type    = string
  default = "24.04.3"
}

variable "image_size" {
  type    = string
  default = "8G"
}

# Ubuntu 24.04.3 Server for Raspberry Pi (arm64)
variable "base_image_url" {
  type    = string
  default = "https://cdimage.ubuntu.com/releases/noble/release/ubuntu-24.04.3-preinstalled-server-arm64+raspi.img.xz"
}

variable "base_image_checksum" {
  type    = string
  default = "9bb1799cee8965e6df0234c1c879dd35be1d87afe39b84951f278b6bd0433e56"
}

source "arm" "cubeos-base" {
  file_urls             = [var.base_image_url]
  file_checksum         = var.base_image_checksum
  file_checksum_type    = "sha256"
  file_target_extension = "xz"
  file_unarchive_cmd    = ["xz", "--decompress", "$ARCHIVE_PATH"]

  image_build_method = "resize"
  image_path         = "cubeos-base-ubuntu${var.ubuntu_version}-arm64.img"
  image_size         = var.image_size
  image_type         = "dos"

  # Boot partition — FAT32 at /boot/firmware (Ubuntu labels this "system-boot")
  image_partitions {
    name         = "boot"
    type         = "c"
    start_sector = "2048"
    filesystem   = "fat"
    size         = "512M"
    mountpoint   = "/boot/firmware"
  }

  # Root partition — ext4 (Ubuntu labels this "writable")
  image_partitions {
    name         = "root"
    type         = "83"
    start_sector = "1050624"
    filesystem   = "ext4"
    size         = "0"
    mountpoint   = "/"
  }

  image_chroot_env             = ["PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"]
  qemu_binary_source_path      = "/usr/bin/qemu-aarch64-static"
  qemu_binary_destination_path = "/usr/bin/qemu-aarch64-static"
}

build {
  sources = ["source.arm.cubeos-base"]

  # ------------------------------------------------------------------
  # Install all system packages on the Ubuntu base
  # ------------------------------------------------------------------
  provisioner "shell" {
    script = "base-image/scripts/01-ubuntu-base.sh"
  }

  # ------------------------------------------------------------------
  # Cleanup for minimal image size
  # ------------------------------------------------------------------
  provisioner "shell" {
    script = "base-image/scripts/02-cleanup.sh"
  }
}
