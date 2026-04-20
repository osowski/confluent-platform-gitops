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

  # KMS encryption disabled — demo cluster is destroyed and recreated frequently;
  # a pending-deletion KMS key blocks re-provisioning within the default 10-day window.
  # Enable create_kms_key = true and set encryption_config for production clusters.
  create_kms_key    = false
  encryption_config = null

  # Control plane log types — explicit to document the monitoring posture.
  # Critical for a private cluster where CloudWatch is the primary debug path.
  enabled_log_types = ["audit", "api", "authenticator", "controllerManager", "scheduler"]

  # Core add-ons — vpc-cni and kube-proxy must be installed before nodes join
  # (before_compute = true) or nodes will have no CNI and pods will never schedule.
  addons = {
    vpc-cni    = { before_compute = true }
    kube-proxy = {}
    coredns    = {}
  }

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

      ami_type = "AL2023_x86_64_STANDARD"

      # 20 GiB default fills rapidly under Confluent Platform image pulls + ephemeral storage.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            delete_on_termination = true
            encrypted             = true
          }
        }
      }
    }
  }

  tags = var.common_tags
}
