packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "= 1.8.1"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "m6i.2xlarge" # RAM/CPU for the SIFT salt run + RAG index build
}

variable "subnet_id" {
  description = "Subnet with outbound internet to build in. us-east-1 in this account has no default VPC, so pass one (e.g. the Terraform public subnet). The builder gets a temporary public IP; SSH is allowed only from the machine running Packer."
  type        = string
}

variable "source_ami" {
  description = "Ubuntu 24.04 base. Must match terraform var.ubuntu_ami_id so baked and from-base installs start identically."
  type        = string
  default     = "ami-0a02a779008fa3b99" # ubuntu-noble-24.04-amd64-server-20260626
}

variable "sift_user" {
  type    = string
  default = "sansforensics"
}

variable "cast_version" {
  type    = string
  default = "v1.0.22"
}

variable "sift_mode" {
  type    = string
  default = "desktop"
}

# Version pins — keep in lockstep with the matching terraform variables.
variable "sift_saltstack_version" {
  type    = string
  default = "v2026.04.21"
}

variable "sift_mcp_ref" {
  type    = string
  default = "c67a860ea70c38dc3c5243193a76f0bcbd6db18f"
}

variable "valhuntir_ref" {
  type    = string
  default = "ce1ae368f425402545414eea50998608f4b887d7"
}

variable "awscli_version" {
  type    = string
  default = "2.35.21"
}

variable "pypi_exclude_newer" {
  type    = string
  default = "2026-07-12T19:00:00Z"
}

variable "ami_name_prefix" {
  type    = string
  default = "valhuntir-sift"
}

locals {
  ami_name = "${var.ami_name_prefix}-${formatdate("YYYYMMDD-hhmmss", timestamp())}"
  # Recorded on the AMI and its snapshot so the image documents what it contains.
  provenance = {
    Project              = "valhuntir"
    Component            = "sift"
    BaseAMI              = var.source_ami
    CastVersion          = var.cast_version
    CastMode             = var.sift_mode
    SiftSaltstackVersion = var.sift_saltstack_version
    SiftMcpRef           = var.sift_mcp_ref
    ValhuntirRef         = var.valhuntir_ref
    AwsCliVersion        = var.awscli_version
    PypiExcludeNewer     = var.pypi_exclude_newer
  }
}

source "amazon-ebs" "sift" {
  region          = var.region
  instance_type   = var.instance_type
  source_ami      = var.source_ami
  subnet_id       = var.subnet_id
  ssh_username    = "ubuntu"
  ami_name        = local.ami_name
  ami_description = "Valhuntir SIFT: SANS SIFT ${var.sift_saltstack_version} via cast + sift-mcp ${substr(var.sift_mcp_ref, 0, 7)}, ${var.sift_mode} mode, secrets scrubbed"

  # Temporary public IP for the build; the temporary security group allows SSH
  # only from this machine's public IP.
  associate_public_ip_address               = true
  temporary_security_group_source_public_ip = true

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 100
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  # The first snapshot of an encrypted 100 GB volume can take well over the
  # default waiter limit (~30 min); wait up to 2 h for the AMI to become available.
  aws_polling {
    delay_seconds = 30
    max_attempts  = 240
  }

  tags          = local.provenance
  snapshot_tags = local.provenance
  run_tags      = merge(local.provenance, { Name = "packer-${var.ami_name_prefix}" })
}

build {
  name    = "valhuntir-sift"
  sources = ["source.amazon-ebs.sift"]

  provisioner "file" {
    sources     = ["${path.root}/scripts/install-sift.sh", "${path.root}/scripts/scrub-sift.sh"]
    destination = "/tmp/"
  }

  # Match cloud-init's environment: `cd /` (Packer's cwd is /home/ubuntu, which
  # uv walks looking for uv.toml and sansforensics cannot read, so venv creation
  # failed) and `sudo env` rather than `sudo -E` so HOME is /root.
  provisioner "shell" {
    execute_command = "cd / && sudo env {{ .Vars }} bash '{{ .Path }}'"
    environment_vars = [
      "SIFT_USER=${var.sift_user}",
      "CAST_VER=${var.cast_version}",
      "SIFT_MODE=${var.sift_mode}",
      "SIFT_SALTSTACK_VERSION=${var.sift_saltstack_version}",
      "SIFT_MCP_REF=${var.sift_mcp_ref}",
      "VALHUNTIR_REF=${var.valhuntir_ref}",
      "AWSCLI_VERSION=${var.awscli_version}",
      "PYPI_EXCLUDE_NEWER=${var.pypi_exclude_newer}",
    ]
    inline = ["bash /tmp/install-sift.sh"]
  }

  # Record which cast salt states failed (some are expected on a headless box).
  provisioner "shell" {
    execute_command = "cd / && sudo env {{ .Vars }} bash '{{ .Path }}'"
    inline = [
      "python3 - <<'PY'",
      "import yaml",
      "def failed(x):",
      "    if isinstance(x, dict):",
      "        if x.get('result') is False: yield x",
      "        for v in x.values(): yield from failed(v)",
      "    elif isinstance(x, list):",
      "        for v in x: yield from failed(v)",
      "for f in failed(yaml.safe_load(open('/var/cache/cast/installer/logs/results.yaml'))):",
      "    print('cast failed state:', f.get('__id__'), '|', str(f.get('comment'))[:120])",
      "PY",
    ]
  }

  # Must be last: removes per-instance secrets, Packer's SSH key, and cloud-init state.
  provisioner "shell" {
    execute_command  = "cd / && sudo env {{ .Vars }} bash '{{ .Path }}'"
    environment_vars = ["SIFT_USER=${var.sift_user}"]
    inline           = ["bash /tmp/scrub-sift.sh", "rm -f /tmp/install-sift.sh /tmp/scrub-sift.sh"]
  }

  post-processor "manifest" {
    output = "manifest-sift.json"
  }
}
