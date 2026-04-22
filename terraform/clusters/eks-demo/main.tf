terraform {
  required_version = ">= 1.9, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    # Run the bootstrap steps in the README to create these resources before
    # running terraform init for the first time.
    bucket         = "confluent-platform-gitops-tfstate"
    key            = "eks-demo/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "confluent-platform-gitops-tflock"
  }
}

locals {
  mandatory_tags = merge(var.common_tags, {
    cflt_keep_until = var.cflt_keep_until
  })
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.mandatory_tags
  }
  # Ignore tags added by Confluent's Divvy compliance scanner — managed externally
  ignore_tags {
    key_prefixes = ["divvy"]
  }
}

module "eks_cluster" {
  source = "../../modules/eks-cluster"

  aws_region         = var.aws_region
  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  platform_zone_id   = var.platform_zone_id
  platform_domain    = var.platform_domain
  vpc_cidr           = var.vpc_cidr
  node_instance_type = var.node_instance_type
  node_desired_size  = var.node_desired_size
  node_min_size      = var.node_min_size
  node_max_size      = var.node_max_size
  common_tags        = var.common_tags
}
