# eks-demo Cluster

## Overview

The `eks-demo` cluster is a fully operational Confluent Platform + Flink deployment on AWS EKS with private-only access.

- **Kafka Cluster**: KRaft-based Kafka with Schema Registry, managed by Confluent for Kubernetes (CFK)
- **Flink Integration**: Apache Flink via Confluent Manager for Apache Flink (CMF) and Flink Kubernetes Operator
- **Monitoring**: Prometheus, Grafana, and Alertmanager with pre-configured dashboards
- **Security**: OIDC-based RBAC via Keycloak, Let's Encrypt TLS via cert-manager (DNS-01/Route53 IRSA)
- **Networking**: Traefik on an internal AWS NLB; wildcard DNS via ExternalDNS → Route53; private-only access via SSM+SOCKS5 bastion

**Domain**: `*.eks-demo.platform.dspdemos.com`

## Prerequisites

- All AWS infrastructure must be provisioned before deploying this cluster.
- Access to the `AWS Commercial` account via Okta Dashboard.
- `assume` setup locally to resolve `aws` CLI commands successfully.

### Step 1: DNS Bootstrap

```bash
cd terraform/dns-bootstrap
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your root_domain and tags
terraform init && terraform apply
# Note the output: platform_zone_id and root_zone_name_servers
```

Set the `root_zone_name_servers` values at your domain registrar for `dspdemos.com`. This is a one-time step.

### Step 2: EKS Cluster

```bash
cd terraform/eks-demo
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set platform_zone_id from dns-bootstrap output
terraform init && terraform apply
```

See [`terraform/eks-demo/README.md`](../../terraform/eks-demo/README.md) for full variable reference and outputs.

### Step 3: Configure kubectl (run locally)

The EKS Kubernetes API is private — not reachable from the internet. All kubectl traffic must route through the SOCKS5 bastion tunnel. Run these commands on your local machine, not on the bastion.

```bash
# Update local kubeconfig (calls the public EKS management API — no tunnel needed)
aws eks update-kubeconfig --region us-east-1 --name eks-demo

# Start the SOCKS5 tunnel (keep this running in a separate terminal)
aws ssm start-session \
  --region us-east-1 \
  --target $(terraform -chdir=terraform/eks-demo output -raw bastion_instance_id) \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["1080"],"localPortNumber":["1080"]}'

# Route kubectl through the tunnel (in your working terminal)
export HTTPS_PROXY=socks5://localhost:1080
kubectl get nodes  # Expected: 2+ nodes in Ready state
```

> [!TIP]
> Add `HTTPS_PROXY=socks5://localhost:1080` to your shell profile or a `.envrc` file in this repo so it's set automatically whenever the tunnel is active.

## Getting Started

### Install ArgoCD

ArgoCD must be installed manually before the bootstrap Application can be applied.

With the SOCKS5 tunnel running and `HTTPS_PROXY` set (see Prerequisites Step 3):

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
kubectl wait --namespace argocd \
  --for=condition=Ready pods \
  --selector=app.kubernetes.io/name=argocd-application-controller \
  --timeout=300s
```

### Configure IRSA Role ARNs

Several infrastructure components use IRSA (IAM Roles for Service Accounts) for AWS API access. Fill in the role ARNs from Terraform before deploying:

```bash
# Get all IRSA role ARNs from Terraform output
terraform -chdir=terraform/eks-demo output ebs_csi_driver_role_arn
terraform -chdir=terraform/eks-demo output cert_manager_role_arn
terraform -chdir=terraform/eks-demo output external_dns_role_arn
terraform -chdir=terraform/eks-demo output aws_lb_controller_role_arn
```

Update the placeholder in `infrastructure/aws-ebs-csi-driver/overlays/eks-demo/values.yaml`:

```yaml
controller:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: <paste ebs_csi_driver_role_arn output here>
```

### Deploy Bootstrap

```bash
kubectl apply -f clusters/eks-demo/bootstrap.yaml
```

### Verify Deployment

```bash
kubectl get application bootstrap -n argocd
kubectl get applications -n argocd
kubectl get applications -n argocd -w
```

### Manual Sync Applications

Some applications require manual sync to ensure operators and namespaces are fully ready.

**Wait for operators to be healthy:**

```bash
kubectl wait --namespace operator --for=condition=Ready pods -l app=confluent-operator --timeout=300s
kubectl wait --namespace operator --for=condition=Ready pods -l app.kubernetes.io/name=confluent-for-apache-flink --timeout=300s
kubectl wait --namespace operator --for=condition=Ready pods -l app.kubernetes.io/name=flink-kubernetes-operator --timeout=300s
```

**Sync confluent-resources** (after CFK operator is healthy):

In the ArgoCD UI:
1. Click on `confluent-resources` → **Sync** → **Synchronize**
2. Wait for `Healthy` status (~5-10 minutes)

**Sync flink-resources** (after CMF operator is healthy):

In the ArgoCD UI:
1. Click on `flink-resources` → **Sync** → **Synchronize**
2. Wait for `Healthy` status (~2-3 minutes)

## Environment Access

<!-- Content in this section intentionally duplicated between this README.md and `terraform/eks-demo/README.md` -->

All services are private — exposed only within the VPC. Access from your laptop requires the SOCKS5 proxy tunnel.

### SOCKS5 Proxy Setup

The same SSM tunnel used for kubectl (Prerequisites Step 3) also proxies browser traffic. Once the tunnel is running on `localhost:1080`, configure **FoxyProxy** to route `*.platform.dspdemos.com` through the SOCKS5 proxy:

1. Install the [FoxyProxy browser extension](https://getfoxyproxy.org/) if not already installed.
2. Open FoxyProxy → **Options** → **Proxies** → **Add**.
3. Fill in the proxy entry fields:
   - **Title**: `eks-demo SOCKS5`
   - **Type**: `SOCKS5`
   - **Hostname**: `localhost`
   - **Port**: `1080`
   - Leave **Username** and **Password** blank.
4. Click **Proxy by Patterns** → **Add Pattern**, and set the pattern to `*.platform.dspdemos.com`.
5. Save the proxy entry.
6. In the FoxyProxy toolbar icon, select **Proxy by Patterns** (or enable the `eks-demo SOCKS5` proxy directly).

DNS is managed automatically by ExternalDNS — no `/etc/hosts` entries are needed.

### Services

**ArgoCD UI:**
- **URL**: https://argocd.eks-demo.platform.dspdemos.com
- **Username**: `admin`
- **Password**: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`

**Control Center:**
- **URL**: https://controlcenter.eks-demo.platform.dspdemos.com

**Grafana:**
- **URL**: https://grafana.eks-demo.platform.dspdemos.com
- **Username**: `admin`
- **Password**: `prom-operator`

**Prometheus:**
- **URL**: https://prometheus.eks-demo.platform.dspdemos.com

**Alertmanager:**
- **URL**: https://alertmanager.eks-demo.platform.dspdemos.com

**CMF API:**
- **URL**: https://cmf.eks-demo.platform.dspdemos.com

**MinIO Console:**
- **URL**: https://s3-console.eks-demo.platform.dspdemos.com

**Keycloak** *(added in Task N)*:
- **URL**: https://keycloak.eks-demo.platform.dspdemos.com

## Sharing Access With Other Users

Multiple SEs can use this environment simultaneously. The SSM tunnel and 3proxy are stateless — each person starts their own port-forward session and sets `HTTPS_PROXY` in their own terminal. No coordination required.

The one thing that requires setup is an EKS access entry. Terraform's `enable_cluster_creator_admin_permissions = true` grants cluster-admin only to the IAM identity that ran `terraform apply`. Any other user will authenticate successfully but get `Unauthorized` on API calls.

### Step 1 — Requesting user finds their role ARN

The user requesting access (e.g. bigbird@confluent.io) runs these two commands and shares the resulting ARN with the cluster owner:

```bash
# Get the role name from the active SSO session
ROLE_NAME=$(aws sts get-caller-identity --query Arn --output text | cut -d'/' -f2)

# Resolve the full IAM role ARN including the SSO path prefix
aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text
```

### Step 2 — Cluster owner creates the access entry

The cluster owner (who ran `terraform apply`) runs these commands with the ARN received in step 1:

```bash
SE_ROLE_ARN="<arn-from-requesting-user>"  # e.g. bigbird@confluent.io's role ARN

aws eks create-access-entry \
  --cluster-name eks-demo \
  --principal-arn "$SE_ROLE_ARN" \
  --region us-east-1

aws eks associate-access-policy \
  --cluster-name eks-demo \
  --principal-arn "$SE_ROLE_ARN" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster \
  --region us-east-1
```

Once their access entry is in place, the requesting user follows the same tunnel and kubeconfig steps in [Accessing the cluster](#accessing-the-cluster) as any other user.

## Applications

### Infrastructure Applications

Defined in `clusters/eks-demo/infrastructure/kustomization.yaml`:

- **kube-prometheus-stack-crds** (wave 2) - Prometheus Operator CRDs
- **aws-ebs-csi-driver** (wave 3) - EBS CSI driver and gp3 StorageClass *(added in Task 10)*
- **metrics-server** (wave 5) - Kubernetes Metrics Server
- **aws-load-balancer-controller** (wave 8) - AWS Load Balancer Controller for NLB provisioning *(added in Task 11)*
- **external-dns** (wave 8) - Route53 DNS record management via ExternalDNS *(added in Task N)*
- **traefik** (wave 10) - Ingress controller deployed on internal AWS NLB
- **cert-manager** (wave 20) - TLS certificate management (Let's Encrypt DNS-01 via Route53 IRSA)
- **kube-prometheus-stack** (wave 20) - Monitoring stack (Prometheus, Grafana, Alertmanager)
- **trust-manager** (wave 30) - CA certificate distribution
- **reflector** (wave 40) - Secret/ConfigMap replication across namespaces
- **cert-manager-resources** (wave 75) - ClusterIssuers for Let's Encrypt staging and production
- **infra-ingresses** (wave 80) - Traefik IngressRoute for ArgoCD UI
- **minio** (wave 85) - Object storage for Flink checkpoints and savepoints
- **argocd-config** (wave 85) - ArgoCD ConfigMap patches for custom health checks

### Workload Applications

Defined in `clusters/eks-demo/workloads/kustomization.yaml`:

- **namespaces** (wave 100) - Namespace definitions
- **keycloak** (wave 102) - Keycloak OIDC provider for MDS RBAC *(added in Task N)*
- **cfk-operator** (wave 105) - Confluent for Kubernetes operator
- **mds-keygen** (wave 107) - MDS token key generation job *(added in Task N)*
- **confluent-resources** (wave 110) - Confluent Platform (KRaft, Kafka, Schema Registry, etc.)
- **workload-ingresses** (wave 110) - Traefik IngressRoutes for workload UIs
- **flink-kubernetes-operator** (wave 116) - Flink Kubernetes Operator
- **observability-resources** (wave 117) - PodMonitors and Grafana dashboards
- **cmf-operator** (wave 118) - Confluent Manager for Apache Flink
- **cmf-operator-secrets** (wave 119) - CMF operator secrets *(added in Task N)*
- **flink-rbac** (wave 119) - Flink RBAC ConfluentRoleBindings *(added in Task N)*
- **flink-resources** (wave 120) - Flink integration resources

## Cluster Specific Use Cases

<!--
Document anything unique to this cluster:
- OIDC/Keycloak SSO flow and realm configuration
- RBAC model for MDS + Flink ConfluentRoleBindings
- Flink checkpoint/savepoint storage layout in MinIO
- Let's Encrypt certificate lifecycle and renewal
- SSM+SOCKS5 bastion access patterns
-->

## Troubleshooting

### ArgoCD Applications Not Syncing

Check parent Application health:

```bash
kubectl get application infrastructure-apps --namespace argocd -o yaml
kubectl get application workloads-apps --namespace argocd -o yaml
```

Verify Application manifests exist:

```bash
ls -la ./clusters/eks-demo/infrastructure/
ls -la ./clusters/eks-demo/workloads/
```

### Pods Not Starting

```bash
kubectl get pods --namespace <namespace> --output wide
kubectl describe pod <pod-name> --namespace <namespace>
kubectl top nodes
kubectl top pods --all-namespaces
```

### Ingress Not Accessible

Verify the SOCKS5 proxy is running and your browser proxy is routing `*.platform.dspdemos.com` through `localhost:1080`.

Check the Traefik NLB is provisioned:

```bash
kubectl get svc -n traefik
# EXTERNAL-IP should show an AWS NLB hostname (*.elb.amazonaws.com)
```

Check ExternalDNS has written Route53 records:

```bash
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns --tail=50
```

Check Traefik IngressRoutes:

```bash
kubectl get ingressroute --all-namespaces
```

### Certificate Issues

```bash
kubectl get certificates --all-namespaces
kubectl get certificaterequests --all-namespaces
kubectl get clusterissuers
kubectl logs -n cert-manager -l app=cert-manager --tail=100
```

Let's Encrypt DNS-01 challenges write TXT records to Route53 via IRSA — check the cert-manager IAM role ARN is correctly annotated on the `cert-manager` ServiceAccount:

```bash
kubectl get sa cert-manager -n cert-manager -o jsonpath='{.metadata.annotations}'
```

### CFK Components Not Deploying

```bash
kubectl logs --namespace operator deployment/confluent-operator --tail=100
kubectl get crd | grep platform.confluent.io
```

### Validation Script

```bash
./scripts/validate-cluster.sh eks-demo --verbose
```

## Cleanup

Destroy Terraform resources in reverse order:

```bash
terraform -chdir=terraform/eks-demo destroy
terraform -chdir=terraform/dns-bootstrap destroy
```

> [!WARNING]
> `terraform destroy` on `eks-demo` deletes the EKS cluster, all node groups, the VPC, bastion, and IRSA roles. Back up or snapshot any persistent data (EBS volumes from PVCs) before destroying.
