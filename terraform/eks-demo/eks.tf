module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Private-only API — no public endpoint; access is via SSM+SOCKS5 bastion
  endpoint_public_access  = false
  endpoint_private_access = true

  # IRSA — required for pod IAM (external-dns, cert-manager, aws-load-balancer-controller)
  enable_irsa = true

  # Grant the Terraform caller cluster-admin via access entry so post-apply kubectl works
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
    }
  }

  tags = var.common_tags
}
