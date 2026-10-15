###############################################################################
# Instance roles. All forensic hosts get: SSM core, KMS decrypt, read of the
# harness secret. SIFT additionally gets evidence-bucket access.
###############################################################################

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# --- Shared policy: SSM, KMS decrypt, read the harness secret ----------------
data "aws_iam_policy_document" "base" {
  statement {
    sid       = "ReadHarnessSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.harness.arn]
  }

  statement {
    sid       = "KmsDecrypt"
    actions   = ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey"]
    resources = [aws_kms_key.main.arn]
  }
}

# --- SIFT-only: evidence bucket read (incoming) + write (exports) ------------
data "aws_iam_policy_document" "sift_evidence" {
  statement {
    sid       = "ListEvidenceBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.evidence.arn]
  }
  statement {
    sid       = "ReadEvidence"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.evidence.arn}/incoming/*"]
  }
  statement {
    sid       = "WriteExports"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.evidence.arn}/exports/*"]
  }
  statement {
    sid       = "EvidenceKms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.main.arn]
  }
}

# -----------------------------------------------------------------------------
# Role factory: one role/profile per host role name.
# -----------------------------------------------------------------------------
locals {
  host_roles = toset(compact([
    "sift",
    var.enable_opensearch ? "opensearch" : "",
    var.enable_windows ? "windows" : "",
    var.enable_remnux ? "remnux" : "",
    "bastion",
  ]))
}

resource "aws_iam_role" "host" {
  for_each           = local.host_roles
  name               = "${var.name_prefix}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy" "base" {
  for_each = local.host_roles
  name     = "base"
  role     = aws_iam_role.host[each.key].id
  policy   = data.aws_iam_policy_document.base.json
}

resource "aws_iam_role_policy" "sift_evidence" {
  name   = "evidence"
  role   = aws_iam_role.host["sift"].id
  policy = data.aws_iam_policy_document.sift_evidence.json
}

# SSM managed-instance core for Session Manager on every host.
resource "aws_iam_role_policy_attachment" "ssm" {
  for_each   = local.host_roles
  role       = aws_iam_role.host[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "host" {
  for_each = local.host_roles
  name     = "${var.name_prefix}-${each.key}"
  role     = aws_iam_role.host[each.key].name
}

###############################################################################
# EC2 key pair (optional — SSM works without it)
###############################################################################

resource "aws_key_pair" "main" {
  count      = var.ssh_public_key != "" ? 1 : 0
  key_name   = "${var.name_prefix}-key"
  public_key = var.ssh_public_key
}
