# 6. Remote Terraform State and Reusable Module Structure

Date: 2026-04-22

## Status

Accepted

## Context

The initial `terraform/eks-demo/` implementation shipped with local Terraform state — the `terraform.tfstate` file lived on the operator's laptop. For a cluster that a single person provisions and owns, local state is workable. It stops being workable the moment a second person needs to run `terraform apply`, or the moment you want a second cluster.

Two gaps drove this decision:

1. **No shared state**: Local state means only the person who ran `terraform apply` has the current state file. Anyone else trying to run `terraform plan` gets a blank state or a stale one. This also makes CI/CD automation impossible without bespoke state hand-off procedures.

2. **No reusability**: `terraform/eks-demo/` was a flat root module — it mixed provider configuration, backend configuration, and all resource definitions into one directory. Adding a second EKS cluster meant copying and editing the entire directory, with no guarantee that changes made to one cluster's copy would flow to the others.

The options considered for remote state were:

1. **Terraform Cloud / HCP Terraform**: Managed state backend with locking, policy enforcement, and a run UI. Rejected — this project deliberately avoids external SaaS dependencies where a self-managed alternative exists, and there is no organizational Terraform Cloud account to use.
2. **S3 + DynamoDB**: AWS-native remote state with S3 versioning for state history and DynamoDB for distributed locking. Selected — the project is already AWS-native, and this is the canonical pattern for self-managed Terraform state on AWS.

The options considered for the module structure were:

1. **Single root with `for_each`**: One Terraform root manages all clusters via a map of cluster configurations, iterating with `for_each`. Rejected — a single bad `terraform plan` can affect all clusters simultaneously, and per-cluster sensitive values (Route53 zone IDs, etc.) become awkward to manage in a single `terraform.tfvars` map.
2. **One root per cluster, shared module**: Extract all resource definitions into a reusable module (`terraform/modules/eks-cluster/`). Each cluster gets its own root in `terraform/clusters/<name>/` that calls the module with cluster-specific variables. Selected — full blast-radius isolation per cluster, clean variable separation, and the same module path works for any future cluster with no duplication.

## Decision

Use S3 + DynamoDB for remote Terraform state, provisioned once via manual AWS CLI bootstrap (documented in each root's README). The S3 bucket is shared across all roots, with each root writing to a distinct key prefix (`eks-demo/terraform.tfstate`, `dns-bootstrap/terraform.tfstate`). The DynamoDB table is shared with per-root lock keys.

Extract all EKS cluster resource definitions into `terraform/modules/eks-cluster/`. The module contains no provider or backend configuration — it is a pure resource library. Each cluster instance lives in `terraform/clusters/<cluster-name>/`, which owns the provider, backend, and a single module call with cluster-specific variable values.

The `terraform/dns-bootstrap/` root is not restructured (it provisions a single shared Route53 zone, not per-cluster infrastructure), but it does receive the S3 backend to eliminate its local state dependency.

## Consequences

### Positive

- **Shared, lockable state**: Any operator with the correct AWS credentials can run `terraform plan` or `terraform apply` against a cluster without needing a copy of the state file. DynamoDB locking prevents concurrent applies from corrupting state.
- **State history**: S3 versioning means every prior state is recoverable. A bad apply no longer means a permanently corrupt state.
- **Zero duplication for additional clusters**: Adding a second EKS cluster requires only a new `terraform/clusters/<name>/` directory with a `main.tf`, `variables.tf`, `outputs.tf`, and `terraform.tfvars`. All resource logic lives in the shared module.
- **Isolated blast radius**: Each cluster root has its own state file and its own `terraform apply` invocation. A plan error in `eks-prod` cannot touch `eks-demo`.

### Negative

- **Backend bootstrap is a manual prerequisite**: The S3 bucket and DynamoDB table must exist before `terraform init` can succeed. This is documented but cannot be automated by the same Terraform that needs them. New operators must read the README and run the bootstrap commands before anything else works.
- **Backend values are not variables**: The `backend "s3"` block in Terraform does not support variable interpolation. Bucket name and DynamoDB table name are hardcoded as placeholder strings in `main.tf`. Operators must edit `main.tf` directly when bootstrapping — they cannot set these values via `terraform.tfvars`.
- **State migration required for existing clusters**: Moving an existing cluster from local to remote state requires a `terraform init -migrate-state` step. This is a one-time operation but requires the operator to have the current `terraform.tfstate` on hand.
- **Module depth adds one layer of indirection**: `terraform plan` output now shows resource addresses as `module.eks_cluster.module.vpc.aws_subnet.private[0]` rather than `module.vpc.aws_subnet.private[0]`. Minor but worth knowing for operators reading plan output.

### Neutral

- **One S3 bucket, multiple key prefixes**: The shared bucket approach means a single IAM policy grants access to all cluster state. Per-cluster bucket isolation (one bucket per cluster) is more granular but adds operational overhead that is not warranted at this scale.
- **DynamoDB table is shared**: All roots use the same DynamoDB table for locking; the lock key includes the S3 bucket + key path, so there is no collision risk between concurrent applies on different roots.

## References

- [eks-cluster module](../terraform/modules/eks-cluster/)
- [eks-demo cluster root](../terraform/clusters/eks-demo/)
- [dns-bootstrap](../terraform/dns-bootstrap/)
- [ADR-0005: Terraform and ArgoCD Cluster Provisioning Split](0005-terraform-argocd-cluster-provisioning-split.md)
- [GitHub Issue #254](https://github.com/osowski/confluent-platform-gitops/issues/254)
