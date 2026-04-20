variable "aws_region" {
  # Route53 is a global service; this only satisfies the provider's required region
  # argument and does not affect zone placement. us-east-1 is the conventional value.
  description = "AWS provider region — Route53 is global and unaffected by this value"
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
