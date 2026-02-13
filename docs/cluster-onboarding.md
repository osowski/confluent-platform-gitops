# Cluster Onboarding

This guide describes how to onboard a new Kubernetes cluster to this GitOps repository.

## Overview

Onboarding a cluster involves:
1. Preparing the cluster (installing ArgoCD)
2. Creating cluster-specific configuration
3. Deploying the bootstrap
4. Adding applications

## Prerequisites

### Cluster Setup

The cluster must have:
- Kubernetes 1.25 or later
- Network connectivity to GitHub
- LoadBalancer or NodePort access for ingress
- Sufficient resources for workloads

### Required Tools

On your local machine:
- `kubectl` configured for the cluster
- `helm` CLI (3.x or later)
- `git` CLI

## Step 1: Install ArgoCD

If ArgoCD is not already installed, deploy it using the standard installation:

```bash
# Create argocd namespace
kubectl create namespace argocd

# Install ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

> TODO update this to be a version-specific Argo CD installation

Wait for all ArgoCD pods to be running:

```bash
kubectl get pods -n argocd -w
```

## Step 2: Create Cluster Directory Structure

In this repository, create the cluster directory structure:

```bash
mkdir -p clusters/<cluster-name>/infrastructure
mkdir -p clusters/<cluster-name>/workloads
```

Create kustomization files for each layer:

**`clusters/<cluster-name>/infrastructure/kustomization.yaml`**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources: []
# Add infrastructure applications here as they are created
# Example:
# - traefik.yaml
# - kube-prometheus-stack.yaml
```

**`clusters/<cluster-name>/workloads/kustomization.yaml`**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources: []
# Add workload applications here as they are created
# Example:
# - http-echo.yaml
```

## Step 3: Create Bootstrap Application

Create a bootstrap Application manifest for the cluster:

**`clusters/<cluster-name>/bootstrap.yaml`**
```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: bootstrap
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: https://github.com/osowski/confluent-platform-gitops.git
    targetRevision: HEAD
    path: bootstrap
    helm:
      valuesObject:
        cluster:
          name: <cluster-name>
          domain: confluentdemo.local
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Adjust the domain if different for this cluster.

## Step 4: Validate Bootstrap Configuration

Validate the bootstrap Application manifest:

```bash
kubectl apply --dry-run=client -f clusters/<cluster-name>/bootstrap.yaml
```

Expected output: `application.argoproj.io/bootstrap created (dry run)`

Optionally, validate what the bootstrap chart will create:

```bash
helm template bootstrap ./bootstrap/ \
  --set cluster.name=<cluster-name> \
  --set cluster.domain=confluentdemo.local
```

Review the output:
- Verify cluster name is correct
- Check repository URL is correct
- Ensure paths reference the new cluster directories

## Step 5: Commit Cluster Configuration

Commit the new cluster configuration:

```bash
git add clusters/<cluster-name>/
git commit -m "Add <cluster-name> cluster configuration"
git push
```

## Step 6: Deploy Bootstrap to Cluster

Deploy the bootstrap Application to the new cluster:

```bash
kubectl apply -f clusters/<cluster-name>/bootstrap.yaml
```

The bootstrap Application will create ArgoCD Projects and parent Applications.

**For detailed bootstrap procedures, troubleshooting, and verification steps, see [Bootstrap Procedure](bootstrap-procedure.md).**

Quick verification:

```bash
kubectl get applications -n argocd
```

Expected output shows bootstrap, infrastructure, and workloads Applications all Synced and Healthy.

## Step 7: Add Applications to Cluster

Once the cluster is bootstrapped, you can add applications. See the detailed guides:

- **[Adding Applications](adding-applications.md)** - Complete guide for adding both Kustomize and Helm applications
  - Kustomize applications: Simple workloads with manifest-based configuration
  - Helm applications: Infrastructure components with upstream charts
  - Includes sync wave guidelines, testing procedures, and best practices

**Quick reference:**
1. Create application manifests (base + overlay) in `workloads/<app>/` or `infrastructure/<app>/`
2. Create ArgoCD Application CRD in `clusters/<cluster-name>/workloads/<app>.yaml` or `clusters/<cluster-name>/infrastructure/<app>.yaml`
3. Add application to `clusters/<cluster-name>/workloads/kustomization.yaml` or `clusters/<cluster-name>/infrastructure/kustomization.yaml`
4. Commit and push to Git
5. ArgoCD automatically discovers and deploys the application

## Step 8: Configure DNS and Ingress

### Get LoadBalancer IP

```bash
kubectl get svc -n ingress traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

### Update DNS

Add DNS records for the cluster applications:
- `*.{cluster-name}.confluentdemo.local` → LoadBalancer IP

Or update `/etc/hosts` for local testing:
```
<LoadBalancer-IP>  echo.<cluster-name>.confluentdemo.local
```

### Test Application

```bash
curl http://echo.<cluster-name>.confluentdemo.local
```

## Cluster-Specific Considerations

### Resource Constraints

For resource-constrained clusters, adjust:
- Replica counts in overlays
- Resource requests/limits
- Number of applications deployed

### Network Policies

If the cluster uses NetworkPolicies:
1. Allow ArgoCD to pull from GitHub
2. Allow ingress traffic to workloads
3. Allow inter-namespace communication if needed

### Storage Classes

Verify storage classes exist for persistent workloads:

```bash
kubectl get storageclass
```

Create cluster-specific storage configurations if needed.

### Ingress Controller

Ensure ingress controller is installed:
- Traefik (default for MicroK8s)
- Nginx Ingress
- Other

Adjust ingress annotations in overlays accordingly.

## Multi-Cluster Patterns

### Shared Applications

For applications deployed to all clusters:
1. Create base manifests in `workloads/<app>/base/`
2. Create overlay per cluster in `workloads/<app>/overlays/<cluster>/`
3. Reference overlay in each cluster's Application manifest

### Cluster-Specific Applications

For applications unique to one cluster:
1. Create manifests in `workloads/<app>/overlays/<cluster>/` only
2. Skip creating a base (or create minimal base)
3. Reference in that cluster's Application manifest only

### Environment Separation

Use clusters to separate environments:
- `dev` cluster - Development environment
- `staging` cluster - Staging environment
- `prod` cluster - Production environment

Use overlays to adjust:
- Replica counts
- Resource limits
- External service endpoints

## Removing a Cluster

To decommission a cluster:

### Step 1: Remove Applications

Delete all Application manifests:

```bash
rm -rf clusters/<cluster-name>/
git commit -m "Remove <cluster-name> cluster"
git push
```

### Step 2: Wait for Cleanup

ArgoCD will delete the Applications from the cluster. Monitor:

```bash
kubectl get applications -n argocd -w
```

### Step 3: Remove Bootstrap

Delete the bootstrap Application (will cascade to parent and child Applications):

```bash
kubectl delete application bootstrap -n argocd
```

Wait for all Applications to be removed:

```bash
kubectl get applications -n argocd -w
```

### Step 4: Uninstall ArgoCD (Optional)

```bash
kubectl delete namespace argocd
```

### Step 5: Clean Up Repository

The cluster directory was already removed in Step 1. Verify no orphaned files remain:

```bash
ls -la clusters/<cluster-name>/  # Should not exist
git status  # Should show clean working tree
```

## Troubleshooting

### Bootstrap Fails to Deploy

**Symptom**: `kubectl apply` fails with errors

**Solutions**:
1. Verify ArgoCD is installed:
   ```bash
   kubectl get pods -n argocd
   ```

2. Check CRDs are present:
   ```bash
   kubectl get crd applications.argoproj.io
   ```

3. Review error messages in bootstrap output

### Applications Not Syncing

**Symptom**: Applications created but not syncing

**Solutions**:
1. Verify repository access from cluster
2. Check Application path is correct
3. Ensure overlay directory exists for cluster
4. Review ArgoCD logs for errors

### Ingress Not Working

**Symptom**: Applications deployed but not accessible

**Solutions**:
1. Verify ingress controller is running:
   ```bash
   kubectl get pods -n ingress
   ```

2. Check LoadBalancer has external IP:
   ```bash
   kubectl get svc -n ingress
   ```

3. Verify DNS or `/etc/hosts` is configured
4. Test service directly:
   ```bash
   kubectl port-forward -n <namespace> svc/<service> 8080:8080
   curl http://localhost:8080
   ```

### Resource Exhaustion

**Symptom**: Pods stuck in `Pending` state

**Solutions**:
1. Check node resources:
   ```bash
   kubectl top nodes
   ```

2. Check pod resource requests:
   ```bash
   kubectl describe pod <pod-name> -n <namespace>
   ```

3. Adjust resource requests in overlays
4. Scale down or remove applications

## Best Practices

1. **Use consistent naming**: `<cluster-name>` should match across all files
2. **Test bootstrap locally**: Always run `helm template` before applying
3. **Start with minimal applications**: Add one application at a time
4. **Document cluster-specific notes**: Add README in `clusters/<cluster-name>/`
5. **Monitor resource usage**: Track CPU, memory, and storage
6. **Version control everything**: Commit all changes to Git
7. **Use automated sync**: Enable auto-sync for faster feedback

## Next Steps

After cluster onboarding:

- **Add applications**: [Adding Applications](adding-applications.md) - Add workloads and infrastructure components
- **Bootstrap operations**: [Bootstrap Procedure](bootstrap-procedure.md) - Re-bootstrap, upgrade, or troubleshoot
- **System architecture**: [Architecture](architecture.md) - Understand the overall design
- **Advanced Helm patterns**: [Adding Helm Workloads](adding-helm-workloads.md) - Complex infrastructure deployments
