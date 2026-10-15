# Remote state on S3 with native lockfile locking (no DynamoDB).
#
# Config is supplied at init time so bucket names stay out of version control:
#   terraform init -backend-config=backend.hcl
#
# Create the bucket first with ../bootstrap, then copy its `backend_hcl` output
# into backend.hcl. To keep using local state instead, delete this file.
terraform {
  backend "s3" {}
}
