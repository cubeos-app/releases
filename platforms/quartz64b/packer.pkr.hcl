# =============================================================================
# CubeOS Pine64 Quartz64 Model B Release Image Builder — v0.2.0-beta.01
# =============================================================================
# Builds a flashable ARM64 image for Quartz64 Model B (Rockchip RK3566).
#
# Uses packer-builder-arm (same plugin as Raspberry Pi) but with:
#   - Armbian base image instead of Ubuntu for Pi
#   - Single root partition (boot files in /boot on root, not separate FAT)
#   - armbianEnv.txt instead of config.txt
#   - Built-in WiFi 802.11ac + Bluetooth 5.0 — AP mode possible
#   - Lower power SoC (A55 only, no big A76 cores)
#
# SoC: Rockchip RK3566 (quad-core Cortex-A55, 1.8GHz)
#       Mali G-52-2EE GPU (Panfrost open source driver)
#       Good for low-power/always-on deployments
#
# STATUS: PLACEHOLDER — will not build until:
#   1. Base image URL is verified (Armbian releases change frequently)
#   2. Partition layout is confirmed on real hardware
#   3. Package list is verified for Armbian
#
# TODO: Verify base image URL at https://www.armbian.com/quartz64-b/
# TODO: Verify partition start sector matches Armbian RK3566 image layout
# TODO: Test on real Quartz64 Model B hardware
# TODO: Add WiFi AP mode support (board has built-in WiFi)
# =============================================================================

variable "version" {
  type    = string
  default = "0.2.0-beta.01"
}

variable "variant" {
  type    = string
  default = "full"
  # Accepted values: "full", "lite"
}

variable "image_size" {
  type    = string
  default = "10G"
  # Smaller default — lower power board, less storage expected
}

variable "base_image_url" {
  type    = string
  default = "https://dl.armbian.com/quartz64-b/Noble_current_minimal"
  # Armbian minimal image for Quartz64 Model B (RK3566)
  # Alternative: https://dl.armbian.com/quartz64-b/Noble_current_server
  # TODO: Pin to a specific version once verified on hardware
}

variable "base_image_checksum" {
  type    = string
  default = ""
  # TODO: Download SHA256 from Armbian and set here
}

variable "base_image_checksum_type" {
  type    = string
  default = "none"
  # Set to "sha256" when checksum is available
}

source "arm" "cubeos-quartz64b" {
  file_urls             = [var.base_image_url]
  file_checksum         = var.base_image_checksum
  file_checksum_type    = var.base_image_checksum_type
  file_target_extension = "xz"
  file_unarchive_cmd    = ["xz", "-T0", "--decompress", "$ARCHIVE_PATH"]

  image_build_method = "resize"
  image_path         = var.variant == "lite" ? "cubeos-${var.version}-lite-quartz64b-arm64.img" : "cubeos-${var.version}-quartz64b-arm64.img"
  image_size         = var.image_size
  image_type         = "dos"

  # Armbian partition layout — single root partition
  # Boot files live in /boot on the root partition (not a separate FAT partition)
  # TODO: Verify start_sector matches the actual Armbian RK3566 image layout
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
  sources = ["source.arm.cubeos-quartz64b"]

  # Phase 1: Armbian networking (has WiFi but AP not configured yet)
  provisioner "shell" {
    script = "platforms/quartz64b/scripts/02-networking.sh"
  }

  # Phase 2: CubeOS structure + coreapps (SHARED)
  provisioner "file" {
    source      = "configs/"
    destination = "/tmp/cubeos-configs/"
  }

  provisioner "file" {
    source      = "firstboot/"
    destination = "/tmp/cubeos-firstboot/"
  }

  provisioner "file" {
    source      = "static/"
    destination = "/tmp/cubeos-static/"
  }

  provisioner "file" {
    source      = "coreapps-bundle/"
    destination = "/tmp/cubeos-coreapps/"
  }

  provisioner "shell" {
    script           = "shared/scripts/04-cubeos.sh"
    environment_vars = [
      "CUBEOS_VERSION=${var.version}",
      "CUBEOS_VARIANT=${var.variant}",
    ]
  }

  # Phase 3: Docker preload, Pi-hole seed, firstboot service, board config, cleanup
  provisioner "shell" {
    environment_vars = [
      "CUBEOS_VARIANT=${var.variant}",
    ]
    scripts = [
      "shared/scripts/05-docker-preload.sh",
      "shared/scripts/08-pihole-seed.sh",
      "shared/scripts/06-firstboot-service.sh",
      "platforms/quartz64b/scripts/09-board-config.sh",
      "shared/scripts/07-cleanup.sh",
    ]
  }
}
