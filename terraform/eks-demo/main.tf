terraform {
  required_version = ">= 1.9, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # cflt_keep_until is computed at apply time — cannot be a variable default
  mandatory_tags = merge(var.common_tags, {
    cflt_keep_until = formatdate("YYYY-MM-DD", timeadd(timestamp(), "8766h"))
  })
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.mandatory_tags
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}
