# Shared configuration for all Valhuntir AMI builds (sift / remnux / opensearch /
# windows .pkr.hcl in this directory form one Packer config).
#
# Don't call Packer directly: checkpoints/bake.sh turns a checkpoint file into
# these variables (the pin names below match the checkpoint's "pins" keys), runs
# the selected builds in parallel, and records the resulting AMI ids back into
# the checkpoint. Every pin is required: an AMI is only ever built from explicit
# versions.

packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "= 1.8.1"
    }
  }
}

variable "checkpoint" {
  description = "Checkpoint name; tagged on every AMI."
  type        = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "subnet_id" {
  description = "Public subnet with internet access (packer/build-vpc). Builders get a temporary public IP; the temporary security group admits SSH/WinRM only from this machine's IP."
  type        = string
}

# --- Build settings (from the checkpoint's "build" block) ---------------------
variable "sift_user" { type = string }
variable "sift_mode" { type = string }
variable "remnux_user" { type = string }
variable "remnux_mode" { type = string }

# --- Pins (from the checkpoint's "pins" block) ----------------------------------
variable "ubuntu_ami" { type = string }
variable "windows_base_ami" { type = string }
variable "awscli" { type = string }
variable "cast" { type = string }
variable "sift_saltstack" { type = string }
variable "sift_mcp" { type = string }
variable "valhuntir" { type = string }
variable "opensearch_mcp" { type = string }
variable "pypi_exclude_newer" { type = string }
variable "remnux_saltstack" { type = string }
variable "remnux_mcp_server" { type = string }
variable "nodejs" { type = string }
variable "docker" { type = string }
variable "wintools_mcp" { type = string }
variable "choco_git" { type = string }
variable "choco_python312" { type = string }

locals {
  stamp = formatdate("YYYYMMDD-hhmmss", timestamp())

  # Shared provenance tags; each build adds its Component and relevant pins.
  common_tags = {
    Project    = "valhuntir"
    Checkpoint = var.checkpoint
  }

  # Packer runs provisioners from the SSH user's home (/home/ubuntu), which the
  # install scripts' tools then scan for config (uv read /home/ubuntu/uv.toml and
  # failed). Match cloud-init instead: cwd /, clean root environment.
  linux_exec = "cd / && sudo env {{ .Vars }} bash '{{ .Path }}'"
}
