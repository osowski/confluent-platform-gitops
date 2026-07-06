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

## Tearing Down the Cluster

Kubernetes controllers (Traefik's `LoadBalancer` Service, Confluent's traffic/NLB controller) provision AWS load balancers and security groups directly against the VPC — outside of Terraform state. Delete those in-cluster **before** running `terraform destroy`, so AWS tears down the associated NLB/ELB and its security groups on its own instead of leaving orphaned resources behind:

```bash
# Delete any Kubernetes-managed LoadBalancer Services (e.g. Traefik) first
kubectl get svc -A --field-selector spec.type=LoadBalancer
kubectl delete svc -n <namespace> <service-name>

# Wait for the backing AWS load balancer to actually disappear before proceeding
aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='<vpc-id>']"

terraform destroy
```

### Troubleshooting: Traefik LoadBalancer left behind after `terraform destroy`

If `terraform destroy` already ran without deleting the Traefik `LoadBalancer` Service first, the EKS cluster is gone — there's no `kubectl` left to clean it up through Kubernetes. The AWS load balancer the AWS Load Balancer Controller provisioned for it still exists in the VPC and needs to be removed directly via the AWS CLI, found by its cluster tag:

```bash
# Find load balancers tagged with this cluster
aws resourcegroupstaggingapi get-resources \
  --resource-type-filters elasticloadbalancing:loadbalancer \
  --tag-filters Key=elbv2.k8s.aws/cluster,Values=<cluster-name> \
  --query 'ResourceTagMappingList[].ResourceARN' --output table

# Delete the load balancer
aws elbv2 delete-load-balancer --load-balancer-arn <lb-arn>

# Delete its target group(s) — deleting the LB doesn't clean these up automatically
aws elbv2 describe-target-groups --load-balancer-arn <lb-arn> --query 'TargetGroups[].TargetGroupArn' --output table
aws elbv2 delete-target-group --target-group-arn <tg-arn>

# Re-run destroy once the load balancer is gone
terraform destroy
```

If the load balancer's security group is still attached to the VPC after this (AWS can take a minute to release it), see the `DependencyViolation` troubleshooting below for how to identify and remove orphaned security groups.

### Troubleshooting: VPC `DependencyViolation` on destroy

If the `LoadBalancer` Services weren't cleaned up first (e.g. the workloads were deleted via `kubectl` after Terraform state already forgot about them, or ArgoCD apps were never pruned), `terraform destroy` will remove everything it manages but fail to delete the VPC with a `DependencyViolation` error, because the load balancer and/or its non-default security groups are still attached to it.

**1. Confirm the VPC still exists in state and get its ID:**
```bash
terraform state list | grep aws_vpc
terraform state show '<vpc_resource_address_from_above>' | grep -E '^\s*id\s*='
```

**2. Find what's still attached to the VPC** (replace `<vpc-id>`):
```bash
aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='<vpc-id>'].{ARN:LoadBalancerArn,Name:LoadBalancerName}" --output table
aws elb describe-load-balancers --query "LoadBalancerDescriptions[?VPCId=='<vpc-id>'].{Name:LoadBalancerName}" --output table

aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=<vpc-id>" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status,Desc:Description}' --output table

aws ec2 describe-security-groups --filters "Name=vpc-id,Values=<vpc-id>" \
  --query 'SecurityGroups[].{ID:GroupId,Name:GroupName}' --output table
```

If a load balancer is still present, delete it first and wait for it to fully disappear — its security groups can't be removed while it exists, and the VPC can't be deleted while the load balancer exists:
```bash
aws elbv2 delete-load-balancer --load-balancer-arn <lb-arn>   # ALB/NLB
aws elb delete-load-balancer --load-balancer-name <lb-name>    # Classic ELB
```

Any security group other than `default` is a candidate for manual cleanup. Before deleting one, verify nothing still references it:
```bash
aws ec2 describe-network-interfaces --filters "Name=group-id,Values=<sg-id>" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}'
```

If that returns nothing (no attached ENIs), the security group is orphaned and safe to remove.

**3. Delete the orphaned security group(s) and re-run destroy:**
```bash
aws ec2 delete-security-group --group-id <sg-id>

terraform destroy
```

The `default` security group is deleted automatically by AWS when the VPC itself is removed — don't try to delete it manually.

## Adding a New Cluster

To provision a second EKS cluster (e.g., `eks-prod`):

1. Create `terraform/clusters/eks-prod/` by copying this directory:
```bash
  cp -r terraform/clusters/eks-demo terraform/clusters/eks-prod
  rm -rf terraform/clusters/eks-prod/.terraform
  rm -f terraform/clusters/eks-prod/.terraform.lock.hcl
```
2. Update `main.tf`: change the backend `key` to `eks-prod/terraform.tfstate`
3. Update `terraform.tfvars` with cluster-specific values (`cluster_name`, `vpc_cidr`, sizing)
4. Run `terraform init && terraform apply` from the new directory

Each cluster directory is fully independent — separate state, separate apply blast radius.
