###############################################################################
# Core
###############################################################################

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for all resource names."
  type        = string
  default     = "valhuntir"
}

variable "examiner_name" {
  description = <<-EOT
    Valhuntir examiner IDENTITY (VHIR_EXAMINER) — used for audit attribution and
    in finding/timeline IDs (e.g. F-analyst-001). This is distinct from the OS
    login account (see sift_user); you log into SIFT as sansforensics but your
    examiner identity is this name.
  EOT
  type        = string
  default     = "analyst"
}

variable "sift_user" {
  description = "(latest only) OS login account on the SIFT host. SANS convention is 'sansforensics'; the SIFT salt-states default to this pillar value."
  type        = string
  default     = "sansforensics"
}

###############################################################################
# Access control
###############################################################################

variable "allowed_admin_cidrs" {
  description = "CIDRs allowed to SSH to the bastion. Set this to your own IP/32. Empty = no SSH ingress (SSM only)."
  type        = list(string)
  default     = []
}

variable "ssh_public_key" {
  description = "SSH public key material (contents of your .pub) used for the EC2 key pair. Leave empty to skip key-pair creation (SSM only)."
  type        = string
  default     = ""
}

###############################################################################
# Network
###############################################################################

variable "vpc_cidr" {
  description = "CIDR for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for the public subnet (bastion + NAT)."
  type        = string
  default     = "10.20.0.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR for the private subnet (forensic hosts)."
  type        = string
  default     = "10.20.10.0/24"
}

variable "availability_zone" {
  description = "AZ to place subnets in. Empty = first AZ in the region."
  type        = string
  default     = ""
}

###############################################################################
# Component toggles
###############################################################################

variable "enable_opensearch" {
  description = "Deploy the dedicated OpenSearch data-store host."
  type        = bool
  default     = true
}

variable "enable_windows" {
  description = "Deploy the Windows wintools-mcp host."
  type        = bool
  default     = true
}

variable "enable_remnux" {
  description = "Deploy the REMnux malware-analysis host."
  type        = bool
  default     = true
}

###############################################################################
# Software checkpoint — see checkpoint.tf and ../checkpoints/README.md
###############################################################################

variable "checkpoint" {
  description = <<-EOT
    Which software to deploy. Required — there is no default, so a deploy never
    silently changes versions.
      "<name>"  launch the baked, tested AMIs in ../checkpoints/<name>.json
      "latest"  build every host from base with the newest upstream versions
                (slow, may fail; used to try upgrades before cutting a checkpoint)
  EOT
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.checkpoint))
    error_message = "checkpoint must be a checkpoint file name (e.g. 2026-07-12) or \"latest\"."
  }
}

###############################################################################
# Install choices for checkpoint="latest" only. A checkpoint records the values
# its AMIs were baked with, and those take precedence.
###############################################################################

variable "sift_mode" {
  description = <<-EOT
    SIFT install mode. Both install identical forensic tooling
    (sift.packages + python3-packages + scripts). 'desktop' additionally
    applies sift.config (examiner dotfiles, aliases, SIFT theme, standard
    folders, foremost.conf, samba config) — it installs NO extra packages,
    so there is no display-manager/XRDP conflict. 'server' skips only that
    config layer. Default 'desktop' for the full workstation experience.
  EOT
  type        = string
  default     = "desktop"
  validation {
    condition     = contains(["server", "desktop"], var.sift_mode)
    error_message = "sift_mode must be 'server' or 'desktop'."
  }
}

variable "remnux_mode" {
  description = "REMnux install mode: 'dedicated', 'addon', or 'cloud'."
  type        = string
  default     = "dedicated"
  validation {
    condition     = contains(["dedicated", "addon", "cloud"], var.remnux_mode)
    error_message = "remnux_mode must be 'dedicated', 'addon', or 'cloud'."
  }
}

variable "remnux_user" {
  description = "Non-root user REMnux/cast installs against. REMnux convention is 'remnux'; created in cloud-init before the installer runs."
  type        = string
  default     = "remnux"
}

###############################################################################
# Instance sizing
###############################################################################

variable "bastion_instance_type" {
  type    = string
  default = "t3.small"
}

variable "sift_instance_type" {
  type    = string
  default = "m6i.2xlarge" # 8 vCPU / 32 GB — room for Volatility 3
}

variable "opensearch_instance_type" {
  type    = string
  default = "r6i.large" # 2 vCPU / 16 GB
}

variable "windows_instance_type" {
  type    = string
  default = "m6i.xlarge" # 4 vCPU / 16 GB
}

variable "remnux_instance_type" {
  type    = string
  default = "m6i.large" # 2 vCPU / 8 GB
}

###############################################################################
# Storage (GiB)
###############################################################################

variable "sift_root_gb" {
  type    = number
  default = 100
}

variable "sift_cases_gb" {
  description = "Dedicated /cases volume for evidence + extractions."
  type        = number
  default     = 500
}

variable "opensearch_root_gb" {
  type    = number
  default = 40
}

variable "opensearch_data_gb" {
  type    = number
  default = 200
}

variable "windows_root_gb" {
  type    = number
  default = 100
}

variable "remnux_root_gb" {
  type    = number
  default = 120
}

###############################################################################
# Evidence bucket / chain of custody
###############################################################################

variable "object_lock_mode" {
  description = "S3 Object Lock mode for evidence: GOVERNANCE (privileged override) or COMPLIANCE (immutable)."
  type        = string
  default     = "GOVERNANCE"
  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.object_lock_mode)
    error_message = "object_lock_mode must be GOVERNANCE or COMPLIANCE."
  }
}

variable "object_lock_retention_days" {
  description = "Default retention (days) applied to evidence objects."
  type        = number
  default     = 365
}
