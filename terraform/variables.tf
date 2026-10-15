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
  description = "OS login account on the SIFT host. SANS convention is 'sansforensics'; the SIFT salt-states default to this pillar value."
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
# SIFT / REMnux provisioning via cast (github.com/ekristen/cast)
###############################################################################

variable "cast_version" {
  description = "cast release tag used to install SIFT/REMnux salt-states. See github.com/ekristen/cast/releases."
  type        = string
  default     = "v1.0.22"
}

###############################################################################
# Version pins — defaults are the versions validated end-to-end on 2026-07-12.
# Bumping any of these is a deliberate upgrade that needs its own test pass.
###############################################################################

variable "sift_saltstack_version" {
  description = "teamdfir/sift-saltstack release installed by `cast install sift@<tag>`."
  type        = string
  default     = "v2026.04.21"
}

variable "sift_mcp_ref" {
  description = "AppliedIR/sift-mcp commit installed on SIFT."
  type        = string
  default     = "c67a860ea70c38dc3c5243193a76f0bcbd6db18f"
}

variable "valhuntir_ref" {
  description = "AppliedIR/Valhuntir (vhir CLI) commit installed on SIFT."
  type        = string
  default     = "ce1ae368f425402545414eea50998608f4b887d7"
}

variable "awscli_version" {
  description = "AWS CLI v2 bundle version installed on SIFT."
  type        = string
  default     = "2.35.21"
}

variable "pypi_exclude_newer" {
  description = "Resolve every Python dependency setup-sift.sh installs as of this UTC timestamp (uv --exclude-newer). Required: sift-mcp's deps are open-ended and mcp 2.x breaks the pinned code."
  type        = string
  default     = "2026-07-12T19:00:00Z"
}

variable "ubuntu_ami_id" {
  description = "Pin the Ubuntu 24.04 base AMI for all Ubuntu hosts (us-east-1). Empty = newest Canonical noble AMI (floats)."
  type        = string
  default     = "ami-0a02a779008fa3b99" # ubuntu-noble-24.04-amd64-server-20260626 (validated 2026-07-12)
}

variable "sift_ami" {
  description = "Pre-baked SIFT AMI (from packer/sift.pkr.hcl). Empty = build from the Ubuntu 24.04 base at first boot (slow)."
  type        = string
  default     = ""
}

variable "remnux_ami" {
  description = "Pre-baked REMnux AMI (from packer/remnux.pkr.hcl). Empty = build from the Ubuntu 24.04 base at first boot (slow)."
  type        = string
  default     = ""
}

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
