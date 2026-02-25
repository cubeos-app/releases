# =============================================================================
# CubeOS x86_64 Release Image Builder — v0.2.0-beta.01
# =============================================================================
# Builds a qcow2 image for x86_64 systems (Intel NUCs, PCs, VMs).
#
# Uses Ubuntu 24.04 Server ISO as base, installed via cloud-init autoinstall.
# The QEMU builder runs a full VM (unlike the Pi build which uses chroot).
# After Ubuntu installs, Packer provisions CubeOS config via SSH.
#
# Output: qcow2 image compatible with QEMU/KVM, Proxmox, and convertible
# to vmdk (VMware) or vhd (Hyper-V) via qemu-img convert.
#
# Key differences from Raspberry Pi build:
#   - QEMU builder (not packer-builder-arm chroot)
#   - Ubuntu autoinstall via cloud-init (not golden base image)
#   - GRUB bootloader (not U-Boot/config.txt)
#   - GPT partitioning (not MBR/DOS)
#   - No WiFi AP (hostapd) — wired Ethernet only
#   - SSH provisioning (not chroot)
#   - AMD64 architecture (not ARM64)
# =============================================================================

packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

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
  default = "20G"
}

variable "iso_url" {
  type    = string
  default = "https://releases.ubuntu.com/noble/ubuntu-24.04.4-live-server-amd64.iso"
}

variable "iso_checksum" {
  type    = string
  default = "sha256:e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433"
  # Verified from https://releases.ubuntu.com/noble/SHA256SUMS
}

source "qemu" "cubeos-x86" {
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  output_directory = "output-cubeos-x86"
  vm_name          = var.variant == "lite" ? "cubeos-${var.version}-lite-amd64.qcow2" : "cubeos-${var.version}-amd64.qcow2"
  disk_size        = var.image_size
  format           = "qcow2"

  cpus   = 2
  memory = 2048

  headless    = true
  accelerator = "kvm"

  # Disk
  disk_interface = "virtio"

  # Network
  net_device = "virtio-net"

  # Boot command — enter GRUB command line and trigger Ubuntu autoinstall
  # The 'c' keystroke enters GRUB CLI, then we manually boot with autoinstall
  boot_wait = "5s"
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz --- autoinstall ds='nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/'<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]

  # Serve autoinstall config via Packer's built-in HTTP server
  http_directory = "platforms/x86_64/http"

  # SSH for provisioning (after Ubuntu finishes installing)
  ssh_username = "cubeos"
  ssh_password = "cubeos"
  ssh_timeout  = "30m"
  ssh_port     = 22

  shutdown_command = "echo 'cubeos' | sudo -S shutdown -P now"
}

build {
  sources = ["source.qemu.cubeos-x86"]

  # =========================================================================
  # Phase 1: x86 networking (no hostapd, no wlan0 — wired Ethernet only)
  # =========================================================================
  provisioner "shell" {
    execute_command = "echo 'cubeos' | sudo -S bash -euo pipefail '{{ .Path }}'"
    script          = "platforms/x86_64/scripts/02-networking.sh"
  }

  # =========================================================================
  # Phase 2: CubeOS structure + coreapps
  # =========================================================================
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
    execute_command  = "echo 'cubeos' | sudo -S bash -euo pipefail '{{ .Path }}'"
    script           = "shared/scripts/04-cubeos.sh"
    environment_vars = [
      "CUBEOS_VERSION=${var.version}",
      "CUBEOS_VARIANT=${var.variant}",
    ]
  }

  # =========================================================================
  # Phase 3: Docker preload, Pi-hole seed, firstboot service, post-install,
  #           cleanup — combined into one provisioner for efficiency
  # =========================================================================
  provisioner "shell" {
    execute_command  = "echo 'cubeos' | sudo -S bash -euo pipefail '{{ .Path }}'"
    environment_vars = [
      "CUBEOS_VARIANT=${var.variant}",
    ]
    scripts = [
      "shared/scripts/05-docker-preload.sh",
      "shared/scripts/08-pihole-seed.sh",
      "shared/scripts/06-firstboot-service.sh",
      "platforms/x86_64/scripts/09-post-install.sh",
      "shared/scripts/07-cleanup.sh",
    ]
  }
}
