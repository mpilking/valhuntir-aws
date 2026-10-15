terraform {
  # 1.11+ for native S3 state locking (use_lockfile). Drop backend.tf to use an
  # older CLI with local state.
  required_version = ">= 1.11.0"

  # Exact provider pins = what `init` resolved for the 2026-07-12 validation.
  # Upgrades are deliberate and need their own test pass.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.100.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "4.3.0"
    }
  }
}
