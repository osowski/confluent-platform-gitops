locals {
  oidc_provider_arn = module.eks.oidc_provider_arn
  # Strip https:// prefix — used as the condition key in IRSA trust policies
  oidc_provider = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
}

# ── EBS CSI Driver ────────────────────────────────────────────────────────────

resource "aws_iam_role" "ebs_csi_driver" {
  name = "AmazonEKS_EBS_CSI_DriverRole_${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = local.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${local.oidc_provider}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ── cert-manager (DNS-01 via Route53) ─────────────────────────────────────────

resource "aws_iam_role" "cert_manager" {
  name = "AmazonEKS_CertManager_${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = local.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${local.oidc_provider}:sub" = "system:serviceaccount:cert-manager:cert-manager"
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
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
  name = "ExternalDNS_${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = local.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${local.oidc_provider}:sub" = "system:serviceaccount:external-dns:external-dns"
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
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
        Action   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
        Resource = ["*"]
      }
    ]
  })
}

# ── AWS Load Balancer Controller ──────────────────────────────────────────────

data "aws_iam_policy_document" "aws_lb_controller_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "aws_lb_controller" {
  name               = "AWSLoadBalancerController_${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.aws_lb_controller_trust.json
  tags               = var.common_tags
}

resource "aws_iam_policy" "aws_lb_controller" {
  name   = "AWSLoadBalancerControllerIAMPolicy_${var.cluster_name}"
  policy = file("${path.module}/aws-lb-controller-iam-policy.json")
  tags   = var.common_tags
}

resource "aws_iam_role_policy_attachment" "aws_lb_controller" {
  role       = aws_iam_role.aws_lb_controller.name
  policy_arn = aws_iam_policy.aws_lb_controller.arn
}
