packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3.0"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "m6i.large"
}

variable "subnet_id" {
  description = "Subnet to build in. Empty = default VPC. Needs outbound internet."
  type        = string
  default     = ""
}

variable "remnux_user" {
  type    = string
  default = "remnux"
}

variable "cast_version" {
  type    = string
  default = "v1.0.22"
}

variable "remnux_mode" {
  type    = string
  default = "dedicated"
}

variable "ami_name_prefix" {
  type    = string
  default = "valhuntir-remnux"
}

locals {
  ami_name = "${var.ami_name_prefix}-${formatdate("YYYYMMDD-hhmmss", timestamp())}"
}

source "amazon-ebs" "remnux" {
  region          = var.region
  instance_type   = var.instance_type
  subnet_id       = var.subnet_id != "" ? var.subnet_id : null
  ssh_username    = "ubuntu"
  ami_name        = local.ami_name
  ami_description = "Valhuntir REMnux (REMnux via cast + remnux-mcp), baked ${var.remnux_mode} mode"

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["099720109477"]
    most_recent = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 120
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  tags = {
    Project   = "valhuntir"
    Component = "remnux"
    BaseAMI   = "{{ .SourceAMI }}"
    CastMode  = var.remnux_mode
  }
}

build {
  name    = "valhuntir-remnux"
  sources = ["source.amazon-ebs.remnux"]

  provisioner "file" {
    source      = "${path.root}/scripts/install-remnux.sh"
    destination = "/tmp/install-remnux.sh"
  }

  provisioner "shell" {
    execute_command = "sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "REMNUX_USER=${var.remnux_user}",
      "CAST_VER=${var.cast_version}",
      "REMNUX_MODE=${var.remnux_mode}",
    ]
    inline = [
      "chmod +x /tmp/install-remnux.sh",
      "REMNUX_USER=$REMNUX_USER CAST_VER=$CAST_VER REMNUX_MODE=$REMNUX_MODE /tmp/install-remnux.sh",
      "cloud-init clean --logs || true",
      "rm -f /tmp/install-remnux.sh",
    ]
  }

  post-processor "manifest" {
    output = "manifest-remnux.json"
  }
}
