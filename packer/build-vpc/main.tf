###############################################################################
# Packer build network — one-time, free while idle.
#
# us-east-1 has no default VPC, and baking should not depend on a deployed
# stack, so checkpoints/bake.sh builds in this small public subnet. Builders get
# a temporary public IP; Packer's temporary security group admits SSH/WinRM only
# from the machine running Packer. Nothing here has an hourly cost (no NAT).
#
#   terraform init && terraform apply     # once per account/region
###############################################################################

terraform {
  required_version = ">= 1.11.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.100.0"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "valhuntir", Component = "packer-build" }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "build" {
  cidr_block           = "10.250.0.0/24"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "valhuntir-packer-build" }
}

resource "aws_internet_gateway" "build" {
  vpc_id = aws_vpc.build.id
  tags   = { Name = "valhuntir-packer-build" }
}

resource "aws_subnet" "build" {
  vpc_id                  = aws_vpc.build.id
  cidr_block              = aws_vpc.build.cidr_block
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "valhuntir-packer-build" }
}

resource "aws_route_table" "build" {
  vpc_id = aws_vpc.build.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.build.id
  }
  tags = { Name = "valhuntir-packer-build" }
}

resource "aws_route_table_association" "build" {
  subnet_id      = aws_subnet.build.id
  route_table_id = aws_route_table.build.id
}

output "subnet_id" {
  value = aws_subnet.build.id
}
