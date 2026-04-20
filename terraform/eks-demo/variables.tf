variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "eks-demo"
}

variable "kubernetes_version" {
  type    = string
  default = "1.31"
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
  type    = string
  default = "10.0.0.0/16"
}

variable "node_instance_type" {
  type    = string
  default = "t3.xlarge"
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 5
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
