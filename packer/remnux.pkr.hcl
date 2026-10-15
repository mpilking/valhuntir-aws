# REMnux AMI: REMnux via cast + the remnux-mcp HTTP server.
# Variables: variables.pkr.hcl. Run via checkpoints/bake.sh.

source "amazon-ebs" "remnux" {
  region          = var.region
  instance_type   = "m6i.large"
  source_ami      = var.ubuntu_ami
  subnet_id       = var.subnet_id
  ssh_username    = "ubuntu"
  ami_name        = "valhuntir-remnux-${var.checkpoint}-${local.stamp}"
  ami_description = "Valhuntir REMnux (checkpoint ${var.checkpoint}): REMnux ${var.remnux_saltstack} + remnux-mcp ${var.remnux_mcp_server}, ${var.remnux_mode} mode"

  associate_public_ip_address               = true
  temporary_security_group_source_public_ip = true

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 120
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  aws_polling {
    delay_seconds = 30
    max_attempts  = 240
  }

  tags = merge(local.common_tags, {
    Component       = "remnux"
    BaseAMI         = var.ubuntu_ami
    Cast            = var.cast
    RemnuxSaltstack = var.remnux_saltstack
    RemnuxMcpServer = var.remnux_mcp_server
    NodeJs          = var.nodejs
  })
  snapshot_tags = merge(local.common_tags, { Component = "remnux" })
  run_tags      = merge(local.common_tags, { Name = "packer-valhuntir-remnux" })
}

build {
  name    = "remnux"
  sources = ["source.amazon-ebs.remnux"]

  provisioner "file" {
    sources     = ["${path.root}/scripts/install-remnux.sh", "${path.root}/scripts/scrub-linux.sh"]
    destination = "/tmp/"
  }

  provisioner "shell" {
    execute_command = local.linux_exec
    environment_vars = [
      "REMNUX_USER=${var.remnux_user}",
      "REMNUX_MODE=${var.remnux_mode}",
      "CAST_VER=${var.cast}",
      "REMNUX_SALTSTACK_VERSION=${var.remnux_saltstack}",
      "NODEJS_VERSION=${var.nodejs}",
      "REMNUX_MCP_VERSION=${var.remnux_mcp_server}",
      "AWSCLI_VERSION=${var.awscli}",
    ]
    inline = ["bash /tmp/install-remnux.sh"]
  }

  provisioner "shell" {
    execute_command = local.linux_exec
    script          = "${path.root}/scripts/list-cast-failures.sh"
  }

  provisioner "shell" {
    execute_command = local.linux_exec
    inline          = ["bash /tmp/scrub-linux.sh", "rm -f /tmp/install-remnux.sh /tmp/scrub-linux.sh"]
  }

  post-processor "manifest" {
    output = "manifest-remnux.json"
  }
}
