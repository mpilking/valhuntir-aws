data "aws_caller_identity" "current" {}

# Single project KMS key used for EBS volumes, the evidence bucket, and secrets.
resource "aws_kms_key" "main" {
  description             = "${var.name_prefix} DFIR harness (EBS, evidence S3, secrets)"
  deletion_window_in_days = 14
  enable_key_rotation     = true

  tags = { Name = "${var.name_prefix}-kms" }
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.name_prefix}"
  target_key_id = aws_kms_key.main.key_id
}
