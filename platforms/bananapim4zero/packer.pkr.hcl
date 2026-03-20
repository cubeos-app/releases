# =============================================================================
# CubeOS BananaPi BPI-M4 Zero Release Image Builder — v0.2.0-beta.01
# =============================================================================
# Builds a flashable ARM64 image for BananaPi BPI-M4 Zero (Allwinner H618).
#
# Uses packer-builder-arm (same plugin as Raspberry Pi) but with:
#   - Armbian base image instead of Ubuntu for Pi
#   - Single root partition (boot files in /boot on root, not separate FAT)
#   - armbianEnv.txt instead of config.txt
#   - Built-in WiFi (RTL8821CS) — hostapd AP mode configured, needs HW testing
#   - 32GB eMMC onboard (/dev/mmcblk1, SD card is /dev/mmcblk0)
#
# NOTE: This is a DIFFERENT board from BPI-M5 (Amlogic S905X3, no WiFi).
#       The M4 Zero uses Allwinner H618 (quad-core Cortex-A53, 1.5GHz).
#
# TWO-TIER BUILD (same as Raspberry Pi):
#   Tier 1: Golden base (base-image/) — Armbian + all packages (~30 min QEMU)
#   Tier 2: This template — applies CubeOS config on golden base (~5 min)
#
# Partition start_sector 32768 is standard for Armbian sunxi64 builds.
# TODO: Verify partition start sector on real BPI-M4 Zero hardware
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
  default = "12G"
}

variable "base_image_url" {
  type    = string
  default = "file:///build/cubeos-base-armbian.img.xz"
  # Golden base image — built by base-image/cubeos-base-armbian.pkr.hcl
  # CI downloads from GitLab Package Registry before running Packer.
  # For local builds: place cubeos-base-armbian.img.xz in the build dir.
  #
  # Stock Armbian (for golden base builder, NOT for release builds):
  #   https://dl.armbian.com/bananapim4zero/archive/Armbian_26.2.1_Bananapim4zero_noble_current_6.12.68_minimal.img.xz
  #   SHA256: 6427a31dd29f85f3eb5ee3af619140a0b213b7600e8afe63124969556b7cf7d9
}

variable "base_image_checksum" {
  type    = string
  default = "28747a594dc626d4446a3fd1e78be21c0050dea322133a2963387663dfd7f2b3"
}

variable "base_image_checksum_type" {
  type    = string
  default = "sha256"
}

source "arm" "cubeos-bananapim4zero" {
  file_urls             = [var.base_image_url]
  file_checksum         = var.base_image_checksum
  file_checksum_type    = var.base_image_checksum_type
  file_target_extension = "xz"
  file_unarchive_cmd    = ["xz", "-T0", "--decompress", "$ARCHIVE_PATH"]

  image_build_method = "resize"
  image_path         = var.variant == "lite" ? "cubeos-${var.version}-lite-bananapim4zero-arm64.img" : "cubeos-${var.version}-bananapim4zero-arm64.img"
  image_size         = var.image_size
  image_type         = "dos"

  # Armbian partition layout — single root partition
  # Boot files live in /boot on the root partition (not a separate FAT partition)
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
  sources = ["source.arm.cubeos-bananapim4zero"]

  # Phase 1: Armbian networking (systemd-networkd, hostapd AP, user setup)
  provisioner "shell" {
    script = "platforms/bananapim4zero/scripts/02-networking.sh"
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
      "platforms/bananapim4zero/scripts/09-console-gui.sh",
      "platforms/bananapim4zero/scripts/09-board-config.sh",
      "shared/scripts/07-cleanup.sh",
    ]
  }
}
