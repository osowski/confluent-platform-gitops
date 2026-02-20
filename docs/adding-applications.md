# Adding Applications

This guide walks through adding a new application to an existing cluster in the GitOps repository.

**Related guides:**
- **[Cluster Onboarding](cluster-onboarding.md)** - Setting up a new cluster from scratch
- **[Bootstrap Procedure](bootstrap-procedure.md)** - Deploying bootstrap to an existing cluster
- **[Adding Helm Workloads](adding-helm-workloads.md)** - Comprehensive Helm deployment guide with advanced patterns

## Prerequisites

- Cluster already onboarded with bootstrap deployed
- Basic knowledge of Kubernetes manifests
- Familiarity with Kustomize or Helm
- Access to this Git repository

## Decision: Kustomize vs Helm

Choose the appropriate tool for your application:

### Use Kustomize When

- Application is simple with minimal configuration
- You're writing manifests from scratch
- You want to patch existing manifests
- Example: custom services, simple deployments

### Use Helm When

- Application has an upstream Helm chart
- Complex configuration with many options
- Infrastructure components (cert-manager, prometheus)
- Example: third-party applications

## Adding a Kustomize Application

### Step 1: Create Base Manifests

Create the base directory:

```bash
mkdir -p workloads/<app-name>/base
```

Create base Kubernetes manifests:

**`workloads/<app-name>/base/namespace.yaml`**
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: <app-name>
```

**`workloads/<app-name>/base/deployment.yaml`**
```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <app-name>
  namespace: <app-name>
  labels:
    app: <app-name>
spec:
  replicas: 1
  selector:
    matchLabels:
      app: <app-name>
  template:
    metadata:
      labels:
        app: <app-name>
    spec:
      containers:
        - name: <app-name>
          image: <image>:<tag>
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
```

**`workloads/<app-name>/base/service.yaml`**
```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: <app-name>
  namespace: <app-name>
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 8080
      targetPort: http
  selector:
    app: <app-name>
```

**`workloads/<app-name>/base/ingress.yaml`** (optional)
```yaml
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: <app-name>
  namespace: <app-name>
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  rules:
    - host: <app>.CLUSTER_NAME.DOMAIN
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: <app-name>
                port:
                  name: http
```

**`workloads/<app-name>/base/kustomization.yaml`**
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - namespace.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

### Step 2: Create Cluster Overlay

Create the overlay directory:

```bash
mkdir -p workloads/<app-name>/overlays/<cluster-name>
```

**`workloads/<app-name>/overlays/<cluster-name>/kustomization.yaml`**
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

patches:
  - path: ingress-patch.yaml
    target:
      kind: Ingress
      name: <app-name>
```

**`workloads/<app-name>/overlays/<cluster-name>/ingress-patch.yaml`**
```yaml
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: <app-name>
  namespace: <app-name>
spec:
  rules:
    - host: <app>.<cluster-name>.confluentdemo.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: <app-name>
                port:
                  name: http
```

### Step 3: Create ArgoCD Application

**`clusters/<cluster-name>/workloads/<app-name>.yaml`**
```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <app-name>
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "105"  # Deploy after infrastructure
spec:
  project: workloads
  source:
    repoURL: https://github.com/osowski/confluent-platform-gitops.git
    targetRevision: HEAD
    path: workloads/<app-name>/overlays/<cluster-name>
  destination:
    server: https://kubernetes.default.svc
    namespace: <app-name>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Step 4: Add to Cluster Kustomization

Add the application to the cluster's kustomization file:

**`clusters/<cluster-name>/workloads/kustomization.yaml`**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - <app-name>.yaml
  # ... other applications
```

### Step 5: Commit and Push

```bash
git add workloads/<app-name>/ clusters/<cluster-name>/workloads/<app-name>.yaml clusters/<cluster-name>/workloads/kustomization.yaml
git commit -m "Add <app-name> application"
git push
```

### Step 6: Verify Deployment

```bash
# Check ArgoCD Application created
kubectl get application <app-name> -n argocd

# Check pods running
kubectl get pods -n <app-name>

# Check ingress
kubectl get ingress -n <app-name>
```

## Adding a Helm Application

> **For a comprehensive guide to Helm deployments**, see [Adding Helm Workloads](adding-helm-workloads.md) which includes:
> - Detailed walkthroughs for infrastructure and workload applications
> - Real-world examples (cert-manager, Grafana)
> - Advanced patterns and troubleshooting
> - Testing and validation procedures
>
> The quick reference below covers the basic steps.

### Step 1: Create Base Directory

```bash
mkdir -p infrastructure/<app-name>/base
```

### Step 2: Create Helm Values

**`infrastructure/<app-name>/base/values.yaml`**
```yaml
# Base values for <app-name>
# These are merged with cluster-specific values

# Add common configuration here
```

### Step 3: Create Cluster Overlay

**`infrastructure/<app-name>/overlays/<cluster-name>/values.yaml`**
```yaml
# Cluster-specific values for <app-name>

# Override base values here
```

### Step 4: Create ArgoCD Application

**`clusters/<cluster-name>/infrastructure/<app-name>.yaml`**
```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <app-name>
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "10"  # Adjust based on dependencies
spec:
  project: infrastructure
  sources:
  - repoURL: <upstream-helm-repo-url>
    targetRevision: <chart-version>
    chart: <chart-name>
    helm:
      ignoreMissingValueFiles: true  # Optional: allows missing overlay files
      valueFiles:
        - $values/infrastructure/<app-name>/base/values.yaml
        - $values/infrastructure/<app-name>/overlays/<cluster-name>/values.yaml
  - repoURL: https://github.com/osowski/confluent-platform-gitops
    targetRevision: HEAD
    ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: <namespace>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true  # Required for CRDs
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

**Note**: This uses ArgoCD's multi-source feature:
- First source: upstream Helm chart
- Second source: values files from this Git repository
- The `$values` reference points to the Git repo source
- `ignoreMissingValueFiles` allows deployment without overlay file (uses only base values)

### Step 5: Add to Cluster Kustomization

Add the application to the cluster's infrastructure kustomization file:

**`clusters/<cluster-name>/infrastructure/kustomization.yaml`**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - <app-name>.yaml
  # ... other infrastructure components
```

### Step 6: Commit and Push

```bash
git add infrastructure/<app-name>/ clusters/<cluster-name>/infrastructure/<app-name>.yaml clusters/<cluster-name>/infrastructure/kustomization.yaml
git commit -m "Add <app-name> infrastructure component"
git push
```

## Sync Waves

Use sync waves to control deployment order when applications have dependencies.

### Common Sync Wave Values

| Wave | Purpose | Examples |
|------|---------|----------|
| 0 | Bootstrap | Bootstrap Application |
| 1 | Parent Apps | infrastructure, workloads |
| 10-50 | Core Infrastructure | traefik (10), kube-prometheus-stack (20), cert-manager (15) |
| 100 | Workload Parent | workloads parent app |
| 105+ | Applications | http-echo (105), custom apps (110+) |

### Setting Sync Waves

Add annotation to Application metadata:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "10"
```

**Guidelines:**
- Lower numbers deploy first
- Leave gaps (10, 20, 30) for future insertions
- Infrastructure: waves 10-50
- Workloads: waves 105+
- Critical dependencies (storage, networking) should have lower wave numbers

## Testing Changes Locally

### Kustomize

Test rendering before committing:

```bash
kubectl kustomize workloads/<app-name>/overlays/<cluster-name>/
```

### Helm

Test rendering before committing:

```bash
helm template <app-name> <chart-repo>/<chart-name> \
  --values infrastructure/<app-name>/base/values.yaml \
  --values infrastructure/<app-name>/overlays/<cluster-name>/values.yaml
```

## Choosing the Project

### Use `workloads` Project When

- Application is user-facing
- Only needs namespace-scoped resources
- Examples: web apps, APIs, databases

### Use `infrastructure` Project When

- Component requires cluster-scoped resources
- Installing CRDs or operators
- Examples: cert-manager, longhorn, monitoring

## Common Patterns

### ConfigMaps and Secrets

Create in base, patch in overlay if needed:

**`base/configmap.yaml`**
```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: <app-name>-config
  namespace: <app-name>
data:
  key: default-value
```

**`overlays/<cluster>/configmap-patch.yaml`**
```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: <app-name>-config
  namespace: <app-name>
data:
  key: cluster-specific-value
```

### Multiple Replicas

Set in base, override in overlay:

**`overlays/<cluster>/replica-patch.yaml`**
```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <app-name>
  namespace: <app-name>
spec:
  replicas: 3
```

### Resource Limits

Set conservative defaults in base, increase in overlay if needed.

## Troubleshooting

### Application Not Appearing

1. Check that parent Application (`workloads-apps` or `infrastructure-apps`) is synced
2. Verify file is in correct directory: `clusters/<cluster>/workloads/` or `clusters/<cluster>/infrastructure/`
3. Check ArgoCD logs for errors

### Kustomize Build Errors

1. Validate YAML syntax
2. Ensure patch targets exist in base
3. Test locally with `kubectl kustomize`

### Helm Template Errors

1. Verify chart version exists
2. Check values file syntax
3. Test locally with `helm template`

## Best Practices

1. **Keep base manifests generic** - Use overlays for cluster-specific config
2. **Set resource requests/limits** - Prevent resource exhaustion
3. **Use health checks** - Define liveness and readiness probes
4. **Pin image tags** - Avoid `:latest` for reproducibility
5. **Document changes** - Write clear commit messages
6. **Test locally** - Validate rendering before pushing
7. **Use semantic versioning** - For custom applications

## AppProject Resource Audit

Every ArgoCD Application must be assigned to a project (`infrastructure` or `workloads`). Each project defines an explicit allowlist of Kubernetes resource kinds it may create:

- **`clusterResourceWhitelist`** — cluster-scoped resources (StorageClass, ClusterRole, ClusterRoleBinding, PersistentVolume, Namespace, CustomResourceDefinition, etc.)
- **`namespaceResourceWhitelist`** — namespace-scoped resources (Deployment, Service, ConfigMap, Secret, etc.)

If an application attempts to create a resource kind not in its project's allowlist, ArgoCD will refuse to sync it. **Run this audit before opening a PR** to catch missing entries at review time rather than at deploy time.

The project allowlists live in `bootstrap/templates/argocd-projects.yaml`.

### Step 1: Enumerate resources the application will create

#### Kustomize applications

```bash
kubectl kustomize workloads/<app>/overlays/<cluster>/ \
  | grep -E "^(apiVersion|kind):" \
  | paste - - \
  | sort -u
```

#### Helm applications (chart available locally)

```bash
helm template <release-name> <chart-path> \
  -f infrastructure/<app>/base/values.yaml \
  -f infrastructure/<app>/overlays/<cluster>/values.yaml \
  | grep -E "^(apiVersion|kind):" \
  | paste - - \
  | sort -u
```

#### Helm applications (remote chart — GitHub or OCI)

Pull the chart first, then template it:

```bash
# Pull from a Helm registry
helm pull <repo>/<chart> --version <version> --untar --untardir /tmp/chart-review/
helm template <release-name> /tmp/chart-review/<chart>/ \
  -f infrastructure/<app>/base/values.yaml \
  | grep -E "^(apiVersion|kind):" | paste - - | sort -u

# Or inspect chart templates directly on GitHub for the pinned targetRevision
```

### Step 2: Classify each resource as cluster-scoped or namespace-scoped

Common cluster-scoped kinds (go in `clusterResourceWhitelist`):

| Kind | API Group |
|------|-----------|
| `ClusterRole` | `rbac.authorization.k8s.io` |
| `ClusterRoleBinding` | `rbac.authorization.k8s.io` |
| `CustomResourceDefinition` | `apiextensions.k8s.io` |
| `Namespace` | _(core)_ |
| `PersistentVolume` | _(core)_ |
| `StorageClass` | `storage.k8s.io` |
| `ValidatingWebhookConfiguration` | `admissionregistration.k8s.io` |
| `MutatingWebhookConfiguration` | `admissionregistration.k8s.io` |

Everything else (Deployment, Service, ConfigMap, ServiceAccount, Role, RoleBinding, etc.) is namespace-scoped and goes in `namespaceResourceWhitelist`.

### Step 3: Cross-reference against the target project

Open `bootstrap/templates/argocd-projects.yaml` and locate the project your Application uses (`spec.project`).

- A wildcard entry (`group: '*' / kind: '*'`) permits all resources — no further action needed.
- An explicit list requires every resource kind from Step 1 to appear as a matching entry.

For each resource not found in the allowlist, add an entry to the appropriate whitelist before merging.

**Example audit table** (from the Vault infrastructure review):

| Kind | Group | Scope | Whitelisted |
|------|-------|-------|-------------|
| `ServiceAccount` | _(core)_ | Namespace | ✅ wildcard |
| `ConfigMap` | _(core)_ | Namespace | ✅ wildcard |
| `Service` | _(core)_ | Namespace | ✅ wildcard |
| `StatefulSet` | `apps` | Namespace | ✅ wildcard |
| `Role` | `rbac.authorization.k8s.io` | Namespace | ✅ wildcard |
| `RoleBinding` | `rbac.authorization.k8s.io` | Namespace | ✅ wildcard |

> **Note:** The `infrastructure` project currently uses wildcard allowlists. If it ever moves to an explicit allowlist, all resource kinds would need to be added explicitly. The `workloads` project uses an explicit allowlist with specific CRD kinds for CFK, Flink, and cert-manager.

## Next Steps

- **Advanced Helm patterns**: [Adding Helm Workloads](adding-helm-workloads.md) - Comprehensive guide with real-world examples
- **System architecture**: [Architecture](architecture.md) - Understand the overall design and patterns
- **Bootstrap operations**: [Bootstrap Procedure](bootstrap-procedure.md) - Manage bootstrap configuration
- **New cluster setup**: [Cluster Onboarding](cluster-onboarding.md) - Onboard additional clusters
