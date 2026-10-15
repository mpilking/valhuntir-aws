# SIFT workstation AMI: SANS SIFT via cast + the Valhuntir sift-mcp stack.
# Variables: variables.pkr.hcl. Run via checkpoints/bake.sh.

source "amazon-ebs" "sift" {
  region          = var.region
  instance_type   = "m6i.2xlarge" # RAM/CPU for the SIFT salt run + RAG index build
  source_ami      = var.ubuntu_ami
  subnet_id       = var.subnet_id
  ssh_username    = "ubuntu"
  ami_name        = "valhuntir-sift-${var.checkpoint}-${local.stamp}"
  ami_description = "Valhuntir SIFT (checkpoint ${var.checkpoint}): SIFT ${var.sift_saltstack} + sift-mcp ${substr(var.sift_mcp, 0, 7)}, ${var.sift_mode} mode, secrets scrubbed"

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

  tags = merge(local.common_tags, {
    Component        = "sift"
    BaseAMI          = var.ubuntu_ami
    Cast             = var.cast
    SiftSaltstack    = var.sift_saltstack
    SiftMcp          = var.sift_mcp
    Valhuntir        = var.valhuntir
    OpensearchMcp    = var.opensearch_mcp
    PypiExcludeNewer = var.pypi_exclude_newer
  })
  snapshot_tags = merge(local.common_tags, { Component = "sift" })
  run_tags      = merge(local.common_tags, { Name = "packer-valhuntir-sift" })
}

build {
  name    = "sift"
  sources = ["source.amazon-ebs.sift"]

  provisioner "file" {
    sources     = ["${path.root}/scripts/install-sift.sh", "${path.root}/scripts/scrub-sift.sh"]
    destination = "/tmp/"
  }

  provisioner "shell" {
    execute_command = local.linux_exec
    environment_vars = [
      "SIFT_USER=${var.sift_user}",
      "SIFT_MODE=${var.sift_mode}",
      "CAST_VER=${var.cast}",
      "SIFT_SALTSTACK_VERSION=${var.sift_saltstack}",
      "SIFT_MCP_REF=${var.sift_mcp}",
      "VALHUNTIR_REF=${var.valhuntir}",
      "OPENSEARCH_MCP_REF=${var.opensearch_mcp}",
      "AWSCLI_VERSION=${var.awscli}",
      "PYPI_EXCLUDE_NEWER=${var.pypi_exclude_newer}",
    ]
    inline = ["bash /tmp/install-sift.sh"]
  }

  # Record which cast salt states failed (some are expected on a headless box).
  provisioner "shell" {
    execute_command = local.linux_exec
    script          = "${path.root}/scripts/list-cast-failures.sh"
  }

  # Must be last: removes per-instance secrets, Packer's SSH key, and cloud-init state.
  provisioner "shell" {
    execute_command  = local.linux_exec
    environment_vars = ["SIFT_USER=${var.sift_user}"]
    inline           = ["bash /tmp/scrub-sift.sh", "rm -f /tmp/install-sift.sh /tmp/scrub-sift.sh"]
  }

  post-processor "manifest" {
    output = "manifest-sift.json"
  }
}
