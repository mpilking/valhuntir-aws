output "bastion_public_ip" {
  description = "Public IP of the bastion (the only internet-facing host)."
  value       = aws_eip.bastion.public_ip
}

output "sift_private_ip" {
  value = aws_instance.sift.private_ip
}

output "opensearch_private_ip" {
  value = var.enable_opensearch ? aws_instance.opensearch[0].private_ip : null
}

output "windows_private_ip" {
  value = var.enable_windows ? aws_instance.windows[0].private_ip : null
}

output "remnux_private_ip" {
  value = var.enable_remnux ? aws_instance.remnux[0].private_ip : null
}

output "evidence_bucket" {
  description = "WORM evidence bucket. Upload to the incoming/ prefix."
  value       = aws_s3_bucket.evidence.bucket
}

output "harness_secret_arn" {
  description = "Secrets Manager ARN holding examiner password, gateway API key, opensearch admin."
  value       = aws_secretsmanager_secret.harness.arn
}

output "get_credentials_cmd" {
  description = "Reveal the generated credentials."
  value       = "aws secretsmanager get-secret-value --region ${var.region} --secret-id ${aws_secretsmanager_secret.harness.arn} --query SecretString --output text | jq ."
}

# Convenience: SSH tunnel that forwards XRDP (SIFT), the gateway/Portal, and
# Windows RDP through the bastion to your localhost.
output "ssh_tunnel_cmd" {
  description = "Port-forward SIFT XRDP:3389, gateway/Portal:4508, Windows RDP:13389 via the bastion."
  value = join(" ", compact([
    "ssh -N",
    "-L 3389:${aws_instance.sift.private_ip}:3389",
    "-L 4508:${aws_instance.sift.private_ip}:4508",
    var.enable_windows ? "-L 13389:${aws_instance.windows[0].private_ip}:3389" : "",
    "ubuntu@${aws_eip.bastion.public_ip}",
  ]))
}

output "usage_hint" {
  value = <<-EOT
    1. Open the tunnel:   terraform output -raw ssh_tunnel_cmd | bash
    2. XRDP into SIFT:    connect an RDP client to localhost:3389 (user = ${local.sift_user})
    3. Examiner Portal:   https://localhost:4508/portal/  (TLS: per-instance CA at ~/.vhir/tls/ca-cert.pem on SIFT)
    4. Get credentials:   see 'get_credentials_cmd' output
    5. Load evidence:     upload to s3://${aws_s3_bucket.evidence.bucket}/incoming/<case>/,
                          then on SIFT run:  pull-evidence <case>
    SSM fallback (no bastion):
       aws ssm start-session --target <instance-id>
  EOT
}
