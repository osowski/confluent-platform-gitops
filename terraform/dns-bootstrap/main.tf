terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    # Run the bootstrap steps in the README to create these resources before
    # running terraform init for the first time.
    bucket         = "confluent-platform-gitops-tfstate"
    key            = "dns-bootstrap/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "confluent-platform-gitops-tflock"
  }
}

provider "aws" {
  region = var.aws_region
  # Ignore tags added by Confluent's Divvy compliance scanner — managed externally
  ignore_tags {
    key_prefixes = ["divvy"]
  }
}

locals {
  platform_domain = "${var.platform_subdomain}.${var.root_domain}"
}

# Root domain hosted zone
resource "aws_route53_zone" "root" {
  name = var.root_domain
  tags = var.tags
}

# Platform subdomain hosted zone (separate zone for scoped IAM policies)
resource "aws_route53_zone" "platform" {
  name = local.platform_domain
  tags = var.tags
}

# NS delegation from root zone to platform zone
resource "aws_route53_record" "platform_ns" {
  zone_id = aws_route53_zone.root.zone_id
  name    = local.platform_domain
  type    = "NS"
  ttl     = 3600
  records = aws_route53_zone.platform.name_servers
}
