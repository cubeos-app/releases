# =============================================================================
# CubeOS Golden Base Image Builder — BPI-M4 Zero (Armbian)
# =============================================================================
# Takes stock Armbian Noble minimal for BPI-M4 Zero and installs all system
# packages (Docker, hostapd, dnsmasq, fail2ban, etc.).
#
# Produces a "golden base" that the release pipeline uses instead of stock
# Armbian, eliminating ~20+ minutes of apt-get under QEMU emulation from
# every release build.
#
# Run frequency: Monthly, or when the package list changes.
#
# Usage (Docker, recommended — from repo root):
#   docker run --rm --privileged -v /dev:/dev -v ${PWD}:/build \
#     mkaczanowski/packer-builder-arm:latest build \
#     /build/platforms/bananapim4zero/base-image/cubeos-base-armbian.pkr.hcl
#
# Usage (GPU VM — from /srv/cubeos-base-builder-bananapim4zero/):
#   ./build.sh
# =============================================================================

variable "image_size" {
  type    = string
  default = "10G"
}

# Armbian 26.2.1 Noble minimal for BPI-M4 Zero (Allwinner H618)
# Pinned 2026-03-20
variable "base_image_url" {
  type    = string
  default = "https://dl.armbian.com/bananapim4zero/archive/Armbian_26.2.1_Bananapim4zero_noble_current_6.12.68_minimal.img.xz"
}

variable "base_image_checksum" {
  type    = string
  default = "6427a31dd29f85f3eb5ee3af619140a0b213b7600e8afe63124969556b7cf7d9"
}

source "arm" "cubeos-base-armbian" {
  file_urls             = [var.base_image_url]
  file_checksum         = var.base_image_checksum
  file_checksum_type    = "sha256"
  file_target_extension = "xz"
  file_unarchive_cmd    = ["xz", "--decompress", "$ARCHIVE_PATH"]

  image_build_method = "resize"
  image_path         = "cubeos-base-armbian-noble-arm64.img"
  image_size         = var.image_size
  image_type         = "dos"

  # Armbian partition layout — single root partition
  # Boot files live in /boot on the root partition (not separate FAT)
  # start_sector 32768 is standard for Armbian sunxi64 builds
  # TODO: Verify on real hardware
  image_partitions {
    name         = "root"
    type         = "83"
    start_sector = "32768"
    filesystem   = "ext4"
    size         = "0"
    mountpoint   = "/"
  }

  image_chroot_env             = ["PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"]
  qemu_binary_source_path      = "/usr/bin/qemu-aarch64-static"
  qemu_binary_destination_path = "/usr/bin/qemu-aarch64-static"
}

build {
  sources = ["source.arm.cubeos-base-armbian"]

  # ------------------------------------------------------------------
  # Install all system packages on the Armbian base
  # ------------------------------------------------------------------
  provisioner "shell" {
    script = "platforms/bananapim4zero/base-image/scripts/01-armbian-base.sh"
  }

  # ------------------------------------------------------------------
  # Cleanup for minimal image size
  # ------------------------------------------------------------------
  provisioner "shell" {
    script = "platforms/bananapim4zero/base-image/scripts/02-cleanup.sh"
  }
}
