# Adding Helm-Based Workloads and Infrastructure

This guide provides comprehensive instructions for deploying applications and infrastructure components using Helm charts in the GitOps repository.

## Table of Contents

- [When to Use Helm](#when-to-use-helm)
- [Repository Structure](#repository-structure)
- [Quick Start: Adding a Helm Application](#quick-start-adding-a-helm-application)
- [Detailed Walkthrough: Infrastructure Component](#detailed-walkthrough-infrastructure-component)
- [Detailed Walkthrough: Workload Application](#detailed-walkthrough-workload-application)
- [Advanced Patterns](#advanced-patterns)
- [Testing and Validation](#testing-and-validation)
- [Troubleshooting](#troubleshooting)
- [Best Practices](#best-practices)

---

## When to Use Helm

Choose Helm over Kustomize when:

- **Upstream Helm chart exists**: Leverage maintained charts from official sources
- **Complex configuration**: Application has many configurable options
- **Infrastructure components**: cert-manager, prometheus, longhorn, traefik
- **Third-party applications**: Pre-packaged charts from artifact repositories
- **Version management**: Need to track specific chart versions

Use Kustomize instead for:
- Simple custom applications without upstream charts
- Writing manifests from scratch
- Straightforward patching needs

---

## Repository Structure

Helm-based applications follow this directory structure:

```
infrastructure/<app-name>/           # For cluster-scoped resources
├── base/
│   └── values.yaml                  # Common configuration
└── overlays/
    └── <cluster-name>/
        └── values.yaml              # Cluster-specific overrides

workloads/<app-name>/                # For namespace-scoped applications
├── base/
│   └── values.yaml                  # Common configuration
└── overlays/
    └── <cluster-name>/
        └── values.yaml              # Cluster-specific overrides

clusters/<cluster-name>/
├── infrastructure/
│   └── <app-name>.yaml              # ArgoCD Application CRD
└── workloads/
    └── <app-name>.yaml              # ArgoCD Application CRD
```

**Key Concepts:**
- **Base values**: Common configuration shared across all clusters
- **Overlay values**: Cluster-specific overrides (hostnames, replicas, resources)
- **ArgoCD Application**: References upstream chart + value files from this repo

---

## Quick Start: Adding a Helm Application

### Step 1: Create Directory Structure

```bash
# For infrastructure components (cluster-scoped)
mkdir -p infrastructure/<app-name>/base
mkdir -p infrastructure/<app-name>/overlays/<cluster-name>

# OR for workload applications (namespace-scoped)
mkdir -p workloads/<app-name>/base
mkdir -p workloads/<app-name>/overlays/<cluster-name>
```

### Step 2: Create Values Files

**Base values** (`infrastructure/<app-name>/base/values.yaml`):
```yaml
# Common configuration for all clusters
# Keep cluster-agnostic settings here
```

**Cluster overlay** (`infrastructure/<app-name>/overlays/<cluster-name>/values.yaml`):
```yaml
# Cluster-specific overrides
# Hostnames, storage classes, node selectors, etc.
```

### Step 3: Create ArgoCD Application

**File**: `clusters/<cluster-name>/infrastructure/<app-name>.yaml`

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <app-name>
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: infrastructure  # or 'workloads' for apps
  source:
    repoURL: <upstream-helm-repo-url>
    targetRevision: <chart-version>
    chart: <chart-name>
    helm:
      valueFiles:
        - https://raw.githubusercontent.com/osowski/confluent-platform-gitops/HEAD/infrastructure/<app-name>/base/values.yaml
        - https://raw.githubusercontent.com/osowski/confluent-platform-gitops/HEAD/infrastructure/<app-name>/overlays/<cluster-name>/values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: <namespace>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Step 4: Commit and Deploy

```bash
git add infrastructure/<app-name>/ clusters/<cluster-name>/infrastructure/<app-name>.yaml
git commit -m "Add <app-name> Helm application"
git push
```

ArgoCD will automatically detect and deploy the application within 3 minutes.

---

## Detailed Walkthrough: Infrastructure Component

This example demonstrates deploying **cert-manager** to the `flink-demo` cluster.

### Prerequisites

1. Identify the upstream Helm repository and chart name
2. Review the chart's default values and required configuration
3. Determine target namespace and project (infrastructure vs workloads)

For cert-manager:
- **Helm repo**: `https://charts.jetstack.io`
- **Chart name**: `cert-manager`
- **Current version**: Check [ArtifactHub](https://artifacthub.io/)
- **Namespace**: `cert-manager` (standard)
- **Project**: `infrastructure` (installs CRDs)

### Step 1: Create Directory Structure

```bash
mkdir -p infrastructure/cert-manager/base
mkdir -p infrastructure/cert-manager/overlays/flink-demo
```

### Step 2: Create Base Values

**File**: `infrastructure/cert-manager/base/values.yaml`

```yaml
# Common cert-manager configuration for all clusters

# Install CRDs as part of the Helm release
installCRDs: true

# Pod security
global:
  podSecurityPolicy:
    enabled: false
  priorityClassName: ""

# Controller configuration
replicaCount: 1

# Resource requests/limits (conservative defaults)
resources:
  requests:
    cpu: 10m
    memory: 32Mi
  limits:
    cpu: 100m
    memory: 128Mi

# Webhook configuration
webhook:
  replicaCount: 1
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 128Mi

# CA injector configuration
cainjector:
  replicaCount: 1
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 128Mi

# Prometheus monitoring (disabled by default)
prometheus:
  enabled: false
```

**Explanation:**
- `installCRDs: true`: Install Certificate, Issuer, ClusterIssuer CRDs
- Conservative resource limits suitable for homelab
- Single replica (HA not needed for homelab)
- Prometheus disabled (enable when monitoring stack is deployed)

### Step 3: Create Cluster Overlay

**File**: `infrastructure/cert-manager/overlays/flink-demo/values.yaml`

```yaml
# Portcullis-specific cert-manager configuration

# Enable Prometheus ServiceMonitor when monitoring stack exists
prometheus:
  enabled: true
  servicemonitor:
    enabled: true
    prometheusInstance: default

# Increase resources if needed for production load
resources:
  requests:
    cpu: 20m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 256Mi

# Use specific node selector if needed
nodeSelector:
  kubernetes.io/hostname: flink-demo-node-1
```

**Explanation:**
- Enables Prometheus integration for the flink-demo cluster
- Increases resource limits for anticipated load
- Optional node placement (useful for high-availability setups)

### Step 4: Find Chart Information

```bash
# Add Helm repository locally (for testing)
helm repo add jetstack https://charts.jetstack.io
helm repo update

# Search for available versions
helm search repo jetstack/cert-manager --versions

# View default values
helm show values jetstack/cert-manager
```

### Step 5: Create ArgoCD Application

**File**: `clusters/flink-demo/infrastructure/cert-manager.yaml`

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "1"  # Deploy early (before apps needing certs)
spec:
  project: infrastructure
  source:
    repoURL: https://charts.jetstack.io
    targetRevision: v1.13.3  # Pin to specific version
    chart: cert-manager
    helm:
      valueFiles:
        - https://raw.githubusercontent.com/osowski/confluent-platform-gitops/HEAD/infrastructure/cert-manager/base/values.yaml
        - https://raw.githubusercontent.com/osowski/confluent-platform-gitops/HEAD/infrastructure/cert-manager/overlays/flink-demo/values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true  # Required for CRDs
  ignoreDifferences:
    - group: apiextensions.k8s.io
      kind: CustomResourceDefinition
      jsonPointers:
        - /spec/conversion/webhook/clientConfig/caBundle  # Ignore auto-generated CA
```

**Key Fields Explained:**

- **`targetRevision`**: Pin to specific chart version for reproducibility
- **`valueFiles`**: Raw GitHub URLs to values in this repo (merged in order)
- **`sync-wave: "1"`**: Deploy before applications that depend on it
- **`ServerSideApply=true`**: Required for managing CRDs safely
- **`ignoreDifferences`**: Prevent sync thrashing on auto-generated fields

### Step 6: Test Locally

```bash
# Test Helm template rendering
helm template cert-manager jetstack/cert-manager \
  --version v1.13.3 \
  --namespace cert-manager \
  --values infrastructure/cert-manager/base/values.yaml \
  --values infrastructure/cert-manager/overlays/flink-demo/values.yaml \
  > /tmp/cert-manager-test.yaml

# Validate YAML
kubectl apply --dry-run=client -f /tmp/cert-manager-test.yaml
```

### Step 7: Commit and Deploy

```bash
git add infrastructure/cert-manager/
git add clusters/flink-demo/infrastructure/cert-manager.yaml
git commit -m "Add cert-manager infrastructure component

- Install cert-manager v1.13.3 via Helm
- Configure for flink-demo cluster
- Enable Prometheus ServiceMonitor
- Set conservative resource limits"

git push
```

### Step 8: Verify Deployment

```bash
# Wait for ArgoCD to sync (up to 3 minutes)
watch kubectl get application cert-manager -n argocd

# Check application status
kubectl get application cert-manager -n argocd -o yaml

# Verify pods are running
kubectl get pods -n cert-manager

# Check CRDs were created
kubectl get crd | grep cert-manager

# Test certificate issuance (optional)
kubectl get certificates -A
```

---

## Detailed Walkthrough: Workload Application

This example demonstrates deploying **Grafana** as a workload application.

### Prerequisites

For Grafana:
- **Helm repo**: `https://grafana.github.io/helm-charts`
- **Chart name**: `grafana`
- **Namespace**: `monitoring`
- **Project**: `workloads` (namespace-scoped only)
- **Ingress**: `grafana.flink-demo.confluentdemo.local`

### Step 1: Create Directory Structure

```bash
mkdir -p workloads/grafana/base
mkdir -p workloads/grafana/overlays/flink-demo
```

### Step 2: Create Base Values

**File**: `workloads/grafana/base/values.yaml`

```yaml
# Common Grafana configuration

# Admin credentials (use secrets in production!)
adminUser: admin
adminPassword: changeme  # Override in overlay or use sealed-secrets

# Persistence
persistence:
  enabled: true
  type: pvc
  size: 1Gi

# Service configuration
service:
  type: ClusterIP
  port: 80

# Datasources - configure Prometheus
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        url: http://prometheus-server.monitoring.svc.cluster.local
        access: proxy
        isDefault: true

# Dashboards
dashboardProviders:
  dashboardproviders.yaml:
    apiVersion: 1
    providers:
      - name: 'default'
        orgId: 1
        folder: ''
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards/default

# Resource limits
resources:
  limits:
    cpu: 200m
    memory: 256Mi
  requests:
    cpu: 100m
    memory: 128Mi

# Disable ingress (configured per-cluster in overlay)
ingress:
  enabled: false
```

### Step 3: Create Cluster Overlay

**File**: `workloads/grafana/overlays/flink-demo/values.yaml`

```yaml
# Portcullis-specific Grafana configuration

# Override admin password (use sealed-secrets in production)
adminPassword: "flink-demo-secure-password"

# Persistence configuration for flink-demo
persistence:
  enabled: true
  storageClassName: longhorn  # Assuming Longhorn is deployed
  size: 5Gi

# Enable ingress for flink-demo
ingress:
  enabled: true
  ingressClassName: traefik
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
    cert-manager.io/cluster-issuer: letsencrypt-prod  # If cert-manager is deployed
  hosts:
    - grafana.flink-demo.confluentdemo.local
  tls:
    - secretName: grafana-tls
      hosts:
        - grafana.flink-demo.confluentdemo.local

# Increase resources for production workload
resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 200m
    memory: 256Mi

# Add Prometheus datasource specific to flink-demo
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        url: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
        access: proxy
        isDefault: true
```

### Step 4: Create ArgoCD Application

**File**: `clusters/flink-demo/workloads/grafana.yaml`

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: grafana
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "2"  # Deploy after monitoring stack
spec:
  project: workloads
  source:
    repoURL: https://grafana.github.io/helm-charts
    targetRevision: 7.0.8
    chart: grafana
    helm:
      valueFiles:
        - https://raw.githubusercontent.com/osowski/confluent-platform-gitops/HEAD/workloads/grafana/base/values.yaml
        - https://raw.githubusercontent.com/osowski/confluent-platform-gitops/HEAD/workloads/grafana/overlays/flink-demo/values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Step 5: Test Locally

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm template grafana grafana/grafana \
  --version 7.0.8 \
  --namespace monitoring \
  --values workloads/grafana/base/values.yaml \
  --values workloads/grafana/overlays/flink-demo/values.yaml
```

### Step 6: Commit and Deploy

```bash
git add workloads/grafana/
git add clusters/flink-demo/workloads/grafana.yaml
git commit -m "Add Grafana workload application

- Deploy Grafana v7.0.8 via Helm
- Configure Prometheus datasource
- Enable ingress at grafana.flink-demo.confluentdemo.local
- Use Longhorn for persistent storage"

git push
```

### Step 7: Verify Deployment

```bash
# Check ArgoCD Application
kubectl get application grafana -n argocd

# Verify pods
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana

# Check PVC
kubectl get pvc -n monitoring

# Check ingress
kubectl get ingress -n monitoring

# Access Grafana
curl -I https://grafana.flink-demo.confluentdemo.local
```

---

## Advanced Patterns

### Multiple Value Files

Stack multiple value files for layered configuration:

```yaml
spec:
  source:
    helm:
      valueFiles:
        - https://raw.githubusercontent.com/.../base/values.yaml
        - https://raw.githubusercontent.com/.../overlays/common/values.yaml
        - https://raw.githubusercontent.com/.../overlays/flink-demo/values.yaml
```

**Order matters**: Later files override earlier ones.

### Inline Values

Override specific values without creating a file:

```yaml
spec:
  source:
    helm:
      valueFiles:
        - https://raw.githubusercontent.com/.../base/values.yaml
      values: |
        replicaCount: 3
        resources:
          limits:
            memory: 1Gi
```

### Helm Parameters

Use parameters for simple overrides:

```yaml
spec:
  source:
    helm:
      parameters:
        - name: "replicaCount"
          value: "3"
        - name: "image.tag"
          value: "v1.2.3"
```

### Using Different Helm Repo Types

#### OCI Registry

```yaml
spec:
  source:
    repoURL: registry-1.docker.io/bitnamicharts
    chart: nginx
    targetRevision: 15.0.2
```

#### Git Repository with Helm Chart

```yaml
spec:
  source:
    repoURL: https://github.com/example/charts.git
    targetRevision: HEAD
    path: charts/my-app
```

### Helm Hooks

ArgoCD respects Helm hooks for ordered resource creation:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: pre-install-job
  annotations:
    helm.sh/hook: pre-install
    helm.sh/hook-weight: "1"
    helm.sh/hook-delete-policy: hook-succeeded
```

Common hooks:
- `pre-install`: Before chart installation
- `post-install`: After chart installation
- `pre-upgrade`: Before upgrade
- `post-upgrade`: After upgrade
- `pre-delete`: Before deletion

### Sync Waves for Dependencies

Control deployment order across applications:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"  # Infrastructure first
---
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "2"  # Dependent apps second
```

**Standard waves:**
- `-5` to `0`: Critical infrastructure (CRDs, namespaces, operators)
- `1` to `5`: Platform services (monitoring, logging, storage)
- `6` to `10`: Application dependencies (databases, message queues)
- `11` to `20`: Applications
- `21+`: Optional add-ons

### Ignoring Differences

Prevent sync thrashing on fields modified by controllers:

```yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas  # Ignore HPA-managed replicas
    - group: ""
      kind: Service
      jsonPointers:
        - /spec/clusterIP  # Ignore auto-assigned IPs
```

### Secrets Management

**Option 1: Sealed Secrets (Recommended)**

```yaml
# Install sealed-secrets controller
# Encrypt secrets, commit encrypted version
# Controller decrypts on cluster

apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: grafana-admin
  namespace: monitoring
spec:
  encryptedData:
    password: AgBh8j2k...  # Encrypted value
```

**Option 2: External Secrets Operator**

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: grafana-admin
  namespace: monitoring
spec:
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: grafana-admin
  data:
    - secretKey: password
      remoteRef:
        key: grafana/admin-password
```

**Option 3: ArgoCD Vault Plugin**

Uses AVP to inject secrets at deployment time from Vault.

### Chart Dependencies

For Helm charts with dependencies (subcharts):

```yaml
# Chart.yaml
dependencies:
  - name: postgresql
    version: 12.x.x
    repository: https://charts.bitnami.com/bitnami
    condition: postgresql.enabled
```

ArgoCD automatically resolves and deploys dependencies.

### Custom Helm Version

Specify Helm version for compatibility:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/helm-version: v3.12.0
```

---

## Testing and Validation

### Local Helm Testing

#### Step 1: Add Helm Repository

```bash
helm repo add <repo-name> <repo-url>
helm repo update
```

#### Step 2: Search for Chart

```bash
helm search repo <repo-name>/<chart-name> --versions
```

#### Step 3: View Default Values

```bash
helm show values <repo-name>/<chart-name> --version <version>
```

#### Step 4: Test Template Rendering

```bash
helm template <release-name> <repo-name>/<chart-name> \
  --version <version> \
  --namespace <namespace> \
  --values <path-to-base-values> \
  --values <path-to-overlay-values> \
  --debug
```

#### Step 5: Dry-Run Apply

```bash
helm template ... | kubectl apply --dry-run=client -f -
```

### ArgoCD Application Testing

#### Validate Application Manifest

```bash
kubectl apply --dry-run=client -f clusters/<cluster>/infrastructure/<app>.yaml
```

#### Check Application Status

```bash
# View Application details
kubectl get application <app-name> -n argocd -o yaml

# Watch sync progress
watch kubectl get application <app-name> -n argocd

# View sync status
kubectl describe application <app-name> -n argocd
```

#### ArgoCD CLI Testing

```bash
# Install ArgoCD CLI
brew install argocd  # macOS

# Login
argocd login <argocd-server>

# Sync application
argocd app sync <app-name>

# Get application details
argocd app get <app-name>

# View application logs
argocd app logs <app-name>
```

### Common Validation Commands

```bash
# Check Helm release on cluster
helm list -n <namespace>

# View Helm release values
helm get values <release-name> -n <namespace>

# View Helm release manifest
helm get manifest <release-name> -n <namespace>

# Check pod status
kubectl get pods -n <namespace>

# View pod logs
kubectl logs -n <namespace> <pod-name>

# Check events
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

---

## Troubleshooting

### Application Won't Sync

**Symptom**: ArgoCD Application stays in `OutOfSync` state

**Diagnosis**:
```bash
kubectl describe application <app-name> -n argocd
argocd app get <app-name>
```

**Common Causes**:

1. **Invalid values file URL**
   - Ensure raw GitHub URLs are correct
   - Check branch name in URL (HEAD vs main vs feature branch)
   - Verify file exists at that path

2. **Chart version doesn't exist**
   ```bash
   helm search repo <repo>/<chart> --versions
   ```

3. **Helm template rendering fails**
   - Test locally with `helm template`
   - Check for syntax errors in values files
   - Validate required values are set

4. **Namespace doesn't exist and CreateNamespace not enabled**
   ```yaml
   syncOptions:
     - CreateNamespace=true
   ```

### Sync Thrashing (Constant OutOfSync)

**Symptom**: Application syncs successfully but immediately becomes OutOfSync again

**Common Causes**:

1. **Controllers modifying resources**
   - HPA changing replica counts
   - LoadBalancer services getting IPs assigned
   - Operators managing custom resources

   **Solution**: Add `ignoreDifferences` (see Advanced Patterns)

2. **Webhook-injected values**
   - Cert-manager injecting CA bundles
   - Istio injecting sidecars

   **Solution**: Ignore webhook-managed fields

3. **Defaulting webhooks**
   - API server setting default values
   - Admission controllers adding fields

   **Solution**: Use `ServerSideApply=true`

### Chart Dependencies Fail

**Symptom**: Subchart dependencies don't resolve

**Diagnosis**:
```bash
helm dependency list <chart-path>
helm dependency update <chart-path>
```

**Solution**: Ensure dependency repositories are accessible

### CRD Installation Issues

**Symptom**: `installCRDs: true` doesn't work or CRDs fail to update

**Diagnosis**:
```bash
kubectl get crds | grep <chart-name>
```

**Solutions**:

1. **Use `ServerSideApply=true`**
   ```yaml
   syncOptions:
     - ServerSideApply=true
   ```

2. **Install CRDs separately** (recommended for production)
   ```bash
   kubectl apply -f https://raw.githubusercontent.com/.../crds.yaml
   ```

3. **Enable CRD replacement**
   ```yaml
   syncOptions:
     - Replace=true  # Use with caution!
   ```

### Values Not Being Applied

**Symptom**: Helm release doesn't reflect values from files

**Diagnosis**:
```bash
# Check actual values used by Helm
helm get values <release-name> -n <namespace>

# Compare with expected values
helm template <release-name> <chart> --values <values-file>
```

**Common Causes**:

1. **Values file order**: Later files override earlier ones
2. **Incorrect value paths**: Check chart's values schema
3. **Raw GitHub URL issues**: Use correct branch and path
4. **YAML syntax errors**: Validate with `yamllint`

### Resource Limits Causing Crashes

**Symptom**: Pods in CrashLoopBackOff or OOMKilled

**Diagnosis**:
```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> --previous
```

**Solution**: Increase resource limits in overlay values:
```yaml
resources:
  limits:
    memory: 1Gi  # Increase from 256Mi
```

### Permission Denied Errors

**Symptom**: ArgoCD can't create resources

**Diagnosis**:
```bash
kubectl describe application <app-name> -n argocd
```

**Common Causes**:

1. **Wrong ArgoCD Project**: Using `workloads` project for cluster-scoped resources
   - **Solution**: Use `infrastructure` project for CRDs, ClusterRoles, etc.

2. **RBAC restrictions**: ArgoCD Project doesn't allow resource type
   - **Solution**: Update AppProject permissions

3. **Namespace restrictions**: Project limited to specific namespaces
   - **Solution**: Add namespace to AppProject whitelist

### Ingress Not Working

**Symptom**: Application deployed but not accessible via ingress

**Diagnosis**:
```bash
kubectl get ingress -n <namespace>
kubectl describe ingress <ingress-name> -n <namespace>
kubectl get svc -n <namespace>
```

**Common Causes**:

1. **IngressClass not set**: Ensure `ingressClassName` matches cluster's ingress controller
2. **DNS not configured**: Verify hostname resolves to cluster
3. **TLS certificate issues**: Check cert-manager Certificate resource
4. **Service selector mismatch**: Verify ingress backend matches service

---

## Best Practices

### Version Pinning

**Always pin chart versions** in ArgoCD Applications:

```yaml
targetRevision: "1.2.3"  # Specific version
```

**Avoid**:
```yaml
targetRevision: "1.2.x"  # Floating minor version
targetRevision: "*"      # Latest (unpredictable)
```

**Rationale**: Ensures reproducible deployments and prevents unexpected breaking changes.

### Resource Limits

**Set conservative defaults in base**, increase in overlays as needed:

```yaml
# base/values.yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 256Mi
```

**Rationale**: Prevents resource exhaustion; easier to increase than decrease.

### Secrets Management

**NEVER commit plaintext secrets**. Use one of:
1. **Sealed Secrets** (recommended for homelab)
2. **External Secrets Operator** (for Vault integration)
3. **SOPS** (for age or PGP encryption)

**For development only**: Override in overlay, document in README

### Value File Organization

**Base values**: Environment-agnostic configuration
```yaml
# Common to all clusters
replicaCount: 1
resources:
  requests:
    cpu: 100m
```

**Overlay values**: Cluster-specific overrides
```yaml
# Specific to flink-demo cluster
ingress:
  hosts:
    - app.flink-demo.confluentdemo.local
persistence:
  storageClassName: longhorn
```

**Rationale**: Promotes reusability and reduces duplication.

### Sync Policies

**Use automated sync with prune and self-heal** for GitOps:
```yaml
syncPolicy:
  automated:
    prune: true      # Remove resources not in Git
    selfHeal: true   # Revert manual changes
```

**Exception**: Manual sync for critical infrastructure during initial setup.

### Health Checks

**Configure readiness and liveness probes** in values:
```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 30
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /ready
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 5
```

**Rationale**: Prevents traffic to unhealthy pods, enables zero-downtime deployments.

### Namespace Strategy

**One namespace per application** (unless chart mandates otherwise):
- Simplifies RBAC
- Isolates resources
- Easier troubleshooting

**Exception**: Monitoring stack components may share namespace.

### Chart Source Verification

**Use official chart repositories**:
- ArtifactHub (https://artifacthub.io/)
- Project's official Helm repo
- Verified publishers

**Avoid**:
- Random GitHub repositories
- Unverified sources
- Outdated mirrors

### Documentation

**Document in values.yaml**:
```yaml
# Ingress configuration
# Exposed at: grafana.flink-demo.confluentdemo.local
# Cert-manager automatically provisions TLS certificate
ingress:
  enabled: true
  hosts:
    - grafana.flink-demo.confluentdemo.local
```

**Update CHANGELOG.md** when adding new applications.

### Testing Before Deployment

**Always test locally**:
1. `helm template` to validate rendering
2. `kubectl apply --dry-run=client` to validate manifests
3. Review diff before committing

**Rationale**: Catches errors before they reach the cluster.

### Rollback Strategy

**Helm rollback via ArgoCD**:
```bash
argocd app history <app-name>
argocd app rollback <app-name> <revision>
```

**Or revert Git commit**:
```bash
git revert <commit-hash>
git push
```

**Rationale**: ArgoCD GitOps approach favors Git-based rollbacks.

### Monitoring and Observability

**Enable metrics and logging**:
```yaml
# Enable Prometheus ServiceMonitor
serviceMonitor:
  enabled: true

# Enable pod annotations for log collection
podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "9090"
```

**Rationale**: Essential for troubleshooting and performance monitoring.

---

## Related Documentation

- [Architecture Overview](architecture.md) - System design and data flow
- [Adding Applications (General)](adding-applications.md) - Kustomize and Helm overview
- [Bootstrap Procedure](bootstrap-procedure.md) - Initial cluster setup
- [Cluster Onboarding](cluster-onboarding.md) - Adding new clusters
- [Code Review Checklist](https://github.com/osowski/homelab-ansible/blob/main/docs/code_review_checklist.md) - Pre-PR validation

---

## Example Applications

### Complete Infrastructure Examples

- **cert-manager**: TLS certificate automation
- **longhorn**: Distributed block storage
- **kube-prometheus-stack**: Monitoring and alerting
- **traefik**: Ingress controller

### Complete Workload Examples

- **grafana**: Metrics visualization
- **pgadmin**: PostgreSQL management UI
- **nextcloud**: File sharing and collaboration
- **home-assistant**: Home automation platform

Refer to the `infrastructure/` and `workloads/` directories for real-world implementations.

---

## Summary

This guide covered:
- When to use Helm over Kustomize
- Repository structure for Helm applications
- Detailed walkthroughs for infrastructure and workloads
- Advanced patterns (multi-value files, sync waves, secrets)
- Testing and validation procedures
- Comprehensive troubleshooting guide
- Best practices for production deployments

For questions or issues, refer to the [Architecture documentation](architecture.md) or review existing implementations in the repository.
