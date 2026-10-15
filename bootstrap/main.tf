# Bootstrap: the S3 bucket that holds the main config's remote state.
#
# This module uses LOCAL state (it can't store its own state in the bucket it
# creates). Run it once, then point terraform/ at the bucket via backend.hcl.
#
#   cd bootstrap
#   terraform init && terraform apply
#   terraform output backend_hcl   # copy into ../terraform/backend.hcl
#
# State locking uses S3's native lockfile (Terraform >= 1.11, `use_lockfile`),
# so there is no DynamoDB table to manage.

locals {
  bucket = var.name_suffix != "" ? "${var.state_bucket_name}-${var.name_suffix}" : var.state_bucket_name
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket

  # State is precious — guard against accidental `terraform destroy`.
  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = local.bucket }
}

# Versioning: required for state history and for native lockfile safety.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Require TLS for all access.
data "aws_iam_policy_document" "state" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket     = aws_s3_bucket.state.id
  policy     = data.aws_iam_policy_document.state.json
  depends_on = [aws_s3_bucket_public_access_block.state]
}
