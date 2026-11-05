# Device Trust Mesh credentials for eks-demo.
#
# Each Kafka / Schema Registry client gets a Keycloak OAuth client whose secret is
# generated here and stored in Secrets Manager. A namespaced External Secrets
# Operator SecretStore (ServiceAccount device-trust-mesh/dtm-eso) reads them
# through the IRSA role below. Keycloak's client definitions consume the same
# values through External Secrets, so the secret never lives in Git.
# The ServiceAccount name must match the SecretStore overlay for
# workloads/device-trust-mesh — changing it there without updating the trust
# policy will silently break IRSA.

locals {
  dtm_clients = ["sa-dtm-ray", "sa-dtm-simulator", "sa-dtm-ui", "sa-dtm-flink"]
}

data "aws_caller_identity" "current" {}

# ── Client secrets ────────────────────────────────────────────────────────────
# recovery_window_in_days = 0 on all secrets: intentional for this lab environment.
# Allows destroy/recreate cycles without the 7–30 day AWS recovery window blocking re-use of the same secret name.
# Do not carry this setting into a production environment.
# Divvy-added tags are filtered by the provider's ignore_tags, so no per-resource
# lifecycle exclusion is needed.

data "aws_secretsmanager_random_password" "dtm_client" {
  for_each = toset(local.dtm_clients)

  password_length     = 40
  exclude_punctuation = true
}

resource "aws_secretsmanager_secret" "dtm_client" {
  for_each = toset(local.dtm_clients)

  name                    = "/device-trust-mesh/${each.key}"
  description             = "Keycloak OAuth client credentials for ${each.key} (device-trust-mesh)"
  recovery_window_in_days = 0
}

# The generated value is written once; ignore_changes keeps later plans from
# rotating a secret that Keycloak and the workloads already hold.
resource "aws_secretsmanager_secret_version" "dtm_client" {
  for_each = toset(local.dtm_clients)

  secret_id = aws_secretsmanager_secret.dtm_client[each.key].id
  secret_string = jsonencode({
    client_id     = each.key
    client_secret = data.aws_secretsmanager_random_password.dtm_client[each.key].random_password
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ── External Secrets Operator (read-only on /device-trust-mesh/*) ─────────────

resource "aws_iam_role" "dtm_eso" {
  name        = "dtm-eso-${var.cluster_name}"
  description = "IRSA role for External Secrets Operator reading device-trust-mesh secrets (device-trust-mesh/dtm-eso)"

  assume_role_policy = templatefile("${path.module}/../../modules/eks-cluster/trust-policy.tpl", {
    oidc_provider_arn = module.eks_cluster.oidc_provider_arn
    oidc_provider     = replace(module.eks_cluster.cluster_oidc_issuer_url, "https://", "")
    namespace         = "device-trust-mesh"
    sa_name           = "dtm-eso"
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "dtm_eso" {
  name = "dtm-secretsmanager-read"
  role = aws_iam_role.dtm_eso.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = ["arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:/device-trust-mesh/*"]
      }
    ]
  })
}
