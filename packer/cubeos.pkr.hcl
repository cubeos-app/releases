# =============================================================================
# CubeOS Release Image Builder — v0.1.0-alpha.8
# =============================================================================
# Builds a flashable ARM64 image for Raspberry Pi 4/5.
#
# Uses the "golden base image" (Ubuntu 24.04.3 with all packages pre-installed)
# so this build only writes configuration, compose files, and firstboot scripts.
# No apt-get, no package downloads — build time is ~3-5 minutes.
#
# ALPHA.8 CHANGES:
#   - secrets.env permissions: 640 root:docker (was 600 root:root)
#   - SSH password auth enabled via sshd_config.d/99-cubeos.conf
#   - cloud-init disabled after first boot (prevents air-gap timeout delays)
#   - Removed ensure_image_loaded placeholder guards from stack deploy
#   - Dashboard nginx proxy_pass fix (66188a7)
#   - NPM core proxy rule auto-seeding on API startup (de0cffd)
#   - secrets.env mounted into API container (4e43a3a)
#
# ALPHA.7 CHANGES:
#   - 02-networking.sh: eth0 DHCP hardening (dhcp-identifier, use-dns:false)
#   - 02-networking.sh: systemd-resolved points to Pi-hole + cubeos.cube domain
#   - 02-networking.sh: /etc/hosts fallback for hostname resolution
#   - 08-pihole-seed.sh: Pre-seed gravity.db for offline-first Pi-hole boot
#   - Pi-hole compose: FTLCONF_ env vars for offline operation + wildcard DNS
#   - Combined final shell provisioners to avoid Packer plugin process limit
#
# ALPHA.6 CHANGES:
#   - Coreapps compose files cloned from GitLab at CI time (no more heredocs)
#   - daemon.json is Swarm-compatible (no live-restore)
#   - Network name: cubeos-network (overlay subnet 10.42.25.0/24)
#   - Swarm init captures stderr for debugging
#   - HAL port: 6005 (was 6013)
#   - Pi-hole v6 FTLCONF_* env vars
#   - Watchdog runs from /cubeos/coreapps/scripts/
# =============================================================================

variable "version" {
  type    = string
  default = "0.1.0-alpha.8"
}

variable "image_size" {
  type    = string
  default = "8G"
}

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

  image_partitions {
    name         = "boot"
    type         = "c"
    start_sector = "2048"
    filesystem   = "fat"
    size         = "512M"
    mountpoint   = "/boot/firmware"
  }

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

  # Phase 1: Networking (hostapd, NAT, cloud-init, netplan)
  provisioner "shell" {
    script = "packer/scripts/02-networking.sh"
  }

  # Phase 2: CubeOS structure + coreapps
  provisioner "file" {
    source      = "configs/"
    destination = "/tmp/cubeos-configs/"
  }

  provisioner "file" {
    source      = "firstboot/"
    destination = "/tmp/cubeos-firstboot/"
  }

  provisioner "file" {
    source      = "coreapps-bundle/"
    destination = "/tmp/cubeos-coreapps/"
  }

  provisioner "shell" {
    script           = "packer/scripts/04-cubeos.sh"
    environment_vars = ["CUBEOS_VERSION=${var.version}"]
  }

  # Phase 3: Docker image tarballs
  provisioner "file" {
    source      = "docker-images/"
    destination = "/var/cache/cubeos-images/"
  }

  # Phase 4: Docker preload, Pi-hole seed, firstboot service, cleanup
  # Combined into one provisioner to stay within Packer's plugin process limit.
  # Scripts run sequentially in order listed.
  provisioner "shell" {
    scripts = [
      "packer/scripts/05-docker-preload.sh",
      "packer/scripts/08-pihole-seed.sh",
      "packer/scripts/06-firstboot-service.sh",
      "packer/scripts/07-cleanup.sh",
    ]
  }
}
