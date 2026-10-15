###############################################################################
# Evidence bucket — WORM chain-of-custody store, reachable only via the VPC
###############################################################################

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "evidence" {
  bucket              = "${var.name_prefix}-evidence-${random_id.bucket_suffix.hex}"
  object_lock_enabled = true

  tags = { Name = "${var.name_prefix}-evidence" }
}

# Versioning is a prerequisite for Object Lock.
resource "aws_s3_bucket_versioning" "evidence" {
  bucket = aws_s3_bucket.evidence.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Default WORM retention for every uploaded object.
resource "aws_s3_bucket_object_lock_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  rule {
    default_retention {
      mode = var.object_lock_mode
      days = var.object_lock_retention_days
    }
  }

  # Object Lock requires versioning to be enabled first.
  depends_on = [aws_s3_bucket_versioning.evidence]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "evidence" {
  bucket                  = aws_s3_bucket.evidence.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Restrict all access to requests arriving through our S3 VPC endpoint, and
# require TLS. Uploads from your workstation should therefore go through the
# VPC (e.g. via the bastion/SSM tunnel or a Direct Connect/VPN), matching the
# "nothing sensitive on the public internet" posture.
data "aws_iam_policy_document" "evidence_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.evidence.arn, "${aws_s3_bucket.evidence.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Evidence CONTENT (object bytes) and uploads may only move through the VPC
  # endpoint — this is the anti-internet-exfiltration control. We deliberately do
  # NOT deny s3:ListBucket here: HeadBucket/ListBucket is what Terraform and admin
  # tooling use to manage the bucket, and denying it to non-VPCE principals makes
  # `HeadBucket` return 403, which Terraform misreads as "bucket deleted" and
  # tries to recreate. Object names are not the sensitive payload; the bytes are,
  # and GetObject stays VPCE-only. Anonymous/public access is already fully
  # blocked by the public-access-block above.
  statement {
    sid    = "ObjectAccessOnlyViaVpcEndpoint"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.evidence.arn}/*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:sourceVpce"
      values   = [aws_vpc_endpoint.s3.id]
    }
    # Keep a break-glass path for the account root principal.
    condition {
      test     = "StringNotLike"
      variable = "aws:PrincipalArn"
      values   = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_s3_bucket_policy" "evidence" {
  bucket = aws_s3_bucket.evidence.id
  policy = data.aws_iam_policy_document.evidence_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.evidence]
}
