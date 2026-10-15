# Windows wintools-mcp host AMI: pinned Git/Python, wintools-mcp source,
# forensic-knowledge and Python environment staged; generalised with sysprep.
# setup-windows.ps1 itself (token, TLS cert, join, scheduled task) runs at first
# boot. Variables: variables.pkr.hcl. Run via checkpoints/bake.sh.

source "amazon-ebs" "windows" {
  region          = var.region
  instance_type   = "m6i.large"
  source_ami      = var.windows_base_ami
  subnet_id       = var.subnet_id
  ami_name        = "valhuntir-windows-${var.checkpoint}-${local.stamp}"
  ami_description = "Valhuntir Windows (checkpoint ${var.checkpoint}): wintools-mcp ${substr(var.wintools_mcp, 0, 7)} staged, sysprepped"

  associate_public_ip_address               = true
  temporary_security_group_source_public_ip = true

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = "30m"
  user_data_file = "${path.root}/scripts/winrm-bootstrap.ps1"

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 100
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  aws_polling {
    delay_seconds = 30
    max_attempts  = 240
  }

  tags = merge(local.common_tags, {
    Component        = "windows"
    BaseAMI          = var.windows_base_ami
    WintoolsMcp      = var.wintools_mcp
    ChocoGit         = var.choco_git
    ChocoPython312   = var.choco_python312
    PypiExcludeNewer = var.pypi_exclude_newer
  })
  snapshot_tags = merge(local.common_tags, { Component = "windows" })
  run_tags      = merge(local.common_tags, { Name = "packer-valhuntir-windows" })
}

build {
  name    = "windows"
  sources = ["source.amazon-ebs.windows"]

  provisioner "powershell" {
    environment_vars = [
      "WINTOOLS_MCP_REF=${var.wintools_mcp}",
      "SIFT_MCP_REF=${var.sift_mcp}",
      "CHOCO_GIT=${var.choco_git}",
      "CHOCO_PYTHON312=${var.choco_python312}",
      "PYPI_EXCLUDE_NEWER=${var.pypi_exclude_newer}",
    ]
    script = "${path.root}/scripts/install-windows.ps1"
  }

  # Must be last: generalise. Each launch gets a new SID, computer name and
  # Administrator password, and EC2Launch v2 runs that launch's user data.
  provisioner "powershell" {
    inline = [
      "Remove-Item -Recurse -Force C:\\ProgramData\\valhuntir\\firstboot.log -ErrorAction SilentlyContinue",
      "& 'C:/Program Files/Amazon/EC2Launch/ec2launch.exe' reset --block",
      "& 'C:/Program Files/Amazon/EC2Launch/ec2launch.exe' sysprep --shutdown --block",
    ]
  }

  post-processor "manifest" {
    output = "manifest-windows.json"
  }
}
