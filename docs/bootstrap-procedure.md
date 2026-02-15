# Bootstrap Procedure

This document describes the procedure for deploying the bootstrap Application to a cluster that already has ArgoCD installed.

**For complete cluster onboarding** (including ArgoCD installation and cluster setup), see [Cluster Onboarding](cluster-onboarding.md).

## Prerequisites

### Cluster Requirements

- Kubernetes cluster (1.25+)
- ArgoCD installed in `argocd` namespace
  - Manual installation required for initial bootstrap (chicken-and-egg)
  - After bootstrap, ArgoCD will manage itself through the self-management Application
- `kubectl` configured with admin access
- `helm` CLI installed (3.x)

### Installation Verification

Verify ArgoCD is installed:

```bash
kubectl get pods -n argocd
```

Expected output: All ArgoCD pods in `Running` state.

### Repository Access

Clone this repository:

```bash
git clone https://github.com/osowski/confluent-platform-gitops.git
cd confluent-platform-gitops
```

## Bootstrap Steps

### Step 1: Prepare Cluster Bootstrap Application

For a new cluster, create a bootstrap Application manifest:

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

The `valuesObject` provides cluster-specific configuration inline, eliminating the need for separate values files.

### Step 2: Validate Bootstrap Application

Test the Application manifest is valid:

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

Review the output for correctness:
- ArgoCD Projects created (infrastructure, workloads)
- Parent Applications created (infrastructure, workloads)
- Correct cluster name and repository URL

### Step 3: Apply Bootstrap

Deploy the bootstrap Application:

```bash
kubectl apply -f clusters/<cluster-name>/bootstrap.yaml
```

Expected output:
```
application.argoproj.io/bootstrap created
```

The bootstrap Application will then create:
- ArgoCD Projects (infrastructure, workloads)
- Parent Applications (infrastructure, workloads)

### Step 4: Verify Bootstrap Application

First, check that the bootstrap Application synced:

```bash
kubectl get application bootstrap -n argocd
```

Expected output:
```
NAME        SYNC STATUS   HEALTH STATUS
bootstrap   Synced        Healthy
```

Then verify parent Applications were created:

```bash
kubectl get applications -n argocd
```

Expected output:
```
NAME             SYNC STATUS   HEALTH STATUS
bootstrap        Synced        Healthy
infrastructure   Synced        Healthy
workloads        Synced        Healthy
```

### Step 5: Wait for Child Applications

Parent Applications will create child Applications. Monitor:

```bash
kubectl get applications -n argocd -w
```

You should see child Applications appear as they're discovered in `clusters/<cluster-name>/` directories.

### Step 6: Verify Application Sync

Check that all applications are syncing:

```bash
kubectl get applications -n argocd -o wide
```

Look for:
- `SYNC STATUS`: Should be `Synced` or `Syncing`
- `HEALTH STATUS`: Should be `Healthy` or `Progressing`

### Step 7: Check Application Workloads

Verify that actual resources are deployed:

```bash
# List all namespaces created by applications
kubectl get namespaces

# Check pods in a specific application namespace
kubectl get pods -n <app-namespace>
```

## Accessing ArgoCD UI

### Port Forward (Development)

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Access at: https://localhost:8080

### Get Admin Password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

Login with username `admin` and the password from above.

### Ingress Access (Production)

ArgoCD UI access is provided via the **argocd-ingress** Application:
- Traefik IngressRoute deployed via Kustomize (sync-wave 80)
- Hostname: `argocd.<cluster>.<domain>` (e.g., `argocd.flink-demo.confluentdemo.local`)
- TLS certificates managed by cert-manager
- ServersTransport configured for internal HTTPS communication
- See `infrastructure/argocd-ingress/` for configuration details

Once the argocd-ingress Application is synced, access ArgoCD at the configured hostname (e.g., https://argocd.flink-demo.confluentdemo.local).

## Troubleshooting

### Bootstrap Application Not Created

**Symptom**: `helm template` succeeds but `kubectl apply` fails

**Solutions**:
1. Verify ArgoCD CRDs are installed:
   ```bash
   kubectl get crd applications.argoproj.io
   kubectl get crd appprojects.argoproj.io
   ```

2. Check ArgoCD is running:
   ```bash
   kubectl get pods -n argocd
   ```

3. Review ArgoCD logs:
   ```bash
   kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller
   ```

### Parent Applications Not Syncing

**Symptom**: `infrastructure` or `workloads` shows `OutOfSync`

**Solutions**:
1. Check repository access:
   ```bash
   kubectl describe application infrastructure -n argocd
   ```

2. Verify path exists in repository:
   ```bash
   ls -la clusters/<cluster-name>/infrastructure/
   ls -la clusters/<cluster-name>/workloads/
   ```

3. Verify kustomization.yaml files exist:
   ```bash
   cat clusters/<cluster-name>/infrastructure/kustomization.yaml
   cat clusters/<cluster-name>/workloads/kustomization.yaml
   ```

4. Manually sync from CLI:
   ```bash
   kubectl patch application infrastructure -n argocd \
     --type merge -p '{"operation":{"sync":{}}}'
   ```

### Child Applications Not Created

**Symptom**: Parent apps are synced but child apps don't appear

**Solutions**:
1. Verify directory contains valid Application manifests:
   ```bash
   kubectl apply --dry-run=client -f clusters/<cluster>/workloads/<app>.yaml
   ```

2. Check parent Application logs:
   ```bash
   kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller \
     | grep infrastructure-apps
   ```

3. Verify the application is listed in kustomization.yaml:
   ```bash
   grep <app>.yaml clusters/<cluster>/infrastructure/kustomization.yaml
   ```

4. Force parent Application to refresh:
   ```bash
   kubectl delete application infrastructure -n argocd
   # Wait for bootstrap to recreate it
   kubectl get application infrastructure -n argocd -w
   ```

### Application Stuck in Progressing

**Symptom**: Application shows `Progressing` but never becomes `Healthy`

**Solutions**:
1. Check pod status:
   ```bash
   kubectl get pods -n <app-namespace>
   kubectl describe pod <pod-name> -n <app-namespace>
   ```

2. Review pod logs:
   ```bash
   kubectl logs <pod-name> -n <app-namespace>
   ```

3. Check ArgoCD Application health:
   ```bash
   kubectl describe application <app-name> -n argocd
   ```

### Repository Authentication Failed

**Symptom**: Applications show "failed to fetch repo" errors

**Solutions**:
1. Verify repository URL is correct in values file
2. Check ArgoCD can reach GitHub:
   ```bash
   kubectl exec -n argocd <argocd-server-pod> -- \
     curl -I https://github.com/osowski/confluent-platform-gitops.git
   ```

3. If using private repo, configure credentials:
   ```bash
   kubectl create secret generic repo-credentials -n argocd \
     --from-literal=url=https://github.com/osowski/confluent-platform-gitops.git \
     --from-literal=password=<token> \
     --from-literal=username=<username>
   ```

## Re-Bootstrapping

To re-apply the bootstrap (safe, idempotent):

```bash
kubectl apply -f clusters/<cluster-name>/bootstrap.yaml
```

This is safe to run multiple times. The bootstrap Application will update its managed resources (Projects and parent Applications) if changes are detected.

## Removing Bootstrap

To remove all ArgoCD Applications (WARNING: destructive):

```bash
# Delete bootstrap Application (will cascade to everything)
kubectl delete application bootstrap -n argocd

# If needed, manually delete Projects
kubectl delete appproject infrastructure -n argocd
kubectl delete appproject workloads -n argocd
```

**Note**: Deleting the bootstrap Application will delete parent Applications, which will cascade to child Applications. Due to the finalizers, ArgoCD will clean up managed resources. This process may take several minutes.

## Deploying a Specific Version

To deploy a known-good release instead of tracking `HEAD`, set `targetRevision` to a release tag in the bootstrap Application:

```yaml
spec:
  source:
    repoURL: https://github.com/osowski/confluent-platform-gitops.git
    targetRevision: v0.2.0
    path: bootstrap
```

At the tagged commit, all child Application manifests also reference `v0.2.0`, so the entire deployment stack is version-pinned.

For the full version pinning workflow, see [Release Process](release-process.md).

## Upgrading Bootstrap

To update the bootstrap configuration:

### Option 1: Update Bootstrap Application (cluster-specific changes)

1. Edit `clusters/<cluster-name>/bootstrap.yaml`
2. Commit and push to Git
3. ArgoCD will automatically sync the changes

### Option 2: Update Bootstrap Helm Chart (affects all clusters)

1. Make changes to `bootstrap/` files (templates, values.yaml)
2. Test locally:
   ```bash
   helm template bootstrap ./bootstrap/ \
     --set cluster.name=<cluster-name> \
     --set cluster.domain=confluentdemo.local
   ```

3. Commit and push to Git
4. The bootstrap Application will automatically detect and apply changes
5. Verify Applications updated:
   ```bash
   kubectl get applications -n argocd
   ```

## Post-Bootstrap Tasks

After successful bootstrap:

1. **Verify all applications synced**:
   ```bash
   kubectl get applications -n argocd
   ```

2. **Check application health**:
   ```bash
   kubectl get pods --all-namespaces
   ```

3. **Test application endpoints**:
   ```bash
   # Get LoadBalancer IP
   kubectl get svc -n ingress traefik

   # Update /etc/hosts with application FQDNs
   # Test with curl
   ```

4. **Configure ArgoCD notifications** (optional):
   - Slack, email, or webhook notifications for sync events

5. **Set up monitoring** (optional):
   - Monitor ArgoCD Application sync status
   - Alert on OutOfSync or Degraded states

## Next Steps

After successful bootstrap:

- **Add applications to the cluster**: [Adding Applications](adding-applications.md)
- **Set up additional clusters**: [Cluster Onboarding](cluster-onboarding.md)
- **Deploy a specific version**: [Release Process](release-process.md)
- **Review system architecture**: [Architecture](architecture.md)
- **Learn advanced Helm patterns**: [Adding Helm Workloads](adding-helm-workloads.md)
