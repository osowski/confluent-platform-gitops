# eks-demo

Provisions a private EKS cluster on AWS for Confluent Platform and Flink demo deployments. This Terraform root is the infrastructure foundation that every subsequent GitOps-managed workload depends on, so understanding what it creates and why the pieces are arranged the way they are will save you considerable debugging time later.

> [!IMPORTANT]
> Before diving in, there are two important scope notes. 
>
> First, this module assumes `terraform/dns-bootstrap` has already been applied and that you have the `platform_zone_id` output available. The EKS cluster, cert-manager, and ExternalDNS all depend on Route53 zones that dns-bootstrap creates.
>
> Second, this cluster uses a private-only API endpoint. There is no public Kubernetes API. All `kubectl` access goes through an SSM Session Manager port-forwarding tunnel to a bastion host running a SOCKS5 proxy. That access pattern is covered in detail below.

## What this creates

| Resource | Description |
|----------|-------------|
| VPC | `/16` CIDR across 3 availability zones, with `/20` private subnets and `/24` public subnets |
| NAT Gateway | Single NAT Gateway in a public subnet for private subnet egress |
| VPC Interface Endpoints | SSM, SSMMessages, EC2Messages, ECR API, ECR DKR, EKS, STS, CloudWatch Logs |
| VPC Gateway Endpoint | S3 (required for ECR image layer pulls) |
| EKS Cluster | Kubernetes 1.32, private-only API endpoint, IRSA via OIDC, core add-ons managed |
| Managed Node Group | AL2023, `t3.2xlarge`, 100 GiB gp3 root volume, 4-6 nodes (`workers-v2`) |
| Bastion Host | AL2023 EC2 in private subnet, SSM-only access, 3proxy SOCKS5 on `localhost:1080` |
| IRSA IAM Roles | EBS CSI Driver, cert-manager, ExternalDNS, AWS Load Balancer Controller |

The VPC endpoint set is what makes the private cluster design possible. Without them, nodes in private subnets have no path to the AWS APIs they need to register with EKS, pull container images, or write logs. The bastion follows the same principle: it has no public IP and no inbound security group rules. Every access path goes through AWS's control plane rather than the public internet.

## Prerequisites

- Terraform `>= 1.9, < 2.0`
- AWS CLI with credentials for the target account
- `dns-bootstrap` applied and `platform_zone_id` output recorded
- AWS Session Manager plugin installed locally for bastion access (`brew install session-manager-plugin`)

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — at minimum, set platform_zone_id from dns-bootstrap output
terraform init
terraform apply
```

The apply takes 15-20 minutes, the majority of which is the EKS cluster and node group provisioning.

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `us-east-1` | AWS region for all resources |
| `cluster_name` | `eks-demo` | Cluster name, used as a prefix for all named resources |
| `kubernetes_version` | `1.32` | Kubernetes version for the EKS cluster |
| `platform_zone_id` | — | Route53 zone ID for `platform.dspdemos.com`, from dns-bootstrap output |
| `platform_domain` | `platform.dspdemos.com` | Platform domain used by ExternalDNS and cert-manager |
| `vpc_cidr` | `10.0.0.0/16` | CIDR block for the VPC |
| `node_instance_type` | `t3.2xlarge` | EC2 instance type for managed node group workers |
| `node_desired_size` | `4` | Desired number of worker nodes |
| `node_min_size` | `4` | Minimum number of worker nodes |
| `node_max_size` | `6` | Maximum number of worker nodes |
| `common_tags` | see below | Confluent mandatory tags applied to all resources |
| `cflt_keep_until` | *(required)* | Static expiry date tag (YYYY-MM-DD). Set at least one year out. Must be set explicitly to prevent plan drift from computed timestamps. |

> [!WARNING]
> `cflt_keep_until` has no default and must be supplied on every apply — either via `terraform.tfvars`, `-var`, or an environment variable. Using a computed value (e.g. `plantimestamp()`) causes a perpetual diff on every `terraform plan`.

## Outputs

Once applied, `terraform output -json` produces everything downstream tasks need. The most commonly referenced outputs are:

| Output | Used by |
|--------|---------|
| `cluster_name` | `aws eks update-kubeconfig`, GitOps overlays |
| `cluster_endpoint` | kubeconfig, debugging |
| `cluster_oidc_issuer_url` | IRSA trust policy verification |
| `oidc_provider_arn` | IRSA IAM role trust policies |
| `bastion_instance_id` | SSM session commands |
| `cert_manager_role_arn` | cert-manager Helm values / ServiceAccount annotation |
| `external_dns_role_arn` | ExternalDNS Helm values / ServiceAccount annotation |
| `aws_lb_controller_role_arn` | AWS LB Controller Helm values / ServiceAccount annotation |
| `ebs_csi_driver_role_arn` | EBS CSI Driver add-on configuration |

Save the full JSON output to a scratch file after apply for reference during GitOps overlay configuration:

```bash
terraform output -json > ../../z_scratch/eks-demo-tf-outputs.json
```

## Accessing the cluster

<!-- Content in this section intentionally duplicated between this README.md and `clusters/eks-demo/README.md` -->

> [!IMPORTANT]
> Pay attention to this section if you want to be able to access your cluster!

Because the EKS API endpoint is private-only, `kubectl` requires a SOCKS5 tunnel through the bastion. The bastion runs `3proxy` (built from source at boot) and listens on `127.0.0.1:1080`. SSM Session Manager port-forwarding exposes that port to your local machine without requiring a public IP, SSH keys, or an open inbound security group rule.

### Starting the tunnel

In a dedicated terminal that you leave running for the duration of your session:

```bash
BASTION_ID=$(terraform output -raw bastion_instance_id)

aws ssm start-session \
  --target $BASTION_ID \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["1080"],"localPortNumber":["1080"]}' \
  --region us-east-1
```

### Configuring kubectl

In a separate terminal, configure your kubeconfig and route traffic through the tunnel:

```bash
aws eks update-kubeconfig --name eks-demo --region us-east-1
export HTTPS_PROXY=socks5://localhost:1080
kubectl get nodes
```

At this point you should see your managed nodes in `Ready` state. Every subsequent `kubectl` command in that terminal will route through the tunnel as long as `HTTPS_PROXY` is set.

### Shutting down the tunnel

When you are done with your session, unset the proxy variable before closing the tunnel so that any subsequent AWS CLI or `kubectl` commands in that terminal do not attempt to route through a closed port:

```bash
unset HTTPS_PROXY
unset HTTP_PROXY
```

Then terminate the SSM session by pressing `Ctrl+C` in the tunnel terminal, or explicitly via:

```bash
aws ssm terminate-session \
  --session-id <session-id-from-start-session-output> \
  --region us-east-1
```

If you need to find an active session ID after the fact:

```bash
aws ssm describe-sessions --state Active --region us-east-1 \
  --query 'Sessions[].{id:SessionId,target:Target,start:StartDate}' \
  --output table
```

### Browser access via FoxyProxy

Cluster UIs (ArgoCD, Confluent Control Center, etc.) are accessible through a browser configured to use the SOCKS5 tunnel. FoxyProxy is the recommended browser extension for this. Configure a SOCKS5 proxy rule for `*.platform.dspdemos.com` pointing to `localhost:1080`. When you are done, disable the pattern or switch FoxyProxy back to direct connection. FoxyProxy does not modify system-level proxy settings, so no other cleanup is needed.

## Design decisions

- **Private-only API endpoint:** Exposing the Kubernetes API publicly is unnecessary for a demo cluster and introduces attack surface that requires ongoing management. The SSM+SOCKS5 pattern provides equivalent developer access without it.

- **3proxy built from source:** Amazon Linux 2023 does not include 3proxy in its default package repositories. Building from a pinned release tag at boot produces a deterministic result regardless of repository availability. The build is gated by an explicit binary check that fails loudly if the build does not succeed, rather than leaving the bastion in an ambiguous state.

- **Single NAT Gateway:** A production deployment would use one NAT Gateway per availability zone for resilience. For a demo cluster where cost is a concern and the NAT Gateway is only used for initial software installation at node boot time, a single NAT Gateway is sufficient.

- **KMS encryption disabled:** This cluster is intended to be destroyed and recreated frequently. A KMS key enters a 10-day pending deletion window when the cluster is destroyed, which blocks a same-named cluster from being recreated during that window. For a cluster running production RBAC secrets, enable `create_kms_key = true` and set `encryption_config = { resources = ["secrets"] }`.
