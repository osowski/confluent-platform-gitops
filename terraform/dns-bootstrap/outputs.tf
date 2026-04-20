output "root_zone_id" {
  description = "Route53 hosted zone ID for the root domain"
  value       = aws_route53_zone.root.zone_id
}

output "root_zone_name_servers" {
  description = "Name servers for the root zone — configure these at your registrar"
  value       = aws_route53_zone.root.name_servers
}

output "platform_zone_id" {
  description = "Route53 hosted zone ID for platform subdomain — used by per-cluster Terraform"
  value       = aws_route53_zone.platform.zone_id
}

output "platform_zone_name_servers" {
  description = "Name servers for the platform zone — delegated from the root zone NS record"
  value       = aws_route53_zone.platform.name_servers
}

output "platform_domain" {
  description = "Fully qualified platform domain"
  value       = local.platform_domain
}
