variable "aws_region" {
  description = "AWS region for the deployment"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name — used as a prefix for all named resources"
  type        = string
  default     = "eks-demo"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.32"
}

variable "platform_zone_id" {
  description = "Route53 zone ID for platform.dspdemos.com — from dns-bootstrap output"
  type        = string
}

variable "platform_domain" {
  description = "Platform domain (e.g. platform.dspdemos.com)"
  type        = string
  default     = "platform.dspdemos.com"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS managed node group workers"
  type        = string
  default     = "t3.2xlarge"
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 5
}

variable "common_tags" {
  description = "Confluent mandatory tags applied to all resources"
  type        = map(string)
  default = {
    cflt_environment = "devel"
    cflt_partition   = "onprem"
    cflt_service     = "osowski/confluent-platform-gitops"
    cflt_managed_by  = "terraform"
    cflt_managed_id  = "osowski/confluent-platform-gitops"
    cflt_protected   = "false"
  }
}

variable "cflt_keep_until" {
  description = "Static expiry date tag applied to all resources (YYYY-MM-DD). Set to a date at least one year out. Must be set explicitly — no default — to prevent plan drift from computed timestamps."
  type        = string
}
