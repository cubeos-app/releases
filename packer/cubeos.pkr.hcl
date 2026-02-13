# =============================================================================
# CubeOS Release Image Builder
# =============================================================================
# Builds a flashable ARM64 image for Raspberry Pi 4/5.
#
# Uses the "golden base image" (Ubuntu 24.04.3 with all packages pre-installed)
# so this build only writes configuration, compose files, and firstboot scripts.
# No apt-get, no package downloads — build time is ~3-5 minutes.
#
# Base image is built separately on nllei01gpu01 (/srv/cubeos-base-builder)
# and stored in GitLab's Generic Package Registry.
#
# Usage (via CI — recommended):
#   Push to main branch or tag → pipeline auto-triggers
#
# Usage (Docker, direct — requires base image at /build/cubeos-base.img.xz):
#   docker run --rm --privileged -v /dev:/dev -v ${PWD}:/build \
#     mkaczanowski/packer-builder-arm:latest build /build/packer/cubeos.pkr.hcl
# =============================================================================

variable "version" {
  type    = string
  default = "0.1.0-alpha.4"
}

variable "image_size" {
  type    = string
  default = "8G"
}

# Golden base image — Ubuntu 24.04.3 with all packages pre-installed.
# Override in CI with: -var "base_image_url=file:///build/cubeos-base.img.xz"
# Accepts local file:// or remote https:// URLs.
variable "base_image_url" {
  type    = string
  default = "file:///build/cubeos-base.img.xz"
}

variable "base_image_checksum" {
  type    = string
  default = ""
}

variable "base_image_checksum_type" {
  type    = string
  default = "none"
}

source "arm" "cubeos" {
  file_urls             = [var.base_image_url]
  file_checksum         = var.base_image_checksum
  file_checksum_type    = var.base_image_checksum_type
  file_target_extension = "xz"
  file_unarchive_cmd    = ["xz", "-T0", "--decompress", "$ARCHIVE_PATH"]

  image_build_method = "resize"
  image_path         = "cubeos-${var.version}-arm64.img"
  image_size         = var.image_size
  image_type         = "dos"

  # Boot partition — FAT32 at /boot/firmware (Ubuntu: "system-boot")
  image_partitions {
    name         = "boot"
    type         = "c"
    start_sector = "2048"
    filesystem   = "fat"
    size         = "512M"
    mountpoint   = "/boot/firmware"
  }

  # Root partition — ext4 (Ubuntu: "writable")
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
  sources = ["source.arm.cubeos"]

  # ------------------------------------------------------------------
  # Phase 1: Networking (Netplan, hostapd template, iptables, cloud-init)
  # ------------------------------------------------------------------
  provisioner "shell" {
    script = "packer/scripts/02-networking.sh"
  }

  # ------------------------------------------------------------------
  # Phase 2: CubeOS directory structure, configs, coreapps
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

  # Pass CUBEOS_VERSION from packer var → shell env → defaults.env
  provisioner "shell" {
    script           = "packer/scripts/04-cubeos.sh"
    environment_vars = ["CUBEOS_VERSION=${var.version}"]
  }

  # ------------------------------------------------------------------
  # Phase 3: Copy pre-downloaded Docker image tarballs
  # ------------------------------------------------------------------
  provisioner "file" {
    source      = "docker-images/"
    destination = "/var/cache/cubeos-images/"
  }

  provisioner "shell" {
    script = "packer/scripts/05-docker-preload.sh"
  }

  # ------------------------------------------------------------------
  # Phase 4: First-boot service installation
  # ------------------------------------------------------------------
  provisioner "shell" {
    script = "packer/scripts/06-firstboot-service.sh"
  }

  # ------------------------------------------------------------------
  # Phase 5: Cleanup and image prep
  # ------------------------------------------------------------------
  provisioner "shell" {
    script = "packer/scripts/07-cleanup.sh"
  }
}
