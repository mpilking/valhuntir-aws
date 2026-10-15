provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "valhuntir"
      ManagedBy = "terraform"
      Component = "dfir-harness"
    }
  }
}
