# Adoption Guide: Using This Repository

## Introduction

This repository provides a production-ready GitOps framework for deploying **Confluent Platform** (KRaft, Kafka, Schema Registry, Connect, Control Center) and **Apache Flink** on Kubernetes using **ArgoCD**. It includes a complete infrastructure stack (ingress, monitoring, secrets management, TLS certificates) and follows the **App of Apps** pattern for declarative cluster management.

**Two primary use cases:**
1. **Use directly** - Deploy to your clusters as-is for testing, demos, or production if it meets your needs
2. **Fork and customize** - Adapt the repository structure, infrastructure stack, or workload configuration for your organization

**Prerequisites:** Kubernetes 1.25+, basic knowledge of Kubernetes manifests, familiarity with GitOps concepts. Time investment: 30 minutes for local testing, 1-2 hours for production cluster deployment, ongoing time for customization.

**This guide is a routing hub** - it helps you quickly identify your use case and navigate to the appropriate detailed documentation. Use the decision tree below to find your path.

## Decision Tree: Choose Your Path

> [!NOTE]
> **Quick selection:** Most first-time users should start with [**Path 1** (local testing)](#path-1-local-development--testing) or [**Path 5** (fork setup)](#path-5-fork-customization-guide). Production deployments typically follow **Path 5 → Path 2**.

```
START: What do you want to do?
│
├─ Learn/test GitOps and Confluent Platform locally?
│  └─> PATH 1: Local Development & Testing
│
├─ Deploy to an existing Kubernetes cluster?
│  │
│  ├─ Do you already have ArgoCD installed?
│  │  ├─ Yes → Want to use as-is or customize?
│  │  │  ├─ Use as-is → PATH 2: Deploy to Existing Cluster
│  │  │  └─ Customize → PATH 5: Fork first, then PATH 2
│  │  └─ No → PATH 2: Deploy to Existing Cluster (includes ArgoCD setup)
│  │
│  └─ Is this for your organization (not contributing back)?
│     └─> PATH 5: Fork Customization Guide (then PATH 2)
│
├─ Add/modify infrastructure components (ingress, monitoring, secrets)?
│  └─> PATH 3: Customize Infrastructure Components
│
├─ Add/modify workloads (apps, Confluent resources, Flink jobs)?
│  └─> PATH 4: Add/Modify Workloads
│
└─ Fork for organizational use?
   └─> PATH 5: Fork Customization Guide
```

## Path 1: Local Development & Testing

> [!TIP]
> **When to use:** Learning GitOps, testing before forking, demos, development environments

**What you get:** Full Confluent Platform + Flink + monitoring stack running locally via KIND (Kubernetes in Docker)

**Time commitment:** ~30 minutes for initial setup, ~15 minutes for subsequent deployments

**High-level steps:**
1. Install required tools (Homebrew, Colima, KIND, kubectl, yq)
2. Configure local DNS entries in `/etc/hosts`
3. Start Colima and create KIND cluster
4. Install ArgoCD
5. Apply bootstrap configuration
6. Access ArgoCD UI and sync workload applications
7. Access Confluent Control Center UI

**Detailed walkthrough:** [Getting Started for the Uninitiated](getting-started-for-the-uninitiated.md)
- Step-by-step commands with explanations
- Verification steps at each stage
- Troubleshooting common local deployment issues

## Path 2: Deploy to Existing Cluster

> [!TIP]
> **When to use:** Production/staging environments, testing repository before forking, cluster already has or needs ArgoCD

**Prerequisites:**
- Kubernetes cluster 1.25+ with kubectl access
- Cluster resources: 8+ CPU cores, 16+ GB RAM, 100+ GB storage
- LoadBalancer support OR NodePort access for ingress
- DNS control or ability to modify `/etc/hosts`

**High-level steps:**
1. Install ArgoCD if not present
2. Fork repository (if customizing - see [Path 5](#path-5-fork-customization-guide))
3. Create cluster directory structure in `clusters/<cluster-name>/`
4. Create and validate bootstrap Application manifest
5. Commit cluster configuration to Git
6. Deploy bootstrap to cluster
7. Configure DNS/ingress for application access
8. Add applications as needed (Path 3 or Path 4)

> [!IMPORTANT]
> Cluster onboarding is typically done **AFTER** forking for organizational use, unless the cluster is intended for contribution back to the upstream repository.

**Detailed procedures:**
- **Complete cluster onboarding:** [Cluster Onboarding](cluster-onboarding.md)
  - Directory structure setup
  - Bootstrap configuration
  - Application selection
  - DNS and ingress configuration
  - Multi-cluster patterns
- **Bootstrap deployment and operations:** [Bootstrap Procedure](bootstrap-procedure.md)
  - Bootstrap verification steps
  - Re-bootstrapping procedures
  - Troubleshooting bootstrap failures

> [!IMPORTANT]
> **Version pinning:** By default, `targetRevision: HEAD` tracks the latest commit. For production deployments, pin to a release tag (e.g., `targetRevision: v0.4.0`). See [Release Process](release-process.md) for version-pinned deployment guidance.

## Path 3: Customize Infrastructure Components

> [!TIP]
> **When to use:** Different infrastructure stack preferences, need to add/remove components, modify configurations (resource limits, replicas, feature flags)

**What you can customize:**
- Add new infrastructure components (service mesh, backup solutions, logging)
- Remove unused components (Vault, monitoring, ingress)
- Modify resource allocations (CPU, memory, storage)
- Change configuration options (monitoring retention, TLS settings, ingress rules)

**Pattern overview:** Infrastructure generally uses Helm with multi-source pattern
- **Base values:** `infrastructure/<component>/base/values.yaml` - Shared defaults
- **Overlay values:** `infrastructure/<component>/overlays/<cluster>/values.yaml` - Cluster-specific overrides
- **ArgoCD Application:** `clusters/<cluster>/infrastructure/<component>.yaml` - Deployment configuration

**Example: Adding a new infrastructure component (simplified)**
1. Create directory: `infrastructure/elasticsearch/base/`
2. Create base values: `infrastructure/elasticsearch/base/values.yaml`
3. Create cluster overlay: `infrastructure/elasticsearch/overlays/flink-demo/values.yaml`
4. Create ArgoCD Application: `clusters/flink-demo/infrastructure/elasticsearch.yaml`
   - Reference upstream Helm chart
   - Set sync wave (e.g., wave 15 for storage-related)
   - Configure multi-source with values files
5. Add to kustomization: `clusters/flink-demo/infrastructure/kustomization.yaml`
6. Commit and push - ArgoCD auto-syncs

**Detailed guidance:**
- **Helm deployment patterns:** [Adding Helm Workloads](adding-helm-workloads.md)
  - Multi-source configuration
  - Sync wave guidelines
  - Testing and validation
  - Advanced patterns (secrets, CRDs, operators)
- **System architecture:** [Architecture](architecture.md)
  - Current infrastructure components and dependencies
  - Sync wave ordering rationale
  - RBAC project boundaries

**Common customizations:**
- Disable Vault (remove from `clusters/<cluster>/infrastructure/kustomization.yaml`)
- Change monitoring retention (modify `kube-prometheus-stack` values)
- Add external-dns (create new infrastructure application)

## Path 4: Add/Modify Workloads

> [!TIP]
> **When to use:** Deploy custom applications, modify Confluent topology (topics, connectors, schemas), add Flink jobs, integrate new services with Kafka

**What you can customize:**
- Add custom applications and services
- Modify Confluent Platform resources (Kafka brokers, Schema Registry, Connect, KafkaTopics)
- Deploy Flink applications (FlinkDeployment, FlinkSessionJob, FlinkApplication)
- Integrate workloads with existing infrastructure

**Pattern overview:** Workloads generally use Kustomize with base + overlay pattern
- **Base manifests:** `workloads/<app>/base/` - Generic Kubernetes manifests
- **Cluster overlays:** `workloads/<app>/overlays/<cluster>/` - Cluster-specific patches
- **ArgoCD Application:** `clusters/<cluster>/workloads/<app>.yaml` - Deployment configuration

**Example: Adding a custom application (simplified)**
1. Create base: `workloads/my-api/base/` with deployment, service, ingress
2. Create kustomization: `workloads/my-api/base/kustomization.yaml`
3. Create overlay: `workloads/my-api/overlays/flink-demo/` with patches
4. Create ArgoCD Application: `clusters/flink-demo/workloads/my-api.yaml`
   - Set sync wave (≥105 for workloads)
   - Configure automated sync or manual sync
5. Add to kustomization: `clusters/flink-demo/workloads/kustomization.yaml`
6. Commit and push

**Detailed guidance:**
- **Application patterns:** [Adding Applications](adding-applications.md)
  - Kustomize vs Helm decision guide
  - Base + overlay structure
  - Sync wave guidelines
  - AppProject resource audit
- **Confluent Platform resources:** [Confluent Platform](confluent-platform.md)
  - KRaft, Kafka, Schema Registry, Connect configuration
  - Adding Kafka topics, connectors, schemas
  - CFK custom resource definitions
- **Flink integration:** [Confluent Flink](confluent-flink.md)
  - Flink Kubernetes Operator usage
  - Confluent Manager for Apache Flink (CMF)
  - FlinkEnvironment and Kafka integration

**Common workload customizations:**
- Add Kafka topics (modify `confluent-resources`)
- Deploy custom microservices (new application)
- Add Flink streaming jobs (new `FlinkApplication`)

## Path 5: Fork Customization Guide

> [!TIP]
> **When to fork vs. use directly:**
> - **Fork when:** Organizational use, custom infrastructure needs, different naming conventions, need to track your own changes
> - **Use directly when:** Contributing improvements back, using for learning/demos, infrastructure matches your needs exactly
>
> **This is the most important section for organizational adoption.**

### Step 1: Fork the Repository

1. Visit [osowski/confluent-platform-gitops](https://github.com/osowski/confluent-platform-gitops) and click "Fork"
2. Clone your fork:
   ```bash
   git clone https://github.com/<your-org>/confluent-platform-gitops.git
   cd confluent-platform-gitops
   ```
3. Add upstream remote (for tracking updates):
   ```bash
   git remote add upstream https://github.com/osowski/confluent-platform-gitops.git
   git fetch upstream
   ```

### Step 2: Update Repository URLs

**CRITICAL STEP:** All ArgoCD Application manifests reference the repository URL. After forking, you must update these references to point to your fork.

**Files to update:**
- `clusters/*/bootstrap.yaml` - Bootstrap application source
- `clusters/*/infrastructure/*.yaml` - Infrastructure applications (multi-source refs)
- `clusters/*/workloads/*.yaml` - Workload applications

**Manual approach:**
```bash
# Update all references to your fork URL
find clusters/ -type f -name "*.yaml" -exec sed -i '' \
  's|https://github.com/osowski/confluent-platform-gitops|https://github.com/<your-org>/confluent-platform-gitops|g' {} +

# Verify changes
git diff
```

**Automation opportunity:** A script would automate this process - see [GitHub Issue #44](#automation-opportunity-update-repo-urls).

### Step 3: Customize Cluster Configuration

Customize cluster-specific settings for your environment:

**Cluster names:** Update `clusters/<cluster-name>/` directory names to match your cluster naming convention

**Domain names:** Update `cluster.domain` in bootstrap and ingress configurations
- Default: `confluentdemo.local`
- Update to your domain: `<cluster>.yourcompany.com`

**Hostnames:** Update ingress hostnames in:
- `infrastructure/*/overlays/<cluster>/` - Infrastructure component ingress (Grafana, ArgoCD, Vault)
- `workloads/*/overlays/<cluster>/` - Application ingress (Control Center)

**TLS certificates:** Modify `cert-manager-resources` for:
- Production certificate issuers (Let's Encrypt instead of self-signed)
- Custom CA certificate trust bundles

**Secrets management:** Configure external secrets (Vault, External Secrets Operator, sealed-secrets)
- Default: HashiCorp Vault in dev mode (NOT production-ready)
- Update or replace with your secrets solution

### Step 4: Cluster Onboarding for Forks

**Standard workflow:**
1. Fork repository (above)
2. Update repository URLs to your fork
3. Customize cluster configuration
4. **Then** perform cluster onboarding with your fork's URL
5. Deploy bootstrap: `kubectl apply -f clusters/<cluster>/bootstrap.yaml`

> [!IMPORTANT]
> **Exception:** Only onboard to the upstream repository if the cluster is intended for contribution back (e.g., demo clusters, testing improvements).

**Detailed onboarding:** Follow [Cluster Onboarding](cluster-onboarding.md) with your fork's repository URL.

## Common Customization Scenarios

Quick reference for common adoption scenarios:

| Scenario | Paths | Primary Docs |
|----------|-------|--------------|
| **Try locally first time** | Path 1 | [Getting Started](getting-started-for-the-uninitiated.md) |
| **Fork for organization** | Path 5 → Path 2 | This guide (Path 5), [Cluster Onboarding](cluster-onboarding.md) |
| **Add custom API to cluster** | Path 4 | [Adding Applications](adding-applications.md) |
| **Replace monitoring stack** | Path 3 | [Adding Helm Workloads](adding-helm-workloads.md), [Architecture](architecture.md) |
| **Add Kafka topics/connectors** | Path 4 | [Confluent Platform](confluent-platform.md) |
| **Deploy Flink streaming job** | Path 4 | [Confluent Flink](confluent-flink.md) |
| **Remove Vault (use different secrets)** | Path 3 | [Adding Helm Workloads](adding-helm-workloads.md) |
| **Add new cluster to fork** | Path 2 | [Cluster Onboarding](cluster-onboarding.md) |
| **Pin to specific version** | Path 2 | [Release Process](release-process.md) |
| **Customize resource limits** | Path 3 or 4 | Component-specific overlays |

## Automation & Tooling Opportunities

The following automation scripts would streamline common adoption tasks. These are **documented for future implementation** - they do not currently exist.

### High Priority Scripts

#### 1. `scripts/new-application.sh` - Scaffold Application Structure
**Problem:** Creating base + overlay structure for new applications is repetitive

**Solution:** Generate application scaffolding with best practices

**Usage:**
```bash
./scripts/new-application.sh my-api kustomize flink-demo
./scripts/new-application.sh vault helm flink-demo
```

**What it would do:**
- Create `workloads/<app>/base/` or `infrastructure/<app>/base/` directory
- Generate template manifests (deployment, service, ingress for Kustomize)
- Generate values files (base + overlay for Helm)
- Create ArgoCD Application manifest in `clusters/<cluster>/`
- Add entry to cluster kustomization.yaml
- Set appropriate sync wave based on type

**Tracking:** [GitHub Issue #46](https://github.com/osowski/confluent-platform-gitops/issues/46)

### Medium Priority Scripts

#### 2. `scripts/test-local.sh` - Automated Local Deployment
**Usage:** `./scripts/test-local.sh [cluster-name]`

**What it would do:** Automate full local deployment flow (Colima start, KIND cluster creation, ArgoCD install, bootstrap apply, wait for sync)

**Tracking:** [GitHub Issue #47](https://github.com/osowski/confluent-platform-gitops/issues/47)

#### 3. `scripts/diff-versions.sh` - Compare Configuration Versions
**Usage:** `./scripts/diff-versions.sh v0.3.0 v0.4.0`

**What it would do:** Show configuration changes between releases or commits (application additions, value changes, version upgrades)

**Tracking:** [GitHub Issue #48](https://github.com/osowski/confluent-platform-gitops/issues/48)

#### 4. `Makefile` - Common Task Shortcuts
**Usage:** `make validate`, `make test-local`, `make new-cluster`

**What it would do:** Provide task runner with common targets (wraps scripts above, adds convenience targets)

**Tracking:** [GitHub Issue #49](https://github.com/osowski/confluent-platform-gitops/issues/49)

### Low Priority Enhancements

#### 5. Pre-commit Hooks
**What it would do:** Run validation on `git commit` (YAML syntax, secret scanning, kustomize build)

**Tracking:** [GitHub Issue #50](https://github.com/osowski/confluent-platform-gitops/issues/50)

#### 6. GitHub Actions Workflows
**What it would do:** Automated PR validation, release automation, E2E testing in CI/CD

**Tracking:** [GitHub Issue #51](https://github.com/osowski/confluent-platform-gitops/issues/51)

**Note:** These automation opportunities are tracked as individual GitHub issues for future implementation. Contributions welcome.

## Testing Your Changes

**Before deploying to production, validate manifests locally:**

### Kustomize Validation
```bash
# Test overlay builds correctly
kubectl kustomize workloads/<app>/overlays/<cluster>/

# Validate YAML syntax
kubectl kustomize workloads/<app>/overlays/<cluster>/ | kubectl apply --dry-run=client -f -
```

### Helm Validation
```bash
# Test values merge correctly
helm template <name> <repo>/<chart> \
  -f infrastructure/<app>/base/values.yaml \
  -f infrastructure/<app>/overlays/<cluster>/values.yaml

# Validate against cluster (requires cluster access)
helm template <name> <repo>/<chart> \
  -f infrastructure/<app>/base/values.yaml \
  -f infrastructure/<app>/overlays/<cluster>/values.yaml \
  | kubectl apply --dry-run=server -f -
```

### Pre-deployment Checklist

- [ ] YAML syntax validated (no parse errors)
- [ ] Kustomize overlays build successfully
- [ ] Helm templates render without errors
- [ ] Sync waves set appropriately (see [Architecture](architecture.md))
- [ ] AppProject resource audit passed (see [Adding Applications](adding-applications.md#appproject-resource-audit))
- [ ] Documentation updated if adding new patterns
- [ ] Tested in local environment (Path 1) if possible
- [ ] Repository URLs point to correct fork (if using fork)

**Full validation guidance:** See `scripts/validate-cluster.sh` documentation ([Issue #45](#automation-opportunity-validate-cluster)) for comprehensive pre-deployment checks.

## Troubleshooting

Quick navigation to troubleshooting sections in detailed guides:

### Bootstrap Issues
- **Bootstrap fails to deploy:** [Bootstrap Procedure - Troubleshooting](bootstrap-procedure.md#troubleshooting)
- **Applications not appearing:** [Cluster Onboarding - Application Not Syncing](cluster-onboarding.md#applications-not-syncing)

### Application Deployment Issues
- **Kustomize build errors:** [Adding Applications - Kustomize Build Errors](adding-applications.md#kustomize-build-errors)
- **Helm template errors:** [Adding Applications - Helm Template Errors](adding-applications.md#helm-template-errors)
- **Sync waves not working:** [Adding Helm Workloads - Troubleshooting](adding-helm-workloads.md#troubleshooting)

### Infrastructure Component Issues
- **Ingress not working:** [Cluster Onboarding - Ingress Not Working](cluster-onboarding.md#ingress-not-working)
- **Resource exhaustion:** [Cluster Onboarding - Resource Exhaustion](cluster-onboarding.md#resource-exhaustion)
- **CRDs not installing:** [Adding Helm Workloads - CRD Installation](adding-helm-workloads.md#troubleshooting)

### Confluent Platform Issues
- **CFK resources not syncing:** [Confluent Platform - Troubleshooting](confluent-platform.md#troubleshooting)
- **Kafka brokers not starting:** [Confluent Platform - Common Issues](confluent-platform.md#common-issues)

**General debugging:**
1. Check ArgoCD Application status: `kubectl get applications -n argocd`
2. Review ArgoCD logs: `kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server`
3. Inspect pod status: `kubectl get pods -A`
4. Review events: `kubectl get events -A --sort-by='.lastTimestamp'`
