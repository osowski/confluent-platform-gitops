variable "aws_region" {
  description = "AWS region for the deployment — used to construct VPC endpoint service names"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — used as a prefix for all named resources"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
}

variable "platform_zone_id" {
  description = "Route53 zone ID for the platform subdomain — from dns-bootstrap output"
  type        = string
}

variable "platform_domain" {
  description = "Platform domain (e.g. platform.dspdemos.com)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS managed node group workers"
  type        = string
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
}

variable "common_tags" {
  description = "Tags applied to all resources — provider default_tags adds cflt_keep_until on top of these"
  type        = map(string)
}

variable "infra_binaries_bucket" {
  description = "S3 bucket containing pre-built infrastructure binaries (e.g. 3proxy). Must be accessible via the VPC S3 Gateway endpoint."
  type        = string
}

variable "proxy_version" {
  description = "3proxy version to download from S3 — must match the binary uploaded to infra_binaries_bucket/binaries/3proxy-<version>-linux-x86_64"
  type        = string
  default     = "0.9.6"
}
