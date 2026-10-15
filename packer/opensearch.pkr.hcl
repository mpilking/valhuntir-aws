# OpenSearch host AMI: Docker + upstream's opensearch-mcp deployment, image
# pre-pulled. The cluster itself is initialised at first boot (password, data
# volume). Variables: variables.pkr.hcl. Run via checkpoints/bake.sh.

source "amazon-ebs" "opensearch" {
  region          = var.region
  instance_type   = "t3.large"
  source_ami      = var.ubuntu_ami
  subnet_id       = var.subnet_id
  ssh_username    = "ubuntu"
  ami_name        = "valhuntir-opensearch-${var.checkpoint}-${local.stamp}"
  ami_description = "Valhuntir OpenSearch host (checkpoint ${var.checkpoint}): docker ${var.docker} + opensearch-mcp ${substr(var.opensearch_mcp, 0, 7)} compose"

  associate_public_ip_address               = true
  temporary_security_group_source_public_ip = true

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 40
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  aws_polling {
    delay_seconds = 30
    max_attempts  = 240
  }

  tags = merge(local.common_tags, {
    Component     = "opensearch"
    BaseAMI       = var.ubuntu_ami
    Docker        = var.docker
    OpensearchMcp = var.opensearch_mcp
  })
  snapshot_tags = merge(local.common_tags, { Component = "opensearch" })
  run_tags      = merge(local.common_tags, { Name = "packer-valhuntir-opensearch" })
}

build {
  name    = "opensearch"
  sources = ["source.amazon-ebs.opensearch"]

  provisioner "file" {
    sources     = ["${path.root}/scripts/install-opensearch.sh", "${path.root}/scripts/scrub-linux.sh"]
    destination = "/tmp/"
  }

  provisioner "shell" {
    execute_command = local.linux_exec
    environment_vars = [
      "OPENSEARCH_MCP_REF=${var.opensearch_mcp}",
      "DOCKER_VERSION=${var.docker}",
      "AWSCLI_VERSION=${var.awscli}",
    ]
    inline = ["bash /tmp/install-opensearch.sh"]
  }

  provisioner "shell" {
    execute_command = local.linux_exec
    inline          = ["bash /tmp/scrub-linux.sh", "rm -f /tmp/install-opensearch.sh /tmp/scrub-linux.sh"]
  }

  post-processor "manifest" {
    output = "manifest-opensearch.json"
  }
}
