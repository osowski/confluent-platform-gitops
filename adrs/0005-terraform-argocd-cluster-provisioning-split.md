# 5. Terraform and ArgoCD Split for Cluster Provisioning

Date: 2026-04-22

## Status

Accepted

## Context

Every other cluster in this repository — flink-demo, flink-demo-rbac — assumes the Kubernetes cluster already exists when ArgoCD takes over. That assumption holds for kind clusters because kind cluster creation is a single CLI command that completes in under a minute and produces no persistent infrastructure. The eks-demo cluster is different: it requires a VPC, three availability zones of private and public subnets, a NAT Gateway, a collection of VPC Interface Endpoints (SSM, ECR, EKS, STS, CloudWatch Logs), an EKS control plane, managed node groups with associated IAM roles, a bastion EC2 instance, and the security groups that wire it all together. That is not a kind cluster, and it cannot be bootstrapped with a single CLI command.

The question became: how do you provision the cluster infrastructure itself, and where does that responsibility end and ArgoCD's begin? The options considered were:

1. **Crossplane**: Manage AWS resources as Kubernetes CRDs from within an existing cluster. Rejected — this creates a chicken-and-egg problem, since you need a cluster to run Crossplane before Crossplane can create your cluster.
2. **AWS CDK or CloudFormation**: AWS-native IaC alternatives to Terraform. Rejected — the team has existing Terraform familiarity, and the `terraform-aws-modules/eks/aws` module is well-maintained, widely used, and covers the full EKS provisioning surface in a single coherent module.
3. **Terraform**: Declarative IaC that manages AWS resources directly from a local or CI workspace with explicit state management. Selected.

The boundary decision — precisely where Terraform stops and ArgoCD starts — was the more nuanced part of this. The answer we landed on is clean and intuitive: Terraform owns everything required for the cluster to exist and be reachable. ArgoCD owns everything that runs inside the cluster once it is reachable.

The hand-off point is `aws eks update-kubeconfig` succeeding and `kubectl get nodes` returning healthy nodes. Everything before that line belongs to Terraform. Everything after it belongs to ArgoCD.

## Decision

Use Terraform (`terraform/eks-demo/`) to provision all cluster-level AWS infrastructure: VPC, subnets, NAT Gateway, VPC endpoints, EKS cluster, managed node groups, IRSA IAM roles, bastion host, and security groups. Use ArgoCD (via the standard GitOps bootstrap in `clusters/eks-demo/`) for all workloads and operators running inside the cluster.

## Consequences

### Positive

- **Clean separation of concerns**: Terraform manages durable AWS infrastructure with proper state management and an explicit apply workflow; ArgoCD manages application lifecycle with GitOps semantics and continuous reconciliation. Each tool does what it is best at, and neither is asked to operate outside its natural domain.
- **Reusable module structure**: The `terraform/eks-demo/` root is self-contained — variables, outputs, and IAM policies are all colocated — making it straightforward to replicate for additional EKS clusters in the future.
- **IRSA outputs feed ArgoCD directly**: Terraform outputs the OIDC provider ARN and all IRSA role ARNs (EBS CSI, cert-manager, ExternalDNS, AWS Load Balancer Controller) that ArgoCD Helm values overlays consume. This creates a clean, explicit data flow between the two provisioning layers with no guesswork about resource names.
- **Drift detection**: `terraform plan` provides a clear, diff-based view of infrastructure drift at any time; `terraform apply` is the authoritative reconciliation path for AWS resources.

### Negative

- **Two tools to operate**: Operators need both Terraform and ArgoCD familiarity to manage the cluster end-to-end. The onboarding experience is more involved than for kind-based clusters, where a single `kind create cluster` is all that stands between you and running ArgoCD.
- **No GitOps for cluster infrastructure**: Terraform state is local (or remote, if a backend is configured) rather than continuously reconciled from Git. Infrastructure changes require a human to run `terraform apply`; there is no automatic drift correction the way ArgoCD provides for workloads.
- **tfvars not committed**: `terraform.tfvars` contains sensitive values (Route53 zone ID, etc.) and is gitignored. Re-provisioning a fresh environment requires reconstructing this file from `terraform.tfvars.example` and external sources.

### Neutral

- **Consistent with broader ecosystem patterns**: Terraform + ArgoCD (or Flux) is the standard pattern for managing EKS at scale. This decision aligns with how the majority of production EKS deployments are structured, which means documentation, tooling, and community knowledge all transfer directly.
- **No remote Terraform backend configured**: The current `terraform/eks-demo/` uses local state. For a multi-operator environment where more than one person needs to run `terraform apply`, an S3 backend with DynamoDB state locking would be the natural next step — but that complexity is deferred until it becomes necessary.

## References

- [eks-demo Terraform module](../terraform/eks-demo/)
- [ADR-0004: Private EKS API Endpoint with SSM+SOCKS5 Bastion](0004-private-eks-api-ssm-bastion.md)
- [terraform-aws-modules/eks/aws](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest)
- [GitHub Issue #24](https://github.com/osowski/confluent-platform-gitops/issues/24)
