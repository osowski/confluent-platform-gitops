locals {
  oidc_provider_arn = module.eks.oidc_provider_arn
  # Strip https:// prefix — used as the condition key in IRSA trust policies
  oidc_provider = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
}

# ── EBS CSI Driver ────────────────────────────────────────────────────────────
# The driver itself is installed via ArgoCD in Task 10 (Issue #185) —
# infrastructure/aws-ebs-csi-driver with a Kustomize overlay that annotates
# the ServiceAccount with this role ARN. It is not a managed EKS addon.
# sa_name must match controller.serviceAccount.name in the Helm values for
# infrastructure/aws-ebs-csi-driver/overlays/eks-demo — changing it there
# without updating this trust policy will silently break IRSA.

resource "aws_iam_role" "ebs_csi_driver" {
  name        = "AmazonEKS_EBS_CSI_DriverRole_${var.cluster_name}"
  description = "IRSA role for the EBS CSI Driver controller (kube-system/ebs-csi-controller-sa)"

  assume_role_policy = templatefile("${path.module}/trust-policy.tpl", {
    oidc_provider_arn = local.oidc_provider_arn
    oidc_provider     = local.oidc_provider
    namespace         = "kube-system"
    sa_name           = "ebs-csi-controller-sa"
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ── cert-manager (DNS-01 via Route53) ─────────────────────────────────────────

resource "aws_iam_role" "cert_manager" {
  name        = "AmazonEKS_CertManager_${var.cluster_name}"
  description = "IRSA role for cert-manager DNS-01 Route53 validation (cert-manager/cert-manager)"

  assume_role_policy = templatefile("${path.module}/trust-policy.tpl", {
    oidc_provider_arn = local.oidc_provider_arn
    oidc_provider     = local.oidc_provider
    namespace         = "cert-manager"
    sa_name           = "cert-manager"
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "cert_manager" {
  name = "cert-manager-route53"
  role = aws_iam_role.cert_manager.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:GetChange"]
        Resource = ["arn:aws:route53:::change/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
        Resource = ["arn:aws:route53:::hostedzone/${var.platform_zone_id}"]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZonesByName"]
        Resource = ["*"]
      }
    ]
  })
}

# ── ExternalDNS ───────────────────────────────────────────────────────────────

resource "aws_iam_role" "external_dns" {
  name        = "ExternalDNS_${var.cluster_name}"
  description = "IRSA role for ExternalDNS Route53 record management (external-dns/external-dns)"

  assume_role_policy = templatefile("${path.module}/trust-policy.tpl", {
    oidc_provider_arn = local.oidc_provider_arn
    oidc_provider     = local.oidc_provider
    namespace         = "external-dns"
    sa_name           = "external-dns"
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "external_dns" {
  name = "external-dns-route53"
  role = aws_iam_role.external_dns.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = ["arn:aws:route53:::hostedzone/${var.platform_zone_id}"]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:ListHostedZonesByName", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
        Resource = ["*"]
      }
    ]
  })
}

# ── AWS Load Balancer Controller ──────────────────────────────────────────────

resource "aws_iam_role" "aws_lb_controller" {
  name        = "AWSLoadBalancerController_${var.cluster_name}"
  description = "IRSA role for the AWS Load Balancer Controller (kube-system/aws-load-balancer-controller)"

  assume_role_policy = templatefile("${path.module}/trust-policy.tpl", {
    oidc_provider_arn = local.oidc_provider_arn
    oidc_provider     = local.oidc_provider
    namespace         = "kube-system"
    sa_name           = "aws-load-balancer-controller"
  })

  tags = var.common_tags
}

resource "aws_iam_policy" "aws_lb_controller" {
  name        = "AWSLoadBalancerControllerIAMPolicy_${var.cluster_name}"
  description = "IAM permissions for the AWS Load Balancer Controller — sourced from kubernetes-sigs/aws-load-balancer-controller"
  # Update aws-lb-controller-iam-policy.json when upgrading the controller Helm chart version;
  # the policy changes across minor releases.
  policy = file("${path.module}/aws-lb-controller-iam-policy.json")
  tags   = var.common_tags
}

resource "aws_iam_role_policy_attachment" "aws_lb_controller" {
  role       = aws_iam_role.aws_lb_controller.name
  policy_arn = aws_iam_policy.aws_lb_controller.arn
}
