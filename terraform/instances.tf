locals {
  sift_user_data = templatefile("${path.module}/templates/sift-cloud-init.yaml.tftpl", {
    region             = var.region
    secret_arn         = aws_secretsmanager_secret.harness.arn
    examiner_name      = var.examiner_name
    sift_user          = var.sift_user
    evidence_bucket    = aws_s3_bucket.evidence.bucket
    opensearch_url     = local.opensearch_url
    cases_device       = "/dev/xvdf"
    cast_version       = var.cast_version
    sift_mode          = var.sift_mode
    sift_saltstack_ver = var.sift_saltstack_version
    sift_mcp_ref       = var.sift_mcp_ref
    valhuntir_ref      = var.valhuntir_ref
    awscli_version     = var.awscli_version
    pypi_exclude_newer = var.pypi_exclude_newer
    baked              = local.sift_baked
    install_script_b64 = local.sift_install_b64
  })

  key_name = var.ssh_public_key != "" ? aws_key_pair.main[0].key_name : null

  opensearch_url = var.enable_opensearch ? "https://${aws_instance.opensearch[0].private_ip}:9200" : ""

  # Baked-AMI selection. When an AMI override is set we launch it and skip the
  # heavy install at boot (baked=true); otherwise we launch the Ubuntu base and
  # run the shared install script at first boot (baked=false).
  # Ubuntu base for every Ubuntu host: the pinned AMI if set, else newest noble.
  ubuntu_ami = var.ubuntu_ami_id != "" ? var.ubuntu_ami_id : data.aws_ami.ubuntu.id

  sift_ami     = var.sift_ami != "" ? var.sift_ami : local.ubuntu_ami
  sift_baked   = var.sift_ami != ""
  remnux_ami   = var.remnux_ami != "" ? var.remnux_ami : local.ubuntu_ami
  remnux_baked = var.remnux_ami != ""

  # Install scripts single-sourced from packer/scripts, embedded into cloud-init
  # (gzip+base64; EC2 caps user_data at 16 KB) so the from-base path runs the
  # exact same logic Packer bakes.
  sift_install_b64   = base64gzip(file("${path.module}/../packer/scripts/install-sift.sh"))
  remnux_install_b64 = base64gzip(file("${path.module}/../packer/scripts/install-remnux.sh"))
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
      - [ bash, -c, "curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip && unzip -q -o /tmp/awscliv2.zip -d /tmp && /tmp/aws/install" ]
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
  ami                    = local.ubuntu_ami
  instance_type          = var.opensearch_instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.opensearch[0].id]
  key_name               = local.key_name
  iam_instance_profile   = aws_iam_instance_profile.host["opensearch"].name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = var.opensearch_root_gb
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = aws_kms_key.main.arn
  }

  user_data = templatefile("${path.module}/templates/opensearch-cloud-init.yaml.tftpl", {
    region      = var.region
    secret_arn  = aws_secretsmanager_secret.harness.arn
    data_device = "/dev/xvdf"
  })

  depends_on = [aws_route_table_association.private, aws_nat_gateway.main]

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
  vpc_security_group_ids = [aws_security_group.sift.id]
  key_name               = local.key_name
  iam_instance_profile   = aws_iam_instance_profile.host["sift"].name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = var.sift_root_gb
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = aws_kms_key.main.arn
  }

  user_data = local.sift_user_data

  depends_on = [aws_route_table_association.private, aws_nat_gateway.main]

  lifecycle {
    precondition {
      condition     = length(local.sift_user_data) <= 16384
      error_message = "SIFT user_data exceeds EC2's 16 KB limit; shrink install-sift.sh or the cloud-init template."
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
  vpc_security_group_ids = [aws_security_group.remnux[0].id]
  key_name               = local.key_name
  iam_instance_profile   = aws_iam_instance_profile.host["remnux"].name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = var.remnux_root_gb
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = aws_kms_key.main.arn
  }

  user_data = templatefile("${path.module}/templates/remnux-cloud-init.yaml.tftpl", {
    region             = var.region
    secret_arn         = aws_secretsmanager_secret.harness.arn
    cast_version       = var.cast_version
    remnux_mode        = var.remnux_mode
    remnux_user        = var.remnux_user
    baked              = local.remnux_baked
    install_script_b64 = local.remnux_install_b64
  })

  depends_on = [aws_route_table_association.private, aws_nat_gateway.main]

  tags = { Name = "${var.name_prefix}-remnux" }
}

###############################################################################
# Windows — wintools-mcp
###############################################################################

resource "aws_instance" "windows" {
  count                  = var.enable_windows ? 1 : 0
  ami                    = data.aws_ssm_parameter.windows2022[0].value
  instance_type          = var.windows_instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.windows[0].id]
  key_name               = local.key_name
  iam_instance_profile   = aws_iam_instance_profile.host["windows"].name
  get_password_data      = var.ssh_public_key != ""

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
    region        = var.region
    secret_arn    = aws_secretsmanager_secret.harness.arn
    sift_ip       = aws_instance.sift.private_ip
    sift_user     = var.sift_user
    examiner_name = var.examiner_name
  })

  depends_on = [aws_route_table_association.private, aws_nat_gateway.main]

  tags = { Name = "${var.name_prefix}-windows" }
}
