# eks-demo

Terraform root for the `eks-demo` EKS cluster. Calls `../../modules/eks-cluster` with cluster-specific configuration. Terraform state is stored in S3 with DynamoDB state locking.

## Prerequisites

- [dns-bootstrap](../../dns-bootstrap/) applied (provides `platform_zone_id` output)
- S3 bucket and DynamoDB table provisioned (see [Remote State Bootstrap](../../REMOTE_STATE.md))
- AWS credentials with EKS, EC2, VPC, IAM, and Route53 permissions

## Remote State Bootstrap

See [terraform/REMOTE_STATE.md](../../REMOTE_STATE.md) for the one-time S3 bucket and DynamoDB table setup. The bucket and table are shared across all Terraform roots — create them once, then use the same names in the `backend "s3"` block in `main.tf`.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set platform_zone_id (from dns-bootstrap) and cflt_keep_until

terraform init
terraform plan
terraform apply
```

## Migrating from Local State

If you have an existing `terraform.tfstate` from the old `terraform/eks-demo/` root, migrate it to S3 before running a fresh apply:

```bash
# 1. Copy the existing local state into this directory
cp ../../eks-demo/terraform.tfstate .

# 2. Initialize with migration — Terraform will upload the local state to S3
terraform init -migrate-state

# 3. Verify with a plan — should show no changes if the config maps cleanly
terraform plan

# 4. Remove the local state file from this directory
rm terraform.tfstate
```

After migration, the `terraform/eks-demo/` directory can be removed from the repository (it has been replaced by `terraform/clusters/eks-demo/` and `terraform/modules/eks-cluster/`).

## What This Provisions

| Resource group | Description |
|----------------|-------------|
| VPC | `/16` CIDR, 3 private `/20` + 3 public `/24` subnets across 3 AZs |
| NAT Gateway | Single NAT gateway for private subnet egress |
| VPC Interface Endpoints | SSM, SSMMessages, EC2Messages, ECR API, ECR DKR, EKS, STS, CloudWatch Logs |
| VPC Gateway Endpoint | S3 (ECR image layer pulls) |
| EKS Control Plane | Kubernetes 1.32, private-only API endpoint |
| Managed Node Group | `workers-v2`: t3.2xlarge, 4–6 nodes, AL2023, 100 GiB gp3 root volume |
| Bastion Host | t3.small, no public IP, SSM + 3proxy SOCKS5, no inbound SG rules |
| IRSA Roles | EBS CSI driver, cert-manager, ExternalDNS, AWS Load Balancer Controller |

## Outputs

| Output | Description |
|--------|-------------|
| `cluster_name` | EKS cluster name |
| `cluster_endpoint` | Private API server endpoint |
| `bastion_instance_id` | SSM session target — pass to `aws ssm start-session --target` |
| `ebs_csi_driver_role_arn` | IRSA role ARN for EBS CSI driver |
| `cert_manager_role_arn` | IRSA role ARN for cert-manager |
| `external_dns_role_arn` | IRSA role ARN for ExternalDNS |
| `aws_lb_controller_role_arn` | IRSA role ARN for AWS Load Balancer Controller |

## Accessing the Cluster

The EKS API endpoint is private-only. All `kubectl` access requires an active SSM tunnel through the bastion.

```bash
# Start the tunnel (keep this terminal open)
aws ssm start-session \
  --target $(terraform output -raw bastion_instance_id) \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["1080"],"localPortNumber":["1080"]}'

# In a second terminal — configure kubectl and set proxy
aws eks update-kubeconfig --name $(terraform output -raw cluster_name) --region us-east-1
export HTTPS_PROXY=socks5://localhost:1080

kubectl get nodes
```

## Adding a New Cluster

To provision a second EKS cluster (e.g., `eks-prod`):

1. Create `terraform/clusters/eks-prod/` by copying this directory
2. Update `main.tf`: change the backend `key` to `eks-prod/terraform.tfstate`
3. Update `terraform.tfvars` with cluster-specific values (`cluster_name`, `vpc_cidr`, sizing)
4. Run `terraform init && terraform apply` from the new directory

Each cluster directory is fully independent — separate state, separate apply blast radius.

## References

- [eks-cluster module](../../modules/eks-cluster/)
- [dns-bootstrap](../../dns-bootstrap/)
- [ADR-0004: Private EKS API Endpoint with SSM+SOCKS5 Bastion](../../../adrs/0004-private-eks-api-ssm-bastion.md)
- [ADR-0005: Terraform and ArgoCD Cluster Provisioning Split](../../../adrs/0005-terraform-argocd-cluster-provisioning-split.md)
- [ADR-0006: Remote Terraform State and Reusable Module Structure](../../../adrs/0006-terraform-remote-state-module-structure.md)
