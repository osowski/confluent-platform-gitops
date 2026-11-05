# 20. Terraform State Locking Uses S3 Native Lock Files

Date: 2026-11-05

## Status

Accepted. Supersedes the locking half of [ADR-0006](0006-terraform-remote-state-module-structure.md).

## Context

[ADR-0006](0006-terraform-remote-state-module-structure.md) stores Terraform state in S3 and locks it with a shared DynamoDB table (`confluent-platform-gitops-tflock`). Terraform 1.11 made S3 native locking generally available and deprecated the S3 backend's `dynamodb_table` argument; every `init`, `plan` and `apply` now prints a deprecation warning.

The `eks-demo` root already requires Terraform >= 1.11 for ephemeral resources and write-only arguments ([ADR-0019](0019-generated-client-secrets-ephemeral-write-only.md)).

## Decision

Both Terraform roots (`terraform/clusters/eks-demo`, `terraform/dns-bootstrap`) set `use_lockfile = true` in their `backend "s3"` block and drop `dynamodb_table`. Both require Terraform `>= 1.11, < 2.0`.

## Consequences

**Positive:**

- No deprecation warning, and one fewer AWS resource to bootstrap and grant access to.
- The lock lives beside the state it protects (`<state key>.tflock`), under the bucket's existing versioning and encryption.

**Negative / constraints:**

- Each existing checkout must run `terraform init -reconfigure` once; the state key is unchanged, so no state migration is needed.
- A checkout still configured for DynamoDB does not see S3 locks, and the reverse. Every operator of a root must switch before the next concurrent run.
- Operators need `s3:PutObject` and `s3:DeleteObject` on the `.tflock` key in addition to the state key.

## Related

- [#493](https://github.com/osowski/confluent-platform-gitops/issues/493)
- [Terraform S3 backend: state locking](https://developer.hashicorp.com/terraform/language/backend/s3#state-locking)
- [Remote State Bootstrap](../terraform/REMOTE_STATE.md)
