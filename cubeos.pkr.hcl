# CubeOS Packer Configuration
# Builds custom Ubuntu 24.04 ARM64 image for Raspberry Pi 5
# with Docker and all CubeOS services pre-installed

packer {
  required_plugins {
    arm = {
      version = ">= 1.0.0"
      source  = "github.com/mkaczanowski/packer-builder-arm"
    }
  }
}

# Variables - can be overridden via command line or CI
variable "ubuntu_image_url" {
  type    = string
  default = "https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.1-preinstalled-server-arm64+raspi.img.xz"
}

variable "image_size" {
  type    = string
  default = "16G"  # Final image size (before shrinking)
}

variable "cubeos_version" {
  type    = string
  default = "0.1.0"
}

variable "hostname" {
  type    = string
  default = "cubeos"
}

source "arm" "cubeos" {
  file_urls             = [var.ubuntu_image_url]
  file_checksum_type    = "none"  # Skip checksum for now, add later
  file_target_extension = "xz"
  file_unarchive_cmd    = ["xz", "-d", "$ARCHIVE_PATH"]
  
  image_build_method    = "resize"
  image_size            = var.image_size
  image_type            = "dos"
  image_partitions {
    name         = "boot"
    type         = "c"
    start_sector = 2048
    filesystem   = "fat"
    size         = "256M"
    mountpoint   = "/boot/firmware"
  }
  image_partitions {
    name         = "root"
    type         = "83"
    start_sector = 526336
    filesystem   = "ext4"
    size         = "0"  # Use remaining space
    mountpoint   = "/"
  }
  
  image_chroot_env = [
    "PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
    "DEBIAN_FRONTEND=noninteractive"
  ]
  
  qemu_binary_source_path      = "/usr/bin/qemu-aarch64-static"
  qemu_binary_destination_path = "/usr/bin/qemu-aarch64-static"
}

build {
  sources = ["source.arm.cubeos"]

  # Set hostname
  provisioner "shell" {
    inline = [
      "echo '${var.hostname}' > /etc/hostname",
      "sed -i 's/127.0.1.1.*/127.0.1.1\\t${var.hostname}/' /etc/hosts"
    ]
  }

  # Update system and install prerequisites
  provisioner "shell" {
    inline = [
      "apt-get update",
      "apt-get upgrade -y",
      "apt-get install -y ca-certificates curl gnupg lsb-release git jq"
    ]
  }

  # Install Docker
  provisioner "shell" {
    inline = [
      "install -m 0755 -d /etc/apt/keyrings",
      "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg",
      "chmod a+r /etc/apt/keyrings/docker.gpg",
      "echo \"deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable\" > /etc/apt/sources.list.d/docker.list",
      "apt-get update",
      "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin",
      "systemctl enable docker"
    ]
  }

  # Create CubeOS directory structure
  provisioner "shell" {
    inline = [
      "mkdir -p /cubeos/{api,dashboard,scripts,coreapps,config,data,backups,certs,apps}",
      "mkdir -p /cubeos/coreapps/{pihole,npm,dockge,homarr,dozzle,backup,diagnostics,reset,usb-monitor,terminal,terminal-ro,watchdog,nettools,gpio,orchestrator}",
      "for dir in /cubeos/coreapps/*/; do mkdir -p \"$dir/appconfig\" \"$dir/appdata\"; done"
    ]
  }

  # Copy CubeOS configuration files
  provisioner "file" {
    source      = "files/coreapps/"
    destination = "/cubeos/coreapps/"
  }

  # Copy CubeOS scripts
  provisioner "file" {
    source      = "files/scripts/"
    destination = "/cubeos/scripts/"
  }

  # Make scripts executable
  provisioner "shell" {
    inline = [
      "chmod +x /cubeos/scripts/*.sh",
      "chmod +x /cubeos/coreapps/*.sh 2>/dev/null || true"
    ]
  }

  # Create cubeos-network
  provisioner "shell" {
    inline = [
      "echo '[Unit]' > /etc/systemd/system/cubeos-network.service",
      "echo 'Description=Create CubeOS Docker Network' >> /etc/systemd/system/cubeos-network.service",
      "echo 'After=docker.service' >> /etc/systemd/system/cubeos-network.service",
      "echo 'Requires=docker.service' >> /etc/systemd/system/cubeos-network.service",
      "echo '' >> /etc/systemd/system/cubeos-network.service",
      "echo '[Service]' >> /etc/systemd/system/cubeos-network.service",
      "echo 'Type=oneshot' >> /etc/systemd/system/cubeos-network.service",
      "echo 'ExecStart=/usr/bin/docker network create cubeos-network || true' >> /etc/systemd/system/cubeos-network.service",
      "echo 'RemainAfterExit=yes' >> /etc/systemd/system/cubeos-network.service",
      "echo '' >> /etc/systemd/system/cubeos-network.service",
      "echo '[Install]' >> /etc/systemd/system/cubeos-network.service",
      "echo 'WantedBy=multi-user.target' >> /etc/systemd/system/cubeos-network.service",
      "systemctl enable cubeos-network.service"
    ]
  }

  # Pre-pull Docker images (saved as tarballs, loaded on first boot)
  # This runs OUTSIDE chroot - we'll use a different approach
  # Instead, create a first-boot service to pull images
  provisioner "shell" {
    inline = [
      "cat > /etc/systemd/system/cubeos-first-boot.service << 'EOF'",
      "[Unit]",
      "Description=CubeOS First Boot Setup",
      "After=docker.service network-online.target",
      "Wants=network-online.target",
      "ConditionPathExists=!/var/lib/cubeos/.first-boot-done",
      "",
      "[Service]",
      "Type=oneshot",
      "ExecStart=/cubeos/scripts/first-boot.sh",
      "ExecStartPost=/usr/bin/touch /var/lib/cubeos/.first-boot-done",
      "RemainAfterExit=yes",
      "TimeoutStartSec=600",
      "",
      "[Install]",
      "WantedBy=multi-user.target",
      "EOF",
      "systemctl enable cubeos-first-boot.service",
      "mkdir -p /var/lib/cubeos"
    ]
  }

  # Create first-boot script
  provisioner "shell" {
    inline = [
      "cat > /cubeos/scripts/first-boot.sh << 'SCRIPT'",
      "#!/bin/bash",
      "set -e",
      "echo 'CubeOS First Boot - Pulling Docker images...'",
      "",
      "# Core app images",
      "IMAGES=(", 
      "  'pihole/pihole:latest'",
      "  'jc21/nginx-proxy-manager:latest'",
      "  'louislam/dockge:1'",
      "  'ghcr.io/gethomepage/homepage:latest'",
      "  'amir20/dozzle:latest'",
      "  'wettyoss/wetty:latest'",
      "  'nicolaka/netshoot:latest'",
      ")",
      "",
      "for img in \"${IMAGES[@]}\"; do",
      "  echo \"Pulling $img...\"",
      "  docker pull \"$img\" || echo \"Warning: Failed to pull $img\"",
      "done",
      "",
      "echo 'CubeOS First Boot Complete!'",
      "SCRIPT",
      "chmod +x /cubeos/scripts/first-boot.sh"
    ]
  }

  # Create CubeOS version file
  provisioner "shell" {
    inline = [
      "echo 'CUBEOS_VERSION=${var.cubeos_version}' > /etc/cubeos-release",
      "echo 'BUILD_DATE=${timestamp()}' >> /etc/cubeos-release"
    ]
  }

  # Cleanup
  provisioner "shell" {
    inline = [
      "apt-get clean",
      "rm -rf /var/lib/apt/lists/*",
      "rm -rf /tmp/*",
      "rm -rf /var/tmp/*",
      "truncate -s 0 /var/log/*.log 2>/dev/null || true"
    ]
  }
}
