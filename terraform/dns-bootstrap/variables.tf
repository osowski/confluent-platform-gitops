variable "aws_region" {
  description = "AWS region for Route53 operations"
  type        = string
  default     = "us-east-1"
}

variable "root_domain" {
  description = "Root domain name (e.g. dspdemos.com)"
  type        = string
}

variable "platform_subdomain" {
  description = "Platform subdomain prefix (e.g. platform)"
  type        = string
  default     = "platform"
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
