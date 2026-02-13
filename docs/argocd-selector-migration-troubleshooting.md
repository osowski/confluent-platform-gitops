# Argo CD Selector Migration Troubleshooting

**Context:** This document addresses issues specific to transitioning a manually-installed Argo CD instance to Helm-based self-management in homelab/demo environments.

## Why Force=true Might Not Work

Based on [GitHub Issue #14910](https://github.com/argoproj/argo-cd/issues/14910), there are several reasons why `Force=true` at the Application level may not successfully delete and recreate Deployments:

### 1. Argo CD May Not Detect the Difference

When comparing Helm-generated manifests with existing resources, Argo CD might not properly detect immutable field differences in selectors. The diff algorithm may skip immutable fields, preventing the OutOfSync status that would trigger Force behavior.

**Diagnostic:**
```bash
# Check if Application shows as OutOfSync
kubectl get application argocd -n argocd -o jsonpath='{.status.sync.status}'

# Force a hard refresh and check diff
argocd app diff argocd --hard-refresh
```

### 2. Helm Three-Way Merge Conflicts

Helm uses three-way strategic merge patches. When Argo CD applies Helm charts to existing manually-installed resources, the merge may fail silently or skip immutable fields rather than triggering deletion.

### 3. Self-Management Safety

Argo CD may have implicit protections against deleting its own critical components (like argocd-server) even with Force=true, to prevent the server from terminating mid-sync.

## Solution 1: Resource-Level Annotations (Recommended)

Add sync annotations directly to each Deployment via Helm values. This is more explicit than Application-level options.

**Implementation:**
Already configured in `infrastructure/argocd/base/values.yaml`:
```yaml
server:
  deploymentAnnotations:
    argocd.argoproj.io/sync-options: "Force=true,Replace=true"
```

**How to apply:**
```bash
git add infrastructure/argocd/base/values.yaml
git commit -m "Add resource-level Force=true annotations for Deployments"
git push

# Sync the Application
kubectl patch application argocd -n argocd --type merge -p '{"operation":{"sync":{}}}'
```

**Verification:**
```bash
# Check if annotations appear on rendered manifests
kubectl get deployment argocd-server -n argocd -o jsonpath='{.metadata.annotations}'
```

## Solution 2: PreSync Hook (Most Reliable)

Use an Argo CD Sync Hook to explicitly delete Deployments before the main sync.

**How it works:**
1. PreSync hook Job runs first
2. Deletes all Argo CD Deployments
3. Hook completes successfully
4. Main sync creates new Deployments with correct selectors

**Implementation:**

The PreSync hook is available at `infrastructure/argocd/base/presync-delete-deployments.yaml`.

**To enable it, you have two options:**

### Option A: Include in Helm Chart (Permanent)
```bash
# Move the hook to Helm templates so it's always included
mkdir -p infrastructure/argocd/base/templates
mv infrastructure/argocd/base/presync-delete-deployments.yaml \
   infrastructure/argocd/base/templates/

# Commit and push
git add infrastructure/argocd/base/templates/
git commit -m "Add PreSync hook for Deployment migration"
git push
```

### Option B: Manual One-Time Application
```bash
# Apply the hook manually before syncing the Application
kubectl apply -f infrastructure/argocd/base/presync-delete-deployments.yaml

# Wait for it to complete
kubectl wait --for=condition=complete job/argocd-presync-delete-deployments -n argocd --timeout=60s

# Now sync the Application
kubectl patch application argocd -n argocd --type merge -p '{"operation":{"sync":{}}}'
```

## Solution 3: Manual Deletion (Fallback)

If automation fails, manually delete Deployments and let Argo CD recreate them:

```bash
# Delete all Deployments
kubectl delete deployment -n argocd \
  argocd-server \
  argocd-repo-server \
  argocd-redis \
  argocd-applicationset-controller \
  argocd-notifications-controller \
  argocd-dex-server

# Delete StatefulSet
kubectl delete statefulset argocd-application-controller -n argocd

# Trigger sync
kubectl patch application argocd -n argocd --type merge -p '{"operation":{"sync":{}}}'
```

**Expected downtime:** 1-3 minutes for Argo CD UI/API only.

## Common Error: ServerSideApply Schema Validation

**Error:**
```
ComparisonError: Failed to compare desired state to live state: failed to calculate diff:
error calculating structured merge diff: error building typed value from live resource:
.status.terminatingReplicas: field not declared in schema
```

**Cause:**
- `ServerSideApply=true` performs strict OpenAPI schema validation
- Runtime status fields like `.status.terminatingReplicas` exist in live resources but aren't in the schema
- Conflicts with `Force=true` strategy (delete/recreate vs incremental patching)

**Solution:**
Remove `ServerSideApply=true` from the Application sync options. This is already configured in `clusters/flink-demo/infrastructure/argocd.yaml`.

**Note for production:** After the initial migration is complete, you can re-enable ServerSideApply and remove Force=true for normal operations. For this demo/homelab environment, we keep ServerSideApply disabled to simplify the self-management transition.

## Recommended Approach

1. **First try**: Resource-level annotations (Solution 1)
2. **If that fails**: Use PreSync Hook Option B (one-time manual)
3. **Last resort**: Manual deletion (Solution 3)
4. **If you get schema validation errors**: Remove ServerSideApply (see above)

## Verification After Migration

After successfully migrating:

```bash
# Verify Deployments have correct selectors
for deploy in argocd-server argocd-repo-server argocd-redis; do
  echo "=== $deploy ==="
  kubectl get deployment $deploy -n argocd -o jsonpath='{.spec.selector.matchLabels}' | jq
done

# Expected output includes both:
# - app.kubernetes.io/name: <component>
# - app.kubernetes.io/instance: argocd

# Verify Services can select pods
kubectl get endpoints -n argocd | grep argocd-server
```

## Post-Migration: Remove Force Annotations

Once migration is complete, **remove the Force=true annotations** to prevent unnecessary deletions on every sync:

```bash
# Edit values.yaml and remove deploymentAnnotations with Force=true
# Commit and push
```

**Why?** Force=true causes deletion/recreation on EVERY sync, not just when needed. This wastes resources and causes unnecessary downtime.

## References

- [Argo CD Issue #14910](https://github.com/argoproj/argo-cd/issues/14910) - Replace=true and immutable fields
- [Argo CD Sync Options](https://argo-cd.readthedocs.io/en/latest/user-guide/sync-options/)
- [Handle immutable fields in Kubernetes with ArgoCD](https://medium.com/@paolocarta_it/handle-immutable-fields-in-kubernetes-with-argocd-0910253d566e)
