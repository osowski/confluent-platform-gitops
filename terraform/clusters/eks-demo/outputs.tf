output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks_cluster.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint (private only)"
  value       = module.eks_cluster.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded cluster CA certificate — used in kubeconfig"
  value       = module.eks_cluster.cluster_certificate_authority_data
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL for IRSA trust policies"
  value       = module.eks_cluster.cluster_oidc_issuer_url
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider — used in IRSA IAM role trust policies"
  value       = module.eks_cluster.oidc_provider_arn
}

output "cluster_security_group_id" {
  description = "Security group attached to the EKS control plane"
  value       = module.eks_cluster.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group shared by all managed node group nodes"
  value       = module.eks_cluster.node_security_group_id
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.eks_cluster.vpc_id
}

output "private_subnets" {
  description = "Private subnet IDs"
  value       = module.eks_cluster.private_subnets
}

output "bastion_instance_id" {
  description = "SSM target ID — use with: aws ssm start-session --target <id>"
  value       = module.eks_cluster.bastion_instance_id
}

output "ebs_csi_driver_role_arn" {
  description = "IRSA role ARN for the EBS CSI driver"
  value       = module.eks_cluster.ebs_csi_driver_role_arn
}

output "cert_manager_role_arn" {
  description = "IRSA role ARN for cert-manager"
  value       = module.eks_cluster.cert_manager_role_arn
}

output "external_dns_role_arn" {
  description = "IRSA role ARN for ExternalDNS"
  value       = module.eks_cluster.external_dns_role_arn
}

output "aws_lb_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller"
  value       = module.eks_cluster.aws_lb_controller_role_arn
}
