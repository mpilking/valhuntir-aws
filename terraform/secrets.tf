###############################################################################
# Generated secrets — never hardcoded, fetched by instances via IAM role
###############################################################################

resource "random_password" "examiner" {
  length  = 24
  special = true
  # XRDP/PAM-friendly special set
  override_special = "!@#%^*-_=+"
}

# Gateway bearer token in sift-gateway's native format (token_gen.py):
# "vhir_gw_" + 24 hex chars (96 bits). firstboot installs it into gateway.yaml
# and refuses to start the gateway if it is missing or malformed.
resource "random_id" "gateway_token" {
  byte_length = 12
}

resource "random_password" "opensearch_admin" {
  length           = 24
  special          = true
  override_special = "!@#%^*-_=+"
}

# remnux-mcp accepts a fixed token (MCP_TOKEN / --http-token), so we can make it
# deterministic: the REMnux service and the SIFT client read the same value.
resource "random_password" "remnux_mcp_token" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "harness" {
  name        = "${var.name_prefix}/harness"
  description = "Valhuntir harness credentials (examiner login, gateway API key, opensearch admin)."
  kms_key_id  = aws_kms_key.main.arn
}

resource "aws_secretsmanager_secret_version" "harness" {
  secret_id = aws_secretsmanager_secret.harness.id
  secret_string = jsonencode({
    examiner_name     = var.examiner_name
    examiner_password = random_password.examiner.result
    gateway_api_key   = "vhir_gw_${random_id.gateway_token.hex}"
    opensearch_admin  = random_password.opensearch_admin.result
    remnux_mcp_token  = random_password.remnux_mcp_token.result
  })
}
