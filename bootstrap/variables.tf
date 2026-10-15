variable "region" {
  description = "AWS region for the Terraform state bucket. Keep it the same as the deployment region."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Globally-unique name for the Terraform remote-state bucket."
  type        = string
  default     = "valhuntir-tfstate"
}

variable "name_suffix" {
  description = "Optional suffix to make the bucket name unique (e.g. your account id or org). Appended as -<suffix>."
  type        = string
  default     = ""
}
