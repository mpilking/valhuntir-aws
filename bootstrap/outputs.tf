output "state_bucket" {
  description = "Name of the Terraform remote-state bucket."
  value       = aws_s3_bucket.state.bucket
}

# Ready-to-use backend config for the main config. Write it to
# ../terraform/backend.hcl, then run: terraform init -backend-config=backend.hcl
output "backend_hcl" {
  description = "Copy into terraform/backend.hcl"
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.bucket}"
    key          = "valhuntir/terraform.tfstate"
    region       = "${var.region}"
    encrypt      = true
    use_lockfile = true
  EOT
}
