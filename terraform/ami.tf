###############################################################################
# AMIs
###############################################################################

# Base images are only looked up for checkpoint="latest"; a checkpoint pins them
# (see checkpoint.tf).
#
# Ubuntu 24.04 LTS (Noble) — base for bastion, SIFT, OpenSearch, REMnux.
# 24.04 is required by the cast salt-states for both SIFT and REMnux.
data "aws_ami" "ubuntu" {
  count       = local.is_latest ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Windows Server 2022 Base — resolved from the AWS-published SSM parameter.
data "aws_ssm_parameter" "windows2022" {
  count = var.enable_windows && local.is_latest ? 1 : 0
  name  = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}
