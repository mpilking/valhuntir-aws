locals {
  # Fixed private IPs. Hosts need each other's addresses in their first-boot
  # config (SIFT's Samba share admits only the Windows IP; Windows joins SIFT),
  # and fixed IPs avoid a Terraform dependency cycle between them.
  ip = {
    sift       = cidrhost(var.private_subnet_cidr, 10)
    opensearch = cidrhost(var.private_subnet_cidr, 11)
    remnux     = cidrhost(var.private_subnet_cidr, 12)
    windows    = cidrhost(var.private_subnet_cidr, 13)
  }

  sift_user_data = templatefile("${path.module}/templates/sift-cloud-init.yaml.tftpl", {
    region             = var.region
    secret_arn         = aws_secretsmanager_secret.harness.arn
    examiner_name      = var.examiner_name
    sift_user          = local.sift_user
    evidence_bucket    = aws_s3_bucket.evidence.bucket
    opensearch_url     = var.enable_opensearch ? "https://${local.ip.opensearch}:9200" : ""
    remnux_url         = var.enable_remnux ? "http://${local.ip.remnux}:3000/mcp" : ""
    windows_ip         = var.enable_windows ? local.ip.windows : ""
    join_code_param    = local.join_code_param
    kms_key_arn        = aws_kms_key.main.arn
    cases_device       = "/dev/xvdf"
    sift_mode          = local.sift_mode
    pins               = local.pins
    baked              = local.baked
    install_script_b64 = local.sift_install_b64
  })

  key_name = var.ssh_public_key != "" ? aws_key_pair.main[0].key_name : null

  # Checkpoint deploys launch the baked AMI for each host; checkpoint="latest"
  # launches the base image and runs the shared install script at first boot.
  sift_ami       = local.baked ? local.amis.sift : local.ubuntu_ami
  remnux_ami     = local.baked ? local.amis.remnux : local.ubuntu_ami
  opensearch_ami = local.baked ? local.amis.opensearch : local.ubuntu_ami
  windows_ami    = local.baked ? local.amis.windows : try(data.aws_ssm_parameter.windows2022[0].value, "")

  # Install scripts single-sourced from packer/scripts, embedded into cloud-init
  # for checkpoint=latest, so the from-base path runs the exact logic Packer bakes.
  sift_install_b64       = base64gzip(file("${path.module}/../packer/scripts/install-sift.sh"))
  remnux_install_b64     = base64gzip(file("${path.module}/../packer/scripts/install-remnux.sh"))
  opensearch_install_b64 = base64gzip(file("${path.module}/../packer/scripts/install-opensearch.sh"))
}

###############################################################################
# Bastion — public, the only internet-facing host
###############################################################################

resource "aws_instance" "bastion" {
  ami                    = local.ubuntu_ami
  instance_type          = var.bastion_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  key_name               = local.key_name
  iam_instance_profile   = aws_iam_instance_profile.host["bastion"].name

  # A changed first-boot script must run, and it only runs on a new instance.
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = aws_kms_key.main.arn
  }

  # 'awscli' is not an apt package on Ubuntu 24.04; install AWS CLI v2 bundle.
  user_data = <<-EOT
    #cloud-config
    package_update: true
    packages: [unzip, curl]
    runcmd:
      - [ bash, -c, "curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64${local.pins.awscli == "latest" ? "" : "-${local.pins.awscli}"}.zip -o /tmp/awscliv2.zip && unzip -q -o /tmp/awscliv2.zip -d /tmp && /tmp/aws/install" ]
  EOT

  # Don't boot until egress (IGW route) is wired, or early cloud-init has no net.
  depends_on = [aws_route_table_association.public]

  tags = { Name = "${var.name_prefix}-bastion" }
}

resource "aws_eip" "bastion" {
  instance = aws_instance.bastion.id
  domain   = "vpc"
  tags     = { Name = "${var.name_prefix}-bastion-eip" }
}

###############################################################################
# OpenSearch data store
###############################################################################

resource "aws_instance" "opensearch" {
  count                  = var.enable_opensearch ? 1 : 0
  ami                    = local.opensearch_ami
  instance_type          = var.opensearch_instance_type
  subnet_id              = aws_subnet.private.id
  private_ip             = local.ip.opensearch
  vpc_security_group_ids = [aws_security_group.opensearch[0].id]
  key_name               = local.key_name
  iam_instance_profile   = aws_iam_instance_profile.host["opensearch"].name

  # A changed first-boot script must run, and it only runs on a new instance.
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = var.opensearch_root_gb
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = aws_kms_key.main.arn
  }

  user_data_base64 = base64gzip(templatefile("${path.module}/templates/opensearch-cloud-init.yaml.tftpl", {
    region             = var.region
    secret_arn         = aws_secretsmanager_secret.harness.arn
    pins               = local.pins
    baked              = local.baked
    install_script_b64 = local.opensearch_install_b64
  }))

  depends_on = [aws_route_table_association.private, aws_nat_gateway.main]

  lifecycle {
    precondition {
      condition     = !local.baked || local.amis.opensearch != ""
      error_message = "Checkpoint ${var.checkpoint} has no baked OpenSearch AMI. Set enable_opensearch = false or bake one (checkpoints/bake.sh)."
    }
  }

  tags = { Name = "${var.name_prefix}-opensearch" }
}

resource "aws_ebs_volume" "opensearch_data" {
  count             = var.enable_opensearch ? 1 : 0
  availability_zone = local.az
  size              = var.opensearch_data_gb
  type              = "gp3"
  encrypted         = true
  kms_key_id        = aws_kms_key.main.arn
  tags              = { Name = "${var.name_prefix}-opensearch-data" }
}

resource "aws_volume_attachment" "opensearch_data" {
  count       = var.enable_opensearch ? 1 : 0
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.opensearch_data[0].id
  instance_id = aws_instance.opensearch[0].id
}

###############################################################################
# SIFT workstation — gateway, MCP backends, portal, XRDP, SMB server
###############################################################################

resource "aws_instance" "sift" {
  ami                    = local.sift_ami
  instance_type          = var.sift_instance_type
  subnet_id              = aws_subnet.private.id
  private_ip             = local.ip.sift
  vpc_security_group_ids = [aws_security_group.sift.id]
  key_name               = local.key_name
  iam_instance_profile   = aws_iam_instance_profile.host["sift"].name

  # A changed first-boot script must run, and it only runs on a new instance.
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = var.sift_root_gb
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = aws_kms_key.main.arn
  }

  # gzip: cloud-init detects compressed user data; EC2 caps it at 16 KB.
  user_data_base64 = base64gzip(local.sift_user_data)

  depends_on = [aws_route_table_association.private, aws_nat_gateway.main]

  lifecycle {
    precondition {
      condition     = !local.baked || local.amis.sift != ""
      error_message = "Checkpoint ${var.checkpoint} has no baked SIFT AMI."
    }
    precondition {
      condition     = length(base64gzip(local.sift_user_data)) <= 21844 # 16 KB once base64-decoded
      error_message = "SIFT user_data exceeds EC2's 16 KB limit even gzipped; shrink install-sift.sh or the cloud-init template."
    }
  }

  tags = { Name = "${var.name_prefix}-sift" }
}

resource "aws_ebs_volume" "sift_cases" {
  availability_zone = local.az
  size              = var.sift_cases_gb
  type              = "gp3"
  encrypted         = true
  kms_key_id        = aws_kms_key.main.arn
  tags              = { Name = "${var.name_prefix}-sift-cases" }
}

resource "aws_volume_attachment" "sift_cases" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.sift_cases.id
  instance_id = aws_instance.sift.id
}

###############################################################################
# REMnux
###############################################################################

resource "aws_instance" "remnux" {
  count                  = var.enable_remnux ? 1 : 0
  ami                    = local.remnux_ami
  instance_type          = var.remnux_instance_type
  subnet_id              = aws_subnet.private.id
  private_ip             = local.ip.remnux
  vpc_security_group_ids = [aws_security_group.remnux[0].id]
  key_name               = local.key_name
  iam_instance_profile   = aws_iam_instance_profile.host["remnux"].name

  # A changed first-boot script must run, and it only runs on a new instance.
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = var.remnux_root_gb
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = aws_kms_key.main.arn
  }

  user_data_base64 = base64gzip(templatefile("${path.module}/templates/remnux-cloud-init.yaml.tftpl", {
    region             = var.region
    secret_arn         = aws_secretsmanager_secret.harness.arn
    remnux_mode        = local.remnux_mode
    remnux_user        = local.remnux_user
    pins               = local.pins
    baked              = local.baked
    install_script_b64 = local.remnux_install_b64
  }))

  depends_on = [aws_route_table_association.private, aws_nat_gateway.main]

  lifecycle {
    precondition {
      condition     = !local.baked || local.amis.remnux != ""
      error_message = "Checkpoint ${var.checkpoint} has no baked REMnux AMI. Set enable_remnux = false or bake one (checkpoints/bake.sh)."
    }
  }

  tags = { Name = "${var.name_prefix}-remnux" }
}

###############################################################################
# Windows — wintools-mcp
###############################################################################

resource "aws_instance" "windows" {
  count                  = var.enable_windows ? 1 : 0
  ami                    = local.windows_ami
  instance_type          = var.windows_instance_type
  subnet_id              = aws_subnet.private.id
  private_ip             = local.ip.windows
  vpc_security_group_ids = [aws_security_group.windows[0].id]
  key_name               = local.key_name
  iam_instance_profile   = aws_iam_instance_profile.host["windows"].name
  get_password_data      = var.ssh_public_key != ""

  # A changed first-boot script must run, and it only runs on a new instance.
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = var.windows_root_gb
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = aws_kms_key.main.arn
  }

  user_data = templatefile("${path.module}/templates/windows-userdata.ps1.tftpl", {
    region          = var.region
    sift_ip         = local.ip.sift
    examiner_name   = var.examiner_name
    join_code_param = local.join_code_param
    pins            = local.pins
    baked           = local.baked
  })

  depends_on = [aws_route_table_association.private, aws_nat_gateway.main]

  lifecycle {
    precondition {
      condition     = !local.baked || local.amis.windows != ""
      error_message = "Checkpoint ${var.checkpoint} has no baked Windows AMI. Set enable_windows = false or bake one (checkpoints/bake.sh)."
    }
  }

  tags = { Name = "${var.name_prefix}-windows" }
}
