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
| NAT Gateway | Single NAT gateway for private subnet egress — AZ selectable via `nat_gateway_az` |
| VPC Interface Endpoints | SSM, SSMMessages, EC2Messages, EC2, ECR API, ECR DKR, EKS, STS, CloudWatch Logs |
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

Kubernetes controllers (Traefik's `LoadBalancer` Service, Confluent's traffic/NLB controller) provision AWS load balancers and security groups outside of Terraform state. Delete them in-cluster **before** running `terraform destroy` so AWS releases the associated resources on its own:

```bash
kubectl get svc -A --field-selector spec.type=LoadBalancer
kubectl delete svc -n <namespace> <service-name>

# Wait for the backing load balancer to disappear
aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='<vpc-id>']"

terraform destroy
```

### Troubleshooting: Traefik LoadBalancer left behind after `terraform destroy`

If `terraform destroy` already ran before the Traefik Service was deleted, the EKS cluster (and `kubectl`) is gone. Find and remove the load balancer directly via its cluster tag:

```bash
aws resourcegroupstaggingapi get-resources \
  --resource-type-filters elasticloadbalancing:loadbalancer \
  --tag-filters Key=elbv2.k8s.aws/cluster,Values=<cluster-name> \
  --query 'ResourceTagMappingList[].ResourceARN' --output table

aws elbv2 delete-load-balancer --load-balancer-arn <lb-arn>

# Target groups aren't deleted automatically
aws elbv2 describe-target-groups --load-balancer-arn <lb-arn> --query 'TargetGroups[].TargetGroupArn' --output table
aws elbv2 delete-target-group --target-group-arn <tg-arn>

terraform destroy
```

If the load balancer's security group is still attached afterward, see the `DependencyViolation` section below.

### Troubleshooting: VPC `DependencyViolation` on destroy

If the load balancer or its security groups weren't cleaned up first, `terraform destroy` removes everything it manages but fails to delete the VPC, since non-default security groups are still attached.

**1. Confirm the VPC still exists in state and get its ID:**
```bash
terraform state list | grep aws_vpc
terraform state show '<vpc_resource_address_from_above>' | grep -E '^\s*id\s*='
```

**2. Find what's still attached to the VPC** (replace `<vpc-id>`):
```bash
aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=<vpc-id>" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status,Desc:Description}' --output table

aws ec2 describe-security-groups --filters "Name=vpc-id,Values=<vpc-id>" \
  --query 'SecurityGroups[].{ID:GroupId,Name:GroupName}' --output table
```

Any security group other than `default` is a candidate for cleanup. Verify nothing still references it before deleting:
```bash
aws ec2 describe-network-interfaces --filters "Name=group-id,Values=<sg-id>" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}'
```

If that returns nothing, the security group is orphaned and safe to remove.

**3. Delete the orphaned security group(s) and re-run destroy:**
```bash
aws ec2 delete-security-group --group-id <sg-id>

terraform destroy
```

The `default` security group is deleted automatically when the VPC itself is removed; don't delete it manually.

### Troubleshooting: node group stuck at 0 registered nodes

Symptom: the node group sits in `CREATING` with `health.issues` empty, while every instance shows `running` and healthy in the EC2 console. After roughly 25 minutes the node group fails with `NodeCreationFailure`.

The usual cause is that the private subnets have no route out. AL2023 `nodeadm` calls `ec2:DescribeInstances` during init, before kubelet starts — with no egress it retries forever, so the instance boots normally but never registers.

**1. Check the private route table for a default route:**
```bash
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=<vpc-id>" \
  --query 'RouteTables[?Tags[?Value==`eks-demo-private`]].Routes' --output table
```
A healthy table has `0.0.0.0/0` pointing at a NAT gateway. If it only has `local` and the S3 prefix list, the NAT gateway is missing.

**2. Confirm on the instance itself** — `get-console-output` shows the retry loop directly:
```bash
aws ec2 get-console-output --instance-id <node-instance-id> --query Output --output text \
  | grep -E 'nodeadm|DescribeInstances'
```

**3. Find why the NAT gateway wasn't created.** The most common reason is the per-AZ NAT gateway quota (`L-FE5A380F`, 20 by default). Terraform reports this at apply time, but the node group is created in parallel and buries it:
```bash
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=CreateNatGateway \
  --start-time <apply-start-time> --query 'Events[].CloudTrailEvent' --output text | grep -o 'errorMessage[^,]*'
```

**4. Remedy.** Count NAT gateways per AZ to find one with headroom:
```bash
aws ec2 describe-nat-gateways --filter Name=state,Values=available,pending \
  --query 'NatGateways[].SubnetId' --output text | tr '\t' '\n' > /tmp/natsub.txt
aws ec2 describe-subnets --subnet-ids $(tr '\n' ' ' < /tmp/natsub.txt) \
  --query 'Subnets[].AvailabilityZone' --output text | tr '\t' '\n' | sort | uniq -c | sort -rn
```
Then set `nat_gateway_az` in `terraform.tfvars` to an AZ below quota and re-apply. Alternatively, request a quota increase for `L-FE5A380F`, or delete stale NAT gateways from abandoned demo VPCs in the crowded AZ.

Note that the failed node group must be deleted before re-applying — EKS will not re-drive a node group out of `CREATING`.

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
