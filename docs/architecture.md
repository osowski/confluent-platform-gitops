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
- **vault-config** (wave 50) - Post-deployment Job to configure transit encryption engine
- **headlamp** (wave 50) - Kubernetes dashboard (chart `0.43.0`), namespace `headlamp`, cluster-admin SA; token-based login on all clusters
- **cert-manager-resources** (wave 75) - Self-signed ClusterIssuer and certificate resources
- **infra-ingresses** (wave 80) - Traefik IngressRoutes + cert-manager Certificates for ArgoCD, Vault, and Headlamp UI access
- **argocd-config** (wave 85) - ArgoCD ConfigMap patches for custom health checks and configuration

**Deployed workloads:**
- **cfk-operator** (wave 105) - Confluent for Kubernetes (CFK) operator for managing Confluent Platform
- **confluent-resources** (wave 110) - Confluent Platform resources (KRaft, Kafka, Schema Registry, Control Center)
- **workload-ingresses** (wave 110) - Traefik IngressRoutes for CMF, Confluent Control Center, and Schema Registry UI access
- **flink-kubernetes-operator** (wave 116) - Flink Kubernetes Operator for managing Flink deployments
- **cmf-operator** (wave 118) - Confluent Manager for Apache Flink (CMF) for central Flink management
- **flink-resources** (see [Sync Waves](#sync-waves) for the exact per-cluster wave) - Flink integration resources (CMFRestClass, single `default` FlinkEnvironment, generic Flink SQL demo) for Kafka integration, deployed on all four clusters
- **colors-and-shapes** (see [Sync Waves](#sync-waves) for the exact per-cluster wave) - Two-tenant Flink demo (`shapes-env`, `colors-env`); anonymous on flink-demo, Kubernetes RBAC + OAuth/Keycloak via the `rbac-oauth` Kustomize Component on the RBAC clusters

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
│   │       ├── vault-config (sync-wave 50)
│   │       ├── headlamp (sync-wave 50)
│   │       ├── cert-manager-resources (sync-wave 75)
│   │       ├── infra-ingresses (sync-wave 80)
│   │       └── argocd-config (sync-wave 85)
│   └── workloads (Parent Application, sync-wave 100)
│       └── Watches: clusters/<cluster>/workloads/
│           ├── cfk-operator (sync-wave 105)
│           ├── confluent-resources (sync-wave 110)
│           ├── workload-ingresses (sync-wave 110)
│           ├── flink-kubernetes-operator (sync-wave 116)
│           ├── cmf-operator (sync-wave 118)
│           ├── flink-resources (sync-wave — see Sync Waves table)
│           ├── colors-and-shapes (sync-wave — see Sync Waves table)
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

### Intra-Application Sync Waves: Flink SQL Resources

The CMF Flink SQL object model is expressed as CFK custom resources (CFK 3.3.0+). They form a strict dependency chain, with the `FlinkEnvironment` ahead of it and `FlinkApplication` behind it:

```
FlinkEnvironment
  → FlinkSecret → FlinkEnvironmentSecretMapping → FlinkKafkaCatalog
    → FlinkKafkaDatabase → FlinkComputePool → FlinkStatement
                                                → FlinkApplication
```

Apply in that order and delete in reverse, so each CMF-side resource is removed before the resource it depends on. Sync-wave annotations express both directions, since ArgoCD deletes in reverse wave order.

| App | Wave scheme |
|---|---|
| `flink-resources` | environment 5; application 10; topics 30; schemas 35; catalog 40; database 45; pool 50 (RBAC clusters additionally use waves 10/20/30 for a `default`-env Secret/FlinkSecret/mapping chain via a Kustomize Component — coexists with the reference application at wave 10 since neither depends on the other) |
| `colors-and-shapes` | environment 5; catalog 40; database 50; pool 60; statement 70; application 80 (waves 10/20/30 are reserved for the Secret/FlinkSecret/mapping chain a Kustomize Component adds on RBAC clusters — not present in the anonymous base) |

`FlinkApplication` must come after `FlinkEnvironment` rather than sharing its wave. Unwaved they race, and CFK reports `FlinkEnvironment "<env>" not found` on the application. Without a health check that failure is invisible — ArgoCD marks the application Healthy on creation and CFK retries in the background — but once health is evaluated it fails the sync outright.

The following constraints are enforced by CEL rules on the CRDs or by CMF runtime behaviour, and are easy to trip over:

| Constraint | Consequence |
|---|---|
| `FlinkStatement.spec.statement` is immutable once running | Editing SQL in Git fails the sync **permanently** — see below |
| `FlinkComputePool.spec.type` is immutable | Switching DEDICATED↔SHARED requires a new CR |
| `FlinkComputePool.spec.state` valid only on `SHARED` pools | CEL rejects `state` on a DEDICATED pool |
| `FlinkKafkaCatalog.spec.flinkEnvironment` is required and immutable | Sharing a catalog across environments needs one CR per environment, even though CMF catalogs are global |
| The `FlinkSecret`, its `FlinkEnvironmentSecretMapping`, and the `connectionSecretId`/`connectionSecretRef` that references them must all share **one identical name** | Two mechanisms enforce it: CMF keys an environment's secrets by mapping name and silently ignores an unmapped catalog rather than erroring; and CFK resolves `connectionSecretId` to a `FlinkSecret` resource, failing with `flinksecret "<id>" not found in namespace` on a mismatch |
| DDL (`CREATE TABLE`) runs only in environments listed in the database's `ddlEnvironments` | DDL is rejected everywhere else |
| `clusterSpec.image` must match the deployed CMF version | JobManager fails to load the statement plan |
| `FlinkSecret` requires CMF secret encryption (`encryption.enabled=true`) | Secrets cannot be stored encrypted at rest, so the sync fails |
| CMF encryption mode is fixed at database initialization and the key cannot be rotated | Enabling encryption on an existing CMF database requires a **fresh database** — see [flink-demo-rbac README](../clusters/flink-demo-rbac/README.md#enabling-cmf-secret-encryption-requires-a-fresh-cmf-database) |
| The CMF encryption key must be exactly 16 or 32 bytes | Any other length and CMF fails to start |

#### Changing the SQL of a running FlinkStatement

`FlinkStatement.spec.statement` carries the CEL rule `self.statement == oldSelf.statement || oldSelf.statement == ''`. Once a statement is running, the API server rejects any update that changes the SQL, so editing the manifest in Git makes the ArgoCD sync fail permanently — retrying never succeeds. This is the most likely way to wedge a Flink SQL deployment in this repository, precisely because the normal GitOps workflow is what breaks.

**To change the SQL, create a new CR with a versioned name** (for example `shapes-sql-enrich-v2`) rather than editing in place. Two things that do not help:

- `spec.stopped: true` stops a statement without deleting it, but does not unlock `spec.statement`.
- `argocd.argoproj.io/sync-options: Force=true,Replace=true` forces a delete-and-recreate that passes validation, but silently discards job state.

Versioning the name is preferred: it is explicit, auditable, and leaves the previous statement's history intact.

These CRDs are a **preview feature** in CFK 3.3.0. The decision to adopt them anyway, and the rollback path if the API changes before GA, is recorded in [ADR-0010](../adrs/0010-adopt-cfk-preview-flink-sql-crds.md).

#### Renaming a FlinkSecret deadlocks a live cluster

CMF refuses to delete a secret that an environment still maps:

```
Secret 'sr-oauth-secret-shapes' is still mapped to environments [shapes-env].
Remove those mappings first.
```

Because the `FlinkSecret` sits at wave 20 and its mapping at wave 30, a rename makes the two waves deadlock: wave 20 cannot prune the old secret while the mapping that references it still exists, and the wave that would update that mapping never runs. The old resources sit `ERROR` with the CFK finalizer held, and the sync hangs.

To rename in place, delete the `FlinkEnvironmentSecretMapping` resources first so the old secrets can finalize, then sync. A cluster built from scratch never hits this — it only bites when renaming an existing deployment, and it is a concrete instance of the reverse-order teardown rule above.

#### Health assessment

Custom Lua health checks in `argocd-cm` evaluate every CMF-backed Flink kind, keyed on `status.cmfSync.status`. Without them ArgoCD treats an unknown custom resource as Healthy the instant it is created, which both hides failures and defeats the wave ordering above.

All Flink checks share one skeleton, evaluated in order:

| Condition | Result |
|---|---|
| no `status` yet | Progressing |
| `status.observedGeneration` < `metadata.generation` | Progressing — spec not yet observed |
| `status.cfkInternalState` = `FAILED` | Degraded |
| `status.cmfSync.status` = `Failed` | Degraded, surfacing `cmfSync.errorMessage` |
| `status.cmfSync.status` = `Unknown` or absent | Progressing |
| `status.cmfSync.status` = `Deleted` | Progressing — transient teardown |
| `status.cmfSync.status` = `Created` | kind-specific checks below, then Healthy |

The `observedGeneration` guard is what makes wave gating correct across updates: without it an edited CR reports Healthy from its *previous* reconcile while the controller is still catching up.

Kind-specific behaviour worth knowing:

- **`FlinkStatement`** degrades only on an explicit `status.phase` of `FAILED`/`FAILING`, surfacing `status.detail`; every other phase is Healthy once `cmfSync` is `Created`. It deliberately does **not** require `RUNNING`, because CFK writes `status.phase` at creation and on failure but does not refresh it when a statement starts running — a running statement can read `PENDING` indefinitely while CMF logs `phase: RUNNING` and its FlinkDeployment is `RUNNING`/`STABLE`. Gating on `RUNNING` hangs the wave on a healthy statement. `COMPLETED` is likewise a success terminal state, since DDL such as `CREATE TABLE` runs once and finishes there.
- **`FlinkComputePool`** deliberately does *not* key on `status.phase`: CMF echoes the pool **type** into that field (observed value `DEDICATED`), not a lifecycle state, so a `phase == "RUNNING"` check would never report Healthy. Pod presence is not a signal either, since a DEDICATED pool has no pods at rest.
- **`FlinkKafkaCatalog`** reports `status.environmentsWithAccess` when present but never degrades on its absence: CFK leaves the field unset on correctly configured catalogs, so treating it as a signal fails the sync for healthy resources. The unmapped-`connectionSecretId` failure — which CMF ignores silently rather than rejecting — is real, but needs a different detector.
- **`FlinkApplication`** defers to the Flink job after CMF registration: only `jobStatus.state` of `FAILED`/`FAILING`, or a non-empty `status.error`, Degrade. A long-running deploy or an intentionally suspended job is never reported broken.

Note the CP data-plane checks (`Kafka`, `KRaftController`, `SchemaRegistry`, `Connect`, `ControlCenter`) use an older convention: they key on `status.phase == "RUNNING"` and return Progressing for everything else, so a terminally failed CP resource sits Progressing rather than Degraded.

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
| 50 | vault-config | Post-deployment Job to configure transit encryption engine |
| 50 | headlamp | Kubernetes dashboard (Helm chart 0.43.0), cluster-admin SA, namespace `headlamp` |
| 75 | cert-manager-resources | Self-signed ClusterIssuer and certificate resources |
| 80 | infra-ingresses | Traefik IngressRoutes + cert-manager Certificates for ArgoCD, Vault, and Headlamp UI access |
| 85 | argocd-config | ArgoCD ConfigMap patches for custom health checks |
| 85 | registry | In-cluster OCI image registry at a pinned ClusterIP (kind clusters) |
| 86 | registry-hosts | PostSync Job writing per-node containerd `hosts.toml` for the in-cluster registry |
| 100 | workloads (parent) | Workloads App of Apps |
| 105 | cfk-operator | Confluent for Kubernetes operator (CRDs and webhooks) |
| 110 | confluent-resources | Confluent Platform resources (KRaft, Kafka, Schema Registry, Control Center, Schema Registry IngressRoute) |
| 110 | workload-ingresses | Traefik IngressRoutes for CMF, Confluent Control Center, and Schema Registry UI access |
| 116 | flink-kubernetes-operator | Flink Kubernetes Operator (manages Flink deployments and jobs) |
| 118 | cmf-operator | Confluent Manager for Apache Flink (central management interface) |
| 119/120 | flink-resources | Flink integration resources (CMFRestClass, single `default` FlinkEnvironment, generic Flink SQL demo) for Kafka integration; deployed on all four clusters — wave 119 on the three RBAC clusters (ahead of colors-and-shapes), wave 120 on flink-demo |
| 120/121 | colors-and-shapes | Two-tenant Flink demo (`shapes-env`, `colors-env`) with a native `FlinkApplication` (JAR) and Flink SQL (`FlinkStatement`) side by side; anonymous on flink-demo (wave 121), Kubernetes RBAC + OAuth/Keycloak via the `rbac-oauth` Kustomize Component on the three RBAC clusters (wave 120) |
| 105+ | workload apps | User-facing applications |

Lower wave numbers deploy first. This ensures dependencies are satisfied (e.g., CRDs before resources that use them, ingress controller before applications with ingress).

## External Access Patterns

### Headlamp Kubernetes Dashboard

Headlamp is a Helm-based infrastructure application (chart `headlamp` 0.43.0 from `https://kubernetes-sigs.github.io/headlamp/`) deployed to the `headlamp` namespace with a cluster-admin ServiceAccount. It is exposed via a Traefik IngressRoute and cert-manager Certificate at `headlamp.<cluster>.<domain>`.

**Authentication:** All clusters use Headlamp's **token login** — the user pastes a Kubernetes bearer token (e.g. `kubectl -n headlamp create token <sa>`) at the login prompt, and Headlamp uses that token's identity (and RBAC) for API calls.

Keycloak OIDC SSO is intentionally **not** used. Headlamp's built-in OIDC combined with `config.unsafeUseServiceAccountToken` does not gate API access — the backend serves every request as the cluster-admin ServiceAccount regardless of login — so that combination would expose unauthenticated cluster-admin. Real SSO will be added later behind an auth proxy (oauth2-proxy + Traefik `forwardAuth`); see [ADR-0009](../adrs/0009-headlamp-dashboard-oidc-access.md).

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
- MinIO provides S3-compatible storage for Flink checkpoints/savepoints, plus a dedicated `artifacts` bucket (`basePath: s3://artifacts/cmf`) backing CMF 2.4.0 artifact management, with credentials injected via `extraEnv` from the reflected `minio-credentials` secret
- Reflector replicates secrets across tenant namespaces

**Flink SQL statement pipeline:** Alongside the JAR-based `FlinkApplication` jobs, the shapes environment runs a standalone Flink SQL statement declared as a `FlinkStatement` custom resource and reconciled into CMF by CFK. A continuous `INSERT INTO` reads the existing `shapes-input` topic (shared with the JAR job) and writes enriched records to a dedicated `shapes-sql-output` topic — kept under the `shapes-` prefix so the `sa-shapes-flink` ResourceOwner bindings authorize the statement's Kafka I/O. The same input thus feeds both the JAR pipeline (→ `shapes-output`) and the SQL pipeline (→ `shapes-sql-output`), while never writing to the JAR output topics. The `colors` tenant mirrors this 1:1 (`colors-input` → `colors-sql-output`). Statement configuration spans three distinct layers — JVM options on the compute pool (OAuth URL allow-list), Kafka connector options as SQL table hints (consumer group, transaction timeout), and MDS RBAC (prefixed Kafka resources + a per-group `FlinkCatalog` binding); see [ADR-0008](../adrs/0008-flink-sql-statement-config-placement-rbac.md) and the [colors-and-shapes README](../workloads/colors-and-shapes/README.md#flink-sql-statement-pipeline).

### AWS EKS Architecture (eks-demo cluster)

The `eks-demo` cluster is the first cluster in this repository provisioned on real AWS infrastructure rather than a local kind environment. This distinction matters more than it might seem at first glance — kind clusters assume the cluster already exists and let you jump straight to ArgoCD. eks-demo requires an entirely separate provisioning layer for the cluster itself before ArgoCD can do anything. That provisioning layer lives in `terraform/clusters/eks-demo/` (calling the reusable `terraform/modules/eks-cluster/` module) and is responsible for the VPC, EKS control plane, managed node groups, IAM roles, bastion host, and all the AWS service endpoints the cluster needs to function in a private network. Terraform state is stored remotely in S3 with DynamoDB locking — see [ADR-0006](../adrs/0006-terraform-remote-state-module-structure.md).

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
- Cluster infrastructure is provisioned via Terraform (`terraform/clusters/eks-demo/` + `terraform/modules/eks-cluster/`), not assumed to pre-exist — see [ADR-0005](../adrs/0005-terraform-argocd-cluster-provisioning-split.md) and [ADR-0006](../adrs/0006-terraform-remote-state-module-structure.md)
- Private API endpoint requires SSM tunnel for all `kubectl` access; no public endpoint is exposed under any circumstances
- Traefik replaced by AWS Load Balancer Controller; Longhorn replaced by EBS CSI driver
- Route53 + ACM provide real public DNS and TLS instead of self-signed certificates and `/etc/hosts` resolution
- `workers-v2` managed node group (t3.2xlarge, min=4, max=6) spread across 3 availability zones

### mTLS Variant (flink-demo-rbac-mtls cluster)

`flink-demo-rbac-mtls` forks `flink-demo-rbac` to add mTLS on the Kafka↔KRaft controller and inter-broker replication paths — see the cluster's own [README](../clusters/flink-demo-rbac-mtls/README.md) for the PKI and listener configuration. **This is currently a work in progress**: service-account and client authentication (CMF, Control Center, Flink SQL statements, producers) still go through Keycloak OIDC/SSO exactly as on `flink-demo-rbac`; only the broker-internal paths have moved to mTLS so far. The same [Multi-Tenant RBAC Architecture](#multi-tenant-rbac-architecture-flink-demo-rbac-cluster) breakdown applies unchanged for everything client-facing.

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
- ArgoCD UI accessible via the infra-ingresses Application (Traefik IngressRoute)
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
