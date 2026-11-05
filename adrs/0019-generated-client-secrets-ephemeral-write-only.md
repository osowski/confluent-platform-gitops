# 19. Generated Client Secrets Use Ephemeral Resources and Write-Only Arguments

Date: 2026-11-05

## Status

Accepted

## Context

Issue [#493](https://github.com/osowski/confluent-platform-gitops/issues/493): the Device Trust Mesh workloads on `eks-demo` need four Keycloak OAuth client secrets (`/device-trust-mesh/<cluster_name>/sa-dtm-*`). Terraform generates them and stores them in Secrets Manager; External Secrets Operator reads them into the cluster, so the values never live in Git.

The obvious generator, the `aws_secretsmanager_random_password` data source, exposes each value as its `id` and `random_password` attributes. Both land in plan output, apply logs and Terraform state, which the S3 backend stores for every operator with access to the bucket.

## Decision

Generate each secret with the `ephemeral "aws_secretsmanager_random_password"` resource and pass it to `aws_secretsmanager_secret_version` through the write-only argument `secret_string_wo`, paired with `secret_string_wo_version`:

```hcl
ephemeral "aws_secretsmanager_random_password" "dtm_client" { ... }

resource "aws_secretsmanager_secret_version" "dtm_client" {
  secret_string_wo         = jsonencode({ ... ephemeral.aws_secretsmanager_random_password.dtm_client[each.key].random_password ... })
  secret_string_wo_version = 1
}
```

## Consequences

**Positive:**

- The values never appear in state, plan output or apply logs.
- Rotation is explicit: increment `secret_string_wo_version` and apply.

**Negative / constraints:**

- Secrets Manager holds the only copy. Recovering a value means reading it there; Terraform cannot show it.
- Terraform >= 1.11 is required, and the AWS provider must be 6.x (`~> 6.0`).
- Plan and apply need `secretsmanager:GetRandomPassword`.
- Terraform cannot detect out-of-band changes to the secret value; only the version number is compared.

## Related

- [#493](https://github.com/osowski/confluent-platform-gitops/issues/493)
- `terraform/clusters/eks-demo/device-trust-mesh.tf`
- [eks-demo Terraform README](../terraform/clusters/eks-demo/README.md#device-trust-mesh-secrets)
