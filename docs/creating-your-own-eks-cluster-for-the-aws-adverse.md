# Creating Your Own EKS Cluster for the AWS-Adverse

> [!WARNING]
> This walkthrough is under active development. Any issues found while using it should be referred to the author.

This guide covers the complete path from nothing to a fully deployed cluster running the entire Confluent Platform and Flink stack — using `eks-demo` as the template and a new cluster named `new-eks-cluster` as the destination. By the end, you will have provisioned real AWS infrastructure via Terraform, tunneled into a private EKS cluster over AWS Systems Manager, generated a full GitOps configuration, and deployed everything through ArgoCD.

The example cluster name throughout this guide is `new-eks-cluster`, deployed under `platform.dspdemos.com`. Everywhere you see `new-eks-cluster`, substitute your actual cluster name before running the command.

## What This Guide Covers

This is intentionally self-contained. It does not assume you have read any other documentation in this repository, though it does assume you are comfortable enough with AWS to manage credentials via `assume`, and that you understand the general shape of things like IAM roles and VPCs without needing a primer. What it does not assume is that you want to spend more time in the AWS console than strictly necessary.

The guide proceeds in four parts:

1. **Provision** — copy and apply the Terraform configuration to create the EKS cluster and its supporting AWS resources
2. **Access** — connect to the private cluster endpoint via an SSM-based SOCKS5 tunnel
3. **Configure** — generate the GitOps structure and wire in the values from Terraform's outputs
4. **Deploy** — bootstrap ArgoCD and bring up the full stack

## Prerequisites

Install the required tools:

```bash
brew install terraform awscli kubectl kubectx
brew install --cask session-manager-plugin
```

> [!NOTE]
> `session-manager-plugin` is the AWS Systems Manager Session Manager plugin for the AWS CLI. It is a separate install from `awscli` and is required for the SSM tunnel that provides `kubectl` access to the private EKS API endpoint. Without it, `aws ssm start-session` will fail silently.

You will also need:

- `assume` configured for the Confluent Commercial AWS organization
- Access to the `confluent-platform-gitops-tfstate` S3 bucket and `confluent-platform-gitops-tflock` DynamoDB table _(ask if you do not have it)_
- This repository cloned locally, with your working directory at the repository root

---

## Part 1: Provision the AWS Infrastructure

### 1. Authenticate with AWS

Use `assume` to authenticate against the Confluent Commercial AWS organization with a role that has permissions for EKS, EC2, VPC, IAM, and Route53:

```bash
assume <your-role>
```

Verify your session is active before proceeding:

```bash
aws sts get-caller-identity
```

Keep this session in mind throughout — the SSM tunnel in Part 2 will fail silently if your credentials expire while the tunnel is running.

### 2. Create the Terraform Configuration

The cleanest starting point is a direct copy of the `eks-demo` Terraform root. It already has the right module reference, backend configuration, and provider setup — the only things that need to change are the state key and your cluster-specific variable values.

From the repository root:

```bash
cp -r terraform/clusters/eks-demo terraform/clusters/new-eks-cluster
rm -rf terraform/clusters/new-eks-cluster/.terraform
rm -f terraform/clusters/new-eks-cluster/.terraform.lock.hcl
```

The `.terraform` directory and lock file are machine-local artifacts from whoever last ran the `eks-demo` configuration. Removing them ensures you initialize cleanly against the new state path.

### 3. Update the Backend Key

Open `terraform/clusters/new-eks-cluster/main.tf` and change the `key` in the S3 backend block:

```hcl
backend "s3" {
  bucket         = "confluent-platform-gitops-tfstate"
  key            = "new-eks-cluster/terraform.tfstate"   # change from eks-demo
  region         = "us-east-1"
  encrypt        = true
  dynamodb_table = "confluent-platform-gitops-tflock"
}
```

This is the single most important change in the Terraform configuration. Every cluster must have its own unique state key — reusing `eks-demo/terraform.tfstate` would cause Terraform to read and overwrite the existing cluster's infrastructure state.

### 4. Configure the Cluster Variables

Copy the example variables file:

```bash
cp terraform/clusters/new-eks-cluster/terraform.tfvars.example \
   terraform/clusters/new-eks-cluster/terraform.tfvars
```

Edit `terraform.tfvars` with your cluster-specific values:

```hcl
aws_region         = "us-east-1"
cluster_name       = "new-eks-cluster"
kubernetes_version = "1.32"
platform_zone_id   = "Z09738543N152CE54R8TI"   # see note below
platform_domain    = "platform.dspdemos.com"
vpc_cidr           = "10.X.0.0/16"             # see note below
node_instance_type = "t3.2xlarge"
node_desired_size  = 4
node_min_size      = 4
node_max_size      = 6
cflt_keep_until    = "YYYY-MM-DD"              # one year from today
```

> [!WARNING]
> **Set `platform_zone_id = "Z09738543N152CE54R8TI"`** — this is the Route53 zone ID for `platform.dspdemos.com` (same for all clusters). Do not leave placeholder text like `<output from dns-bootstrap: platform_zone_id>`. Terraform will succeed but cert-manager and ExternalDNS will fail later with `AccessDenied`. If you already ran `terraform apply` with a placeholder, fix the value and run `terraform apply` again.

**`platform_zone_id`** — This is the Route53 hosted zone ID for `platform.dspdemos.com`. You can copy it directly from `terraform/clusters/eks-demo/terraform.tfvars` where it is already set, or ask Rick Osowski if that file is not available to you.

**`vpc_cidr`** — Choose a `/16` CIDR block that does not overlap with any other cluster in this repository. To see what is already in use:

```bash
grep vpc_cidr terraform/clusters/*/terraform.tfvars
```

If `eks-demo` (at `10.0.0.0/16`) is the only existing cluster, `10.1.0.0/16` is a safe choice. If there are others, increment the second octet accordingly.

**`cflt_keep_until`** — Set this to one year from today in `YYYY-MM-DD` format. Resources without a valid keep-until date are subject to automated cleanup.

### 5. Initialize and Apply Terraform

> [!NOTE]
> The EKS API endpoint is configured as **private-only**. You will not be able to reach it directly from your local machine once `apply` completes. All `kubectl` access requires the SSM tunnel covered in Part 2.

From inside the new cluster directory:

```bash
cd terraform/clusters/new-eks-cluster
terraform init
terraform plan
terraform apply
```

`terraform init` connects to the S3 backend and downloads the `eks-cluster` module. `terraform plan` shows every resource that will be created — a new VPC, subnets across three availability zones, a NAT gateway, VPC interface endpoints for SSM and ECR, an EKS control plane, a managed node group, a bastion host, and four IRSA IAM roles. `terraform apply` provisions all of it.

The full apply takes approximately 15–20 minutes, the majority of which is waiting for the EKS control plane to become available. This is normal.

> [!WARNING]
> **If you applied Terraform with placeholder values** (like `platform_zone_id = "<output from dns-bootstrap...>"`), fix the value in `terraform.tfvars` and run `terraform apply` again. Terraform will update the IAM policies without recreating other resources.

### 6. Capture the Terraform Outputs

Once `apply` completes, print the outputs — you will need these values in Part 3:

```bash
terraform output
```

Hold on to the following:

| Output | Where it goes |
|--------|---------------|
| `bastion_instance_id` | SSM tunnel target in the next step |
| `cluster_name` | `aws eks update-kubeconfig` in the next step |
| `vpc_id` | `infrastructure/aws-load-balancer-controller/overlays/new-eks-cluster/values.yaml` |
| `ebs_csi_driver_role_arn` | `infrastructure/aws-ebs-csi-driver/overlays/new-eks-cluster/values.yaml` |
| `cert_manager_role_arn` | `infrastructure/cert-manager/overlays/new-eks-cluster/values.yaml` |
| `external_dns_role_arn` | `infrastructure/external-dns/overlays/new-eks-cluster/values.yaml` |
| `aws_lb_controller_role_arn` | `infrastructure/aws-load-balancer-controller/overlays/new-eks-cluster/values.yaml` |

---

## Part 2: Access the Cluster

The EKS control plane in this repository is intentionally private — there is no public endpoint, no open inbound security group rules, and no SSH keys to manage. All access runs through a bastion host that is only reachable via AWS Systems Manager Session Manager. The bastion runs a SOCKS5 proxy on port 1080 that forwards traffic to the private EKS API.

You will need two terminal windows for this section: one to keep the tunnel alive, and one to run `kubectl` commands.

### 7. Start the SSM Tunnel

> [!IMPORTANT]
> Every new terminal session you open for `kubectl` work requires both the tunnel created here to be running and `HTTPS_PROXY=socks5://localhost:1080` to be exported. If you are doing extended work across multiple sessions, consider adding the export to a shell alias or a local `.envrc` file for the repository directory.

In your first terminal, from `terraform/clusters/new-eks-cluster`:

```bash
aws ssm start-session \
  --target $(terraform output -raw bastion_instance_id) \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["1080"],"localPortNumber":["1080"]}'
```

Leave this running. It forwards port 1080 on your local machine to the SOCKS5 proxy on the bastion, which in turn routes traffic to the private EKS API endpoint. If the command exits immediately or times out at connection without producing any output, verify your `assume` session is still active with `aws sts get-caller-identity`.

### 8. Configure kubectl and Set the Proxy

> [!WARNING]
> `HTTPS_PROXY=socks5h://localhost:1080` must be exported in every terminal session where you run `kubectl` against this cluster. The EKS API endpoint is private and unreachable without it. If you open a new terminal and `kubectl` commands hang or time out, this is the first thing to check.

In your second terminal, from `terraform/clusters/new-eks-cluster`:

```bash
aws eks update-kubeconfig \
  --name $(terraform output -raw cluster_name) \
  --region us-east-1

export HTTPS_PROXY=socks5h://localhost:1080
```

> [!NOTE]
> The `h` in `socks5h://` forces DNS resolution through the proxy. Without it, your machine tries to resolve the private EKS hostname locally and fails.

Verify you can reach the cluster:

```bash
kubectl get nodes
```

You should see four nodes in `Ready` state. If `kubectl` times out, the tunnel from Step 7 is either not running or has dropped — check the first terminal.

---

## Part 3: Set Up the GitOps Structure

With infrastructure running and accessible, the next step is creating the GitOps cluster configuration. This is where you stop thinking in AWS terms and start thinking in ArgoCD Applications and Kustomize overlays. Return to the repository root before continuing.

```bash
cd ~/git/confluent/confluent-platform-gitops   # or wherever your repo lives
```

### 9. Clone the Cluster Configuration

Run `clone-cluster.sh` to generate the full GitOps structure for the new cluster:

```bash
./scripts/clone-cluster.sh eks-demo new-eks-cluster
```

This copies `clusters/eks-demo/` to `clusters/new-eks-cluster/` and creates a matching `overlays/new-eks-cluster/` directory under every infrastructure and workload application that `eks-demo` has enabled. All references to `eks-demo` are replaced with `new-eks-cluster` throughout. The domain (`platform.dspdemos.com`) is carried over unchanged since you are deploying under the same hosted zone.

When the script finishes, it prints an **AUDIT REQUIRED** section listing every file that contains values which were mechanically renamed but still point to `eks-demo`'s actual AWS infrastructure. Work through each category in the steps below.

### 10. Update the IRSA Role ARNs

Four IAM roles were created by Terraform in Step 5, one for each AWS-integrated cluster component. The clone script renamed the role references (they now end in `new-eks-cluster`) but could not know the actual ARNs that Terraform just assigned. Replace the placeholder ARNs with the real outputs from Step 6.

> [!WARNING]
> **Verify you are using the correct role ARN for each component.** Copy-paste errors (like using the ExternalDNS role for the EBS CSI driver) will cause failures with `no EC2 IMDS role found` or `AccessDenied`. Double-check the role name in each ARN matches the component.

**`infrastructure/aws-ebs-csi-driver/overlays/new-eks-cluster/values.yaml`**

```yaml
controller:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: <ebs_csi_driver_role_arn>
```

Must be nested under `controller:`. If `serviceAccount:` is at root level, the annotation won't apply.

**`infrastructure/cert-manager/overlays/new-eks-cluster/values.yaml`**

```yaml
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: <cert_manager_role_arn>
```

**`infrastructure/external-dns/overlays/new-eks-cluster/values.yaml`**

```yaml
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: <external_dns_role_arn>
```

**`infrastructure/aws-load-balancer-controller/overlays/new-eks-cluster/values.yaml`**

```yaml
clusterName: new-eks-cluster-eks-cluster
region: <aws_region from terraform.tfvars>
vpcId: <vpc_id>
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: <aws_lb_controller_role_arn>
```

**`clusterName` must be the full EKS cluster name** (`new-eks-cluster-eks-cluster`), not just `new-eks-cluster`. Verify with `terraform output cluster_name`. Mismatch causes `unable to resolve at least one subnet` errors.

### 11. Update the Route53 Hosted Zone ID

cert-manager uses Route53 DNS-01 challenges to issue Let's Encrypt certificates for every service endpoint. The hosted zone ID appears twice in `infrastructure/cert-manager-resources/overlays/new-eks-cluster/letsencrypt-cluster-issuers.yaml` — once for the staging issuer and once for production.

Since all clusters in this repository deploy under `platform.dspdemos.com`, the zone ID is the same for every cluster. Copy it from `terraform/clusters/eks-demo/terraform.tfvars` (`platform_zone_id`) or directly from the existing overlay at `infrastructure/cert-manager-resources/overlays/eks-demo/letsencrypt-cluster-issuers.yaml`. Replace both occurrences in the new cluster's file, in necessary.

### 12. Review the Remaining Audit Items

With the ARNs, VPC ID, and hosted zone ID updated, the infrastructure-critical values are covered. The audit report also flagged the following categories, which require a decision rather than a direct replacement:

**Keycloak / OAuth Issuer Endpoints** — The cluster name embedded in these URLs was renamed correctly by the clone script. No action is needed unless you are intentionally changing the Keycloak realm name or domain from what `eks-demo` uses.

**Architecture-Specific Container Images** — The Flink workload images are currently pinned to `amd64`. EKS managed node groups using `t3.2xlarge` run on x86\_64, so these work without changes. If you chose a Graviton (`t4g` or `m7g`) instance type, update the image tags in `workloads/flink-resources-rbac/overlays/new-eks-cluster/` to their `arm64` equivalents.

**Plain-Text Kubernetes Secrets** — These are demonstration credentials cloned from `eks-demo`. They are acceptable for a non-production demonstration cluster. Do not reuse them in any environment that requires credential isolation between deployments.

**Load Balancer Annotations** — Review `infrastructure/traefik/overlays/new-eks-cluster/values.yaml` and confirm the `cflt_service` annotation reflects your cluster's identity. The clone script will have updated it, but it is worth verifying before the NLB is provisioned.

### 13. Commit and Push

> [!NOTE]
> This repository uses Airlock. Use `git push-external` instead of `git push` when pushing to the remote — standard `git push` will be blocked.

Stage and commit the new cluster configuration from the repository root:

```bash
git add clusters/new-eks-cluster/
git add infrastructure/
git add workloads/
git commit -m "feat: add new-eks-cluster GitOps configuration"
git push-external
```

---

## Part 4: Deploy the Stack

Return to the terminal where you set `HTTPS_PROXY` in Step 8. All `kubectl` commands below require the SSM tunnel from Step 7 to be running.

### 14. Install ArgoCD

```bash
kubectl create namespace argocd

kubectl apply \
  --namespace argocd \
  --server-side \
  --force-conflicts \
  --filename https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Wait for all ArgoCD pods to be ready before proceeding:

```bash
kubectl wait pods \
  --namespace argocd \
  --all \
  --for=condition=Ready \
  --timeout=300s
```

### 15. Apply the Bootstrap

```bash
kubectl apply --filename ./clusters/new-eks-cluster/bootstrap.yaml
```

This creates a single ArgoCD `Application` named `bootstrap` that points ArgoCD at your cluster's configuration directory in the Git repository. From there, ArgoCD takes over: it creates the `infrastructure` and `workloads` parent Applications, which in turn deploy every configured component automatically — cert-manager, ExternalDNS, Traefik, MinIO, the Confluent and Flink operators, Keycloak, and everything else defined in the cluster configuration.

### 16. Retrieve the ArgoCD Admin Password

```bash
kubectl get secret \
  --namespace argocd \
  argocd-initial-admin-secret \
  --output jsonpath='{.data.password}' | base64 -d | pbcopy
```

### 17. Configure FoxyProxy

> [!NOTE]
> This is a one-time setup. Once the pattern is saved, FoxyProxy will apply it automatically whenever the tunnel is active, for this cluster and any future cluster deployed under `platform.dspdemos.com`.

The service URLs that ExternalDNS registers in Route53 — ArgoCD, Control Center, Grafana, and the rest — resolve to the cluster's internal AWS Network Load Balancer. That NLB is not publicly reachable. The same SOCKS5 tunnel you opened in Step 7 for `kubectl` access can carry browser traffic too, but your browser will not use it unless you tell it to.

[FoxyProxy](https://getfoxyproxy.org/) is a browser extension that routes traffic matching a URL pattern through a configured proxy, leaving everything else unaffected. Install it for your browser of choice:

- **Chrome / Arc / Brave**: [FoxyProxy Standard](https://chromewebstore.google.com/detail/foxyproxy/gcknhkkoolaabfmlnjonogaaifnjlfnp) from the Chrome Web Store
- **Firefox**: [FoxyProxy Standard](https://addons.mozilla.org/en-US/firefox/addon/foxyproxy-standard/) from Firefox Add-ons

Once installed, open the FoxyProxy options and add a new proxy with the following settings:

| Field | Value |
|-------|-------|
| Type | SOCKS5 |
| Hostname | `127.0.0.1` |
| Port | `1080` |

Then add a URL pattern that routes all `platform.dspdemos.com` traffic through that proxy:

| Field | Value |
|-------|-------|
| Pattern | `*.platform.dspdemos.com` |
| Type | Wildcard |
| Proxy | _(the SOCKS5 entry you just created)_ |

> [!WARNING]
> **Ensure no other proxy patterns overlap with `*.platform.dspdemos.com`.** If multiple proxy configurations are active with conflicting patterns, connections may route through the wrong proxy or fail. Disable other proxy patterns or use FoxyProxy's "Proxy by Patterns" mode and verify `*.platform.dspdemos.com` routes to the correct SOCKS5 proxy.

With this in place, your browser will automatically route any request to `*.platform.dspdemos.com` through the tunnel while leaving the rest of your browsing unaffected. The tunnel from Step 7 must be running for the browser to reach the services — FoxyProxy only handles the routing, not the connection itself.

### 18. Access ArgoCD

ArgoCD is exposed through Traefik with a Let's Encrypt certificate. Once the `infrastructure` Applications have synced and the ingress is healthy:

- URL: `https://argocd.new-eks-cluster.platform.dspdemos.com`
- Username: `admin`
- Password: paste from clipboard (copied in the previous step)

You should see the `bootstrap`, `infrastructure`, and `workloads` Applications syncing. Infrastructure components deploy first in sync-wave order — cert-manager, ExternalDNS, Traefik, then the storage and monitoring stack — followed by the Confluent and Flink workloads. The full stack takes approximately 10–15 minutes to reach a fully healthy state after the bootstrap is applied.

### 19. Deploy Confluent and Flink Resources

The `confluent-resources` and `flink-resources-rbac` Applications are intentionally not configured for automatic sync. They depend on the Confluent and Flink operators being fully ready and the Keycloak realm being initialized before their resources can be applied successfully. Once the `workloads` Application shows as `Healthy`:

1. In the ArgoCD UI, click on the `confluent-resources` Application, then click **Sync** → **Synchronize**. Wait for it to reach a `Healthy` status before proceeding.

2. Click on the `flink-resources-rbac` Application, then click **Sync** → **Synchronize**. Wait for it to reach a `Healthy` status.

---

## Part 5: Tear Down the Cluster

### 20. Destroy the AWS Infrastructure

When you are done with the cluster, `terraform destroy` will remove everything Terraform provisioned — the EKS control plane, node group, VPC, bastion host, NAT gateway, IRSA roles, and all associated resources.

Before running the destroy, close the SSM tunnel terminal from Step 7. This is important enough to explain in full.

>Terraform destroys resources in reverse dependency order. The bastion host is not the last thing to go, but it is not the first either. At some point mid-destroy, the EC2 instance backing the bastion gets terminated. The moment that happens, the SSM Session Manager plugin detects that the target is gone and exits the tunnel process with an error along the lines of:
>
>```
>An error occurred (TargetNotConnected) when calling the StartSession operation
>```
>
>If the tunnel terminal is in the background or you are not watching it, this looks indistinguishable from a Terraform failure. It is not — `terraform destroy` communicates with the AWS API directly, which is a public endpoint that does not route through your SOCKS5 proxy. The destroy will complete successfully regardless of what happens to the tunnel.
>
>The second trap is if you have `HTTPS_PROXY=socks5://localhost:1080` still set in a terminal and you try to check on the cluster's state after the bastion disappears but before the EKS control plane is removed. Every `kubectl` command will hang until it times out, because the proxy it is pointing at no longer exists. This is not a sign that anything is wrong with the destroy. Closing the tunnel terminal before starting `terraform destroy` eliminates both the alarming error message and the temptation to run `kubectl` commands that will never complete.

With the tunnel closed and **triple-confirmation** that you are attempting to destroy YOUR cluster:

```bash
cd terraform/clusters/new-eks-cluster
terraform destroy
```

Terraform handles the resource dependency sequencing automatically. The full destroy takes approximately 15–20 minutes, mirroring the apply duration. When it completes, all AWS resources for the cluster are gone and the state file in S3 will reflect an empty configuration.

---

## Access Your Services

All services are exposed through Traefik at subdomains of `new-eks-cluster.platform.dspdemos.com`. ExternalDNS automatically registers DNS records in Route53 as each service's IngressRoute and Certificate become available — no `/etc/hosts` configuration is required.

| Service | URL | Username | Password |
|---------|-----|----------|----------|
| ArgoCD | `https://argocd.new-eks-cluster.platform.dspdemos.com` | `admin` | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" \| base64 -d` |
| Confluent Control Center | `https://controlcenter.new-eks-cluster.platform.dspdemos.com` | `admin@dspdemos.com` | `admin123` |
| Grafana | `https://grafana.new-eks-cluster.platform.dspdemos.com` | `admin` | `prom-operator` |
| Prometheus | `https://prometheus.new-eks-cluster.platform.dspdemos.com` | — | — |
| Alertmanager | `https://alertmanager.new-eks-cluster.platform.dspdemos.com` | — | — |
| MinIO Console | `https://s3-console.new-eks-cluster.platform.dspdemos.com` | — | — |
| Keycloak Admin Console | `https://keycloak.new-eks-cluster.platform.dspdemos.com` | `flink-admin` | `admin123` |
| CMF | `https://cmf.new-eks-cluster.platform.dspdemos.com` | — | — |

> [!NOTE]
> **Keycloak has two sets of credentials:**
> 
> - **Keycloak Admin Console** (`/admin`): Use `flink-admin` / `admin123` to manage realms and OIDC clients.
> - **Confluent Platform services** (Control Center, CMF, etc.): Use `admin@dspdemos.com` / `admin123` to log in via SSO. This is a user in the `confluent` Keycloak realm, not the Keycloak admin account.
> 
> Logging in to Control Center with `flink-admin` will fail with `user_not_found` — that account only exists as a Keycloak administrator.
