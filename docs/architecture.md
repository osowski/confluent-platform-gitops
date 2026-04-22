# Architecture

## Overview

This repository implements GitOps using ArgoCD's **App of Apps** pattern for managing Confluent Platform deployments on Kubernetes. The architecture separates infrastructure components from application workloads, with different RBAC policies for each.

## GitOps Flow

```
Developer commits to Git
         ↓
   GitHub Repository
         ↓
   ArgoCD detects change
         ↓
   ArgoCD syncs to cluster
         ↓
   Kubernetes applies manifests
```

## Directory Structure

### Bootstrap (`bootstrap/`)

The bootstrap Helm chart is the entry point. It creates:
- ArgoCD Project CRDs (infrastructure, workloads)
- Parent Applications (infrastructure, workloads)

**Key files:**
- `Chart.yaml` - Helm chart metadata
- `values.yaml` - Default configuration values
- `templates/argocd-projects.yaml` - Project definitions
- `templates/infrastructure.yaml` - Infrastructure App of Apps
- `templates/workloads.yaml` - Workloads App of Apps

**Cluster-specific bootstrap:**
- `clusters/<cluster>/bootstrap.yaml` - ArgoCD Application that deploys the bootstrap chart
- Uses inline `valuesObject` to specify cluster name and domain
- Deployed with sync-wave `0` (highest priority)

### ArgoCD Projects (`argocd-projects/`)

Standalone Project definitions for reference. These are also created by the bootstrap chart.

**Projects:**
- `infrastructure` - Can create cluster-scoped resources (CRDs, PVs, etc.)
- `workloads` - Namespace-scoped resources only (Deployments, Services, Ingress, etc.)

### Infrastructure (`infrastructure/`)

Platform infrastructure components deployed before workloads.

**Deployed components:**
- **kube-prometheus-stack-crds** (wave 2) - Prometheus Operator CRDs deployed early for availability
- **metrics-server** (wave 5) - Kubernetes Metrics Server for resource metrics and HPA support
- **traefik** (wave 10) - Ingress controller for external access
- **kube-prometheus-stack** (wave 20) - Monitoring stack with Prometheus, Grafana, Alertmanager
- **cert-manager** (wave 20) - TLS certificate management
- **trust-manager** (wave 30) - Automatic distribution of CA certificate trust bundles across namespaces
- **vault** (wave 40) - HashiCorp Vault for secrets management and encryption services
- **vault-ingress** (wave 45) - Traefik IngressRoute for Vault UI access
- **vault-config** (wave 50) - Post-deployment Job to configure transit encryption engine
- **cert-manager-resources** (wave 75) - Self-signed ClusterIssuer and certificate resources
- **argocd-ingress** (wave 80) - Traefik IngressRoute for ArgoCD UI access
- **argocd-config** (wave 85) - ArgoCD ConfigMap patches for custom health checks and configuration

**Deployed workloads:**
- **cfk-operator** (wave 105) - Confluent for Kubernetes (CFK) operator for managing Confluent Platform
- **confluent-resources** (wave 110) - Confluent Platform resources (KRaft, Kafka, Schema Registry, Control Center)
- **controlcenter-ingress** (wave 115) - Traefik IngressRoute for Confluent Control Center UI access
- **flink-kubernetes-operator** (wave 116) - Flink Kubernetes Operator for managing Flink deployments
- **cmf-operator** (wave 118) - Confluent Manager for Apache Flink (CMF) for central Flink management
- **flink-resources** (wave 120) - Flink custom resources (CMFRestClass, FlinkEnvironment) for Kafka integration

**Future components:**
- **argocd** - ArgoCD self-management (currently manual install, future state target)
- **external-dns** - DNS automation

**Structure:**
```
infrastructure/<component>/
├── base/
│   └── values.yaml           # Base Helm values (shared across clusters)
└── overlays/<cluster>/
    └── values.yaml           # Cluster-specific Helm value overrides
```

Infrastructure components use Helm charts from upstream repositories with values files stored in Git.

### Workloads (`workloads/`)

User-facing applications and services.

**Structure:**
```
workloads/<app>/
├── base/              # Base Kubernetes manifests
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── ingress.yaml
└── overlays/          # Cluster-specific overlays
    └── <cluster>/
        ├── kustomization.yaml
        └── *-patch.yaml
```

### Clusters (`clusters/`)

Cluster-specific application instances. Parent Applications watch these directories.

**Structure:**
```
clusters/<cluster>/
├── bootstrap.yaml              # Bootstrap Application (sync-wave 0)
├── infrastructure/
│   ├── kustomization.yaml      # Lists all infrastructure applications
│   └── <app>.yaml              # ArgoCD Application CRDs
└── workloads/
    ├── kustomization.yaml      # Lists all workload applications
    └── <app>.yaml              # ArgoCD Application CRDs
```

The `kustomization.yaml` files serve as an index of applications for each layer and are monitored by the parent Applications.

## Application Hierarchy

```
Bootstrap Application (sync-wave 0)
├── Deploys bootstrap Helm chart
│   ├── ArgoCD Projects (infrastructure, workloads)
│   ├── infrastructure (Parent Application, sync-wave 1)
│   │   └── Watches: clusters/<cluster>/infrastructure/
│   │       ├── kube-prometheus-stack-crds (sync-wave 2)
│   │       ├── traefik (sync-wave 10)
│   │       ├── longhorn (sync-wave 15)
│   │       ├── kube-prometheus-stack (sync-wave 20)
│   │       ├── cert-manager (sync-wave 20)
│   │       ├── trust-manager (sync-wave 30)
│   │       ├── vault (sync-wave 40)
│   │       ├── vault-ingress (sync-wave 45)
│   │       ├── vault-config (sync-wave 50)
│   │       ├── cert-manager-resources (sync-wave 75)
│   │       ├── argocd-ingress (sync-wave 80)
│   │       └── argocd-config (sync-wave 85)
│   └── workloads (Parent Application, sync-wave 100)
│       └── Watches: clusters/<cluster>/workloads/
│           ├── cfk-operator (sync-wave 105)
│           ├── confluent-resources (sync-wave 110)
│           ├── controlcenter-ingress (sync-wave 115)
│           ├── flink-kubernetes-operator (sync-wave 116)
│           ├── cmf-operator (sync-wave 118)
│           ├── flink-resources (sync-wave 120)
│           ├── http-echo (sync-wave 105)
│           └── (future workload applications)
```

Sync waves ensure infrastructure is deployed before workloads, and components deploy in the correct order (e.g., CRDs before resources that use them, cert-manager before certificates).

### Intra-Application Sync Waves: Confluent Resources

Within the `confluent-resources` application (wave 110), individual CFK resources use sync-wave annotations to enforce the correct startup dependency chain:

```
KRaftController (wave 0) → Kafka (wave 10) → SchemaRegistry (wave 20) → ControlCenter (wave 30)
                                            → Connect (wave 20)       ↗
```

| Wave | Resource | CFK Kind | Rationale |
|------|----------|----------|-----------|
| `"0"` | kraft-controller.yaml | KRaftController | No dependencies, must start first |
| `"10"` | kafka-broker.yaml | Kafka | Depends on KRaftController |
| `"10"` | kafkarestclass.yaml | KafkaRestClass | Configuration resource, deploy with Kafka |
| `"20"` | schema-registry.yaml | SchemaRegistry | Depends on Kafka |
| `"20"` | connect.yaml | Connect | Depends on Kafka |
| `"30"` | control-center.yaml | ControlCenter | Depends on Kafka, SchemaRegistry, Connect |
| `"30"` | kafkatopic.yaml | KafkaTopic | Depends on Kafka + KafkaRestClass |

ArgoCD deploys each wave sequentially within the application and waits for resources to become healthy before advancing. Custom Lua health checks in `argocd-cm` evaluate CFK resource `status.state` fields (healthy when `"RUNNING"`). Without these health checks, ArgoCD cannot determine CFK resource health and sync waves would not advance.

See [ADR-0002](../adrs/0002-cfk-component-sync-wave-ordering.md) for the full decision record.

## Sync Policies

### Automated Sync

All applications use automated sync with:
- **Prune**: Remove resources not defined in Git
- **Self-Heal**: Revert manual changes to match Git state

### Sync Options

Common sync options used across applications:
- `CreateNamespace=true` - Automatically create target namespaces
- `ServerSideApply=true` - Used for infrastructure components with CRDs

### Sync Waves

Applications deploy in waves using `argocd.argoproj.io/sync-wave` annotations:

| Wave | Component | Purpose |
|------|-----------|---------|
| 0 | bootstrap | Creates Projects and Parent Applications |
| 1 | infrastructure (parent) | Infrastructure App of Apps |
| 2 | kube-prometheus-stack-crds | Prometheus Operator CRDs for early availability |
| 10 | traefik | Ingress controller for external access |
| 15 | longhorn | Distributed block storage for persistent volumes |
| 20 | kube-prometheus-stack | Monitoring stack (Prometheus, Grafana, Alertmanager) |
| 20 | cert-manager | TLS certificate management |
| 30 | trust-manager | Automatic distribution of CA certificate trust bundles |
| 40 | vault | HashiCorp Vault for secrets management and encryption |
| 45 | vault-ingress | Traefik IngressRoute for Vault UI access |
| 50 | vault-config | Post-deployment Job to configure transit encryption engine |
| 75 | cert-manager-resources | Self-signed ClusterIssuer and certificate resources |
| 80 | argocd-ingress | Traefik IngressRoute for ArgoCD UI access |
| 85 | argocd-config | ArgoCD ConfigMap patches for custom health checks |
| 100 | workloads (parent) | Workloads App of Apps |
| 105 | cfk-operator | Confluent for Kubernetes operator (CRDs and webhooks) |
| 110 | confluent-resources | Confluent Platform resources (KRaft, Kafka, Schema Registry, Control Center, Schema Registry IngressRoute) |
| 115 | controlcenter-ingress | Traefik IngressRoute for Confluent Control Center UI access |
| 116 | flink-kubernetes-operator | Flink Kubernetes Operator (manages Flink deployments and jobs) |
| 118 | cmf-operator | Confluent Manager for Apache Flink (central management interface) |
| 120 | flink-resources | Flink custom resources (CMFRestClass, FlinkEnvironment) for Kafka integration |
| 105+ | workload apps | User-facing applications |

Lower wave numbers deploy first. This ensures dependencies are satisfied (e.g., CRDs before resources that use them, ingress controller before applications with ingress).

## External Access Patterns

### Kafka External Access (flink-demo cluster)

The `flink-demo` cluster uses Kafka NodePort listeners to enable external client access in local kind environments. This configuration is cluster-specific and deployed via Kustomize overlay.

**Architecture:**
- **kind port mapping**: `31000-31002:31000-31002` (3 brokers)
- **CFK listener configuration**: NodePort listener on port 9094 with nodePortOffset 31000
- **Advertised hostname**: `kafka.flink-demo.confluentdemo.local`
- **Bootstrap connection string**: `kafka.flink-demo.confluentdemo.local:31000`

**DNS Resolution:**
Clients must resolve the advertised hostname to localhost. Add to `/etc/hosts`:
```
127.0.0.1 kafka.flink-demo.confluentdemo.local
```

**Implementation:**
- **Base**: `workloads/confluent-resources/base/kafka-broker.yaml` contains cluster-agnostic Kafka configuration
- **Overlay**: `workloads/confluent-resources/overlays/flink-demo/kafka-broker-patch.yaml` adds NodePort listener via strategic merge patch
- **kind cluster**: `clusters/flink-demo/kind-config.yaml` defines extraPortMappings for NodePort range

This pattern keeps the base Kafka configuration reusable across clusters while allowing cluster-specific external access configuration.

### Multi-Tenant RBAC Architecture (flink-demo-rbac cluster)

The `flink-demo-rbac` cluster implements a three-layer authorization model for group-based multi-tenant isolation:

**Layer 1 — Kubernetes RBAC:**
- Namespace isolation: `flink-shapes` (shapes group), `flink-colors` (colors group), plus shared `kafka`, `flink`, `operator` namespaces
- Per-group ServiceAccounts, Roles, and RoleBindings restrict kubectl access to group-specific namespaces
- Kubeconfig generation script (`scripts/generate-kubeconfigs.sh`) creates per-user contexts with scoped credentials

**Layer 2 — OAuth/SSO (Keycloak):**
- Keycloak provides OAuth2/OIDC authentication for all Confluent Platform components
- OAuth clients: `cmf` (CMF operator), `controlcenter` (Control Center OIDC SSO), `kafka` (Kafka broker OAUTHBEARER), `sso` (general SSO)
- 11 demo users across 3 groups: shapes (5 users), colors (5 users), admin (1 user)
- Token lifespan: 604800 seconds (7 days)
- Control Center authenticates via OIDC SSO; users see only their authorized FlinkEnvironments

**Layer 3 — MDS Authorization (ConfluentRoleBindings):**
- Metadata Service (MDS) enforces fine-grained RBAC on Confluent Platform resources
- ConfluentRoleBindings grant `ResourceOwner` and `DeveloperManage` roles scoped to group-specific resources
- Resource scoping: KafkaTopics (`shapes-*`/`colors-*`), Schema Registry subjects, consumer groups, and transactional IDs
- CMF resources (FlinkEnvironments, FlinkApplications, catalogs) are scoped per group via MDS policies

**Key differences from flink-demo:**
- Keycloak replaces anonymous access with authenticated OAuth/OIDC flows
- MDS adds authorization layer (flink-demo uses no RBAC)
- Multiple FlinkEnvironments per group instead of a single shared environment
- MinIO provides S3-compatible storage for Flink checkpoints/savepoints
- Reflector replicates secrets across tenant namespaces

### AWS EKS Architecture (eks-demo cluster)

The `eks-demo` cluster is the first cluster in this repository provisioned on real AWS infrastructure rather than a local kind environment. This distinction matters more than it might seem at first glance — kind clusters assume the cluster already exists and let you jump straight to ArgoCD. eks-demo requires an entirely separate provisioning layer for the cluster itself before ArgoCD can do anything. That provisioning layer lives in `terraform/eks-demo/` and is responsible for the VPC, EKS control plane, managed node groups, IAM roles, bastion host, and all the AWS service endpoints the cluster needs to function in a private network.

**Cluster Access — Private API and SSM+SOCKS5 Tunnel:**

The EKS API endpoint is private-only — there is no public Kubernetes API URL. Every `kubectl` command, every ArgoCD sync, and every Terraform operation that talks to the cluster goes through an AWS SSM Session Manager port-forwarding tunnel to a bastion EC2 instance running 3proxy as a SOCKS5 proxy. The bastion itself has no public IP and no inbound security group rules. This is what makes the design work: AWS's control plane handles all the authentication and authorization before traffic ever reaches your infrastructure.

The practical consequence for operators is that you need to start the tunnel before any cluster interaction:

```bash
aws ssm start-session \
  --target $BASTION_ID \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["1080"],"localPortNumber":["1080"]}'

export HTTPS_PROXY=socks5://localhost:1080
```

Without the tunnel running, `kubectl get nodes` will simply time out — not fail with an auth error, just hang — which can be disorienting the first time you encounter it. See [ADR-0004](../adrs/0004-private-eks-api-ssm-bastion.md) for the full rationale behind this design.

**AWS-Native Ingress (ALB + ExternalDNS + Route53):**

The ingress model for eks-demo is fundamentally different from the kind-based clusters in this repository, which use Traefik with local `.confluentdemo.local` hostnames and `/etc/hosts` entries. On eks-demo, the AWS Load Balancer Controller provisions an Application Load Balancer for each Kubernetes Ingress resource, and ExternalDNS automatically creates Route53 DNS records pointing to those ALBs. TLS certificates are provisioned via ACM and referenced by annotation on the Ingress resources.

The end result is that deploying a new service with an Ingress in eks-demo automatically produces a real public DNS record, a real TLS certificate, and a real load balancer — with no manual AWS console interaction required.

- **Ingress controller**: AWS Load Balancer Controller (sync-wave 25)
- **DNS automation**: ExternalDNS watching for `Ingress` resources and writing A records to Route53 (sync-wave 26)
- **TLS**: ACM certificates referenced via `alb.ingress.kubernetes.io/certificate-arn` annotation
- **Domain pattern**: `<service>.eks-demo.platform.dspdemos.com`

**Storage (EBS CSI Driver):**

eks-demo uses the AWS EBS CSI driver add-on (managed by EKS) for persistent storage rather than Longhorn. EBS volumes are AZ-scoped, which means a pod can only mount a volume from the same availability zone the volume was originally provisioned in. This constraint is worth understanding deeply before draining nodes or resizing nodegroups — rescheduling a stateful pod to a node in a different AZ from its EBS volume will cause the attach to silently fail.

**RBAC and Authorization:**

The eks-demo authorization model mirrors flink-demo-rbac exactly: Keycloak for OAuth/OIDC, MDS for ConfluentRoleBinding enforcement, and group-scoped permissions for `flink-shapes` and `flink-colors`. The same three-layer model applies — see [Multi-Tenant RBAC Architecture (flink-demo-rbac cluster)](#multi-tenant-rbac-architecture-flink-demo-rbac-cluster) for the full breakdown. The key operational difference is that eks-demo runs on real public infrastructure, so OAuth redirect URIs and MDS token issuer URLs reference real DNS hostnames rather than `.local` entries that only resolve in a developer's `/etc/hosts`.

**Key differences from flink-demo-rbac:**
- Cluster infrastructure is provisioned via Terraform (`terraform/eks-demo/`), not assumed to pre-exist — see [ADR-0005](../adrs/0005-terraform-argocd-cluster-provisioning-split.md)
- Private API endpoint requires SSM tunnel for all `kubectl` access; no public endpoint is exposed under any circumstances
- Traefik replaced by AWS Load Balancer Controller; Longhorn replaced by EBS CSI driver
- Route53 + ACM provide real public DNS and TLS instead of self-signed certificates and `/etc/hosts` resolution
- `workers-v2` managed node group (t3.2xlarge, min=4, max=6) spread across 3 availability zones

## RBAC Boundaries

### Infrastructure Project

- **Scope**: Cluster-wide
- **Allowed**: All cluster-scoped and namespace-scoped resources
- **Use case**: Platform components (storage, monitoring, ingress controllers)

### Workloads Project

- **Scope**: Primarily namespace-scoped with limited cluster-scoped permissions
- **Allowed**: Deployments, Services, Ingress, ConfigMaps, Secrets, CRDs (apiextensions.k8s.io), ValidatingWebhookConfigurations, Confluent Platform CRs (platform.confluent.io), Flink CRs (flink.apache.org, flink.confluent.io)
- **Denied**: Most cluster-scoped resources (ClusterRoles, PersistentVolumes, etc.)
- **Use case**: Application workloads including operators that manage CRDs
- **Note**: Enhanced RBAC added for:
  - Confluent for Kubernetes operator (22 CRDs and webhooks)
  - Flink Kubernetes Operator and CMF (FlinkDeployment, FlinkSessionJob, CMFRestClass, FlinkEnvironment, FlinkApplication)

## Naming Conventions

### Hostnames

Pattern: `<service>.<cluster>.<domain>`

Examples:
- `echo.flink-demo.confluentdemo.local`
- `grafana.flink-demo.confluentdemo.local`

### Application Names

- Use lowercase hyphenated names
- Match the directory name in `workloads/` or `infrastructure/`
- Example: `http-echo`, `kube-prometheus-stack`

### Namespace Names

- Generally match the application name
- Infrastructure components may use standard names (e.g., `longhorn-system`, `monitoring`)

## Tool Choices

### Kustomize

Used for:
- Simple applications with minimal customization
- Applications without upstream Helm charts
- Example: http-echo

**Pros**: Simple, no templating, GitOps-friendly
**Cons**: Limited logic, verbose for complex apps

### Helm

Used for:
- Complex infrastructure components
- Applications with many configuration options
- Components with upstream Helm charts
- Example: kube-prometheus-stack, traefik, cert-manager

**Pros**: Rich templating, upstream support, values-based config
**Cons**: More complex, templating can be opaque

**Multi-Source Pattern:**
Infrastructure applications use ArgoCD's multi-source feature to combine:
1. Upstream Helm chart from OCI registry or Helm repository
2. Values files from this Git repository (base + cluster overlay)

Example Application sources:
```yaml
sources:
  - repoURL: oci://ghcr.io/traefik/helm/traefik
    targetRevision: 38.0.2
    chart: traefik
    helm:
      valueFiles:
        - $values/infrastructure/traefik/base/values.yaml
        - $values/infrastructure/traefik/overlays/flink-demo/values.yaml
  - repoURL: https://github.com/osowski/confluent-platform-gitops
    targetRevision: HEAD
    ref: values
```

The `$values` reference points to the Git repository source, allowing values files to be version-controlled separately from the chart.

## Adding a New Application

See [Adding Applications](adding-applications.md) for detailed instructions.

**Quick steps:**
1. Create base manifests in `workloads/<app>/base/` or `infrastructure/<app>/base/`
2. Create cluster overlay in `workloads/<app>/overlays/<cluster>/` or `infrastructure/<app>/overlays/<cluster>/`
3. Create ArgoCD Application in `clusters/<cluster>/workloads/<app>.yaml` or `clusters/<cluster>/infrastructure/<app>.yaml`
4. Add application to `clusters/<cluster>/workloads/kustomization.yaml` or `clusters/<cluster>/infrastructure/kustomization.yaml`
5. Add sync-wave annotation if deployment order matters
6. Commit and push to Git
7. Parent Application automatically discovers and syncs the new application

## Multi-Cluster Support

To add a new cluster:
1. Create `clusters/<cluster>/` directory structure
2. Create `clusters/<cluster>/bootstrap.yaml` with cluster-specific `valuesObject`
3. Create `clusters/<cluster>/infrastructure/kustomization.yaml`
4. Create `clusters/<cluster>/workloads/kustomization.yaml`
5. Add applications to cluster directories
6. Deploy bootstrap Application to the new cluster

Each cluster has independent configuration via its bootstrap.yaml file, which specifies the cluster name and domain.

See [Cluster Onboarding](cluster-onboarding.md) for details.

## Security Considerations

### Secrets Management

**Current**: Secrets are managed manually outside this repository.

**Future**: Consider Sealed Secrets or External Secrets Operator for GitOps-native secret management.

### RBAC

ArgoCD Projects enforce RBAC boundaries:
- Infrastructure project can modify cluster-scoped resources
- Workloads project is restricted to namespace-scoped resources

### Repository Access

- This repository is private
- ArgoCD uses HTTPS with token/password authentication
- Consider using SSH keys or GitHub App for production

## Monitoring and Observability

### ArgoCD UI

Access via port-forward or ingress to view:
- Application sync status
- Resource health
- Sync history and diffs

### kubectl

```bash
# View all applications
kubectl get applications -n argocd

# View application details
kubectl describe application <app-name> -n argocd

# View application logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller
```

## Troubleshooting

### Application Not Syncing

1. Check Application status:
   ```bash
   kubectl get application <app-name> -n argocd
   ```

2. Describe Application for events:
   ```bash
   kubectl describe application <app-name> -n argocd
   ```

3. Check ArgoCD logs:
   ```bash
   kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller
   ```

### Sync Errors

1. View sync status in ArgoCD UI
2. Check resource events in target namespace
3. Verify Kustomize/Helm rendering:
   ```bash
   kubectl kustomize workloads/<app>/overlays/<cluster>/
   # or
   helm template <app> infrastructure/<app>/
   ```

### Parent Application Not Creating Children

1. Verify directory structure matches `path` in parent Application
2. Check that child Application manifests are valid YAML
3. Review parent Application logs for errors

## ArgoCD Self-Management

**Current State:** ArgoCD is manually installed and not yet self-managed via GitOps.

**Future State:** ArgoCD will manage its own deployment and configuration through a dedicated Application manifest. This follows the GitOps principle where ArgoCD:

1. **Initial Bootstrap**: Manually installed via Helm or kubectl (chicken-and-egg requirement)
2. **Self-Management**: ArgoCD Application manifest deploys and manages ArgoCD via the official Helm chart
3. **Declarative Updates**: Configuration changes are made through Git commits, not manual kubectl commands

**Benefits of Future Self-Management:**
- Consistent GitOps workflow for all infrastructure
- Version-controlled ArgoCD configuration
- Automated updates and rollbacks
- Audit trail for all changes

**Current Access:**
- ArgoCD UI accessible via argocd-ingress Application (Traefik IngressRoute)
- Hostname pattern: `argocd.<cluster>.<domain>` (e.g., argocd.flink-demo.confluentdemo.local)
- TLS certificates managed by cert-manager

**Future Implementation Plan:**
- Helm chart: `argo-cd` from `https://argoproj.github.io/argo-helm`
- Base values: `infrastructure/argocd/base/values.yaml`
- Cluster overlays: `infrastructure/argocd/overlays/<cluster>/values.yaml`
- Application manifest: `clusters/<cluster>/infrastructure/argocd.yaml`
- Sync wave: `5` (early deployment, before other infrastructure)
- See [ArgoCD Self-Management Guide](argocd-self-management.md) for transition procedure

## Future Enhancements

- ApplicationSets for multi-cluster templating
- Progressive delivery with Argo Rollouts
- Sealed Secrets or External Secrets Operator
- External DNS automation
- Monitoring and alerting for ArgoCD itself
