terraform {
  required_version = ">= 1.9, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

locals {
  # Filter to AZs that support Interface VPC endpoint services.
  # In us-east-1, us-east-1e is "available" but lacks endpoint service and NAT Gateway support.
  azs = slice(
    [for az in data.aws_availability_zones.available.names :
    az if contains(data.aws_vpc_endpoint_service.ssm.availability_zones, az)],
    0, 3
  )

  # cflt_keep_until is stable across plan→apply via plantimestamp()
  mandatory_tags = merge(var.common_tags, {
    cflt_keep_until = formatdate("YYYY-MM-DD", timeadd(plantimestamp(), "8766h"))
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

data "aws_vpc_endpoint_service" "ssm" {
  service      = "ssm"
  service_type = "Interface"
}
