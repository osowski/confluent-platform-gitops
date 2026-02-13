# ArgoCD Self-Management Guide

> **⚠️ FUTURE STATE TARGET - NOT CURRENTLY IMPLEMENTED**
>
> This document describes a **future state architecture** for ArgoCD self-management via GitOps.
>
> **Current State:**
> - ArgoCD is manually installed via `kubectl apply -f manual-argocd-install.yaml`
> - ArgoCD configuration is managed manually, not via Git
> - ArgoCD UI access is provided via the `argocd-ingress` Application (Traefik IngressRoute)
>
> **Why Deferred:**
> - Focus on deploying infrastructure components first (cert-manager, monitoring, ingress)
> - Manual installation is simpler for initial cluster setup
> - Self-management adds complexity with immutable field challenges
> - This documentation is preserved for future reference when ready to transition
>
> **When to Implement:**
> - After infrastructure components are stable and validated
> - When ready to manage ArgoCD configuration declaratively via Git
> - When comfortable with the transition procedure and potential downtime

---

## Table of Contents

1. [Overview](#overview)
2. [Problem Statement](#problem-statement)
3. [Solution Overview](#solution-overview)
4. [Prerequisites](#prerequisites)
5. [Transition Procedure](#transition-procedure)
6. [Troubleshooting](#troubleshooting)
7. [Post-Migration](#post-migration)
8. [References](#references)

---

## Overview

ArgoCD self-management allows ArgoCD to manage its own deployment and configuration through GitOps. This follows the principle where ArgoCD:

1. **Initial Bootstrap**: Manually installed via Helm or kubectl (chicken-and-egg requirement)
2. **Self-Management**: ArgoCD Application manifest deploys and manages ArgoCD via the official Helm chart
3. **Declarative Updates**: Configuration changes are made through Git commits, not manual kubectl commands

**Benefits:**
- Consistent GitOps workflow for all infrastructure
- Version-controlled ArgoCD configuration
- Automated updates and rollbacks
- Audit trail for all changes

**Architecture:**
- Helm chart: `argo-cd` from `https://argoproj.github.io/argo-helm`
- Base values: `infrastructure/argocd/base/values.yaml`
- Cluster overlays: `infrastructure/argocd/overlays/<cluster>/values.yaml`
- Application manifest: `clusters/<cluster>/infrastructure/argocd.yaml`
- Sync wave: `5` (early deployment, before other infrastructure)

---

## Problem Statement

### Challenge: Immutable Kubernetes Fields

Kubernetes Deployment selectors are **immutable** - once created, they cannot be changed.

**Manual installation** creates Deployments with selector:
```yaml
selector:
  matchLabels:
    app.kubernetes.io/name: argocd-server
```

**Helm chart** requires selector:
```yaml
selector:
  matchLabels:
    app.kubernetes.io/name: argocd-server
    app.kubernetes.io/instance: argocd
```

Since selectors cannot be changed, existing Deployments must be deleted and recreated during the transition.

### Impact

- **Downtime**: Brief ArgoCD UI/API unavailability during Deployment recreation (1-3 minutes)
- **Service Disruption**: Pods are deleted and recreated with new labels
- **Endpoint Mismatch**: Services cannot select pods until new selectors are applied

---

## Solution Overview

### Automated via Force=true

The Application manifest uses `Force=true` sync option to automatically:
1. Detect immutable field conflicts
2. Delete existing resources
3. Create new resources with correct configuration

### Sync Options Configuration

For this self-managed demo environment:

| Option | Enabled | Purpose |
|--------|---------|---------|
| `CreateNamespace=true` | ✅ | Ensures argocd namespace exists |
| `Replace=true` | ✅ | Handles large resource specifications |
| `Force=true` | ✅ | Deletes/recreates resources with immutable conflicts |
| `ServerSideApply` | ❌ | **Disabled** - conflicts with Force and causes schema validation errors |

**Why ServerSideApply is disabled:**
- Performs strict schema validation that fails on runtime status fields (e.g., `.status.terminatingReplicas`)
- Force=true uses delete/recreate strategy, making ServerSideApply's incremental patching unnecessary
- These strategies are mutually exclusive - using both causes validation errors
- **For production:** Re-enable ServerSideApply after transition and remove Force=true

### Preserving Secrets

The Helm values include `configs.secret.createSecret: false` to preserve existing secrets:
- `argocd-secret` - Admin password and authentication tokens
- `argocd-redis` - Redis authentication
- `argocd-notifications-secret` - Notification integrations

---

## Prerequisites

Before transitioning to self-management:

- ✅ Manual ArgoCD installation already running
- ✅ Bootstrap Application deployed and syncing
- ✅ Infrastructure components stable (traefik, cert-manager)
- ✅ Application manifest committed to Git with `Force=true` sync option
- ✅ Values configured with `configs.secret.createSecret: false` to preserve secrets
- ✅ Git repository access configured in ArgoCD
- ✅ Backup of current ArgoCD configuration (optional but recommended)

---

## Transition Procedure

### Step 1: Verify Current State

```bash
# Verify ArgoCD is running
kubectl get deployments -n argocd

# Check current Deployment selectors (should NOT have instance label)
kubectl get deployment argocd-server -n argocd -o jsonpath='{.spec.selector}'
```

Expected: Selector WITHOUT `app.kubernetes.io/instance`.

### Step 2: Prepare Application Manifest

Ensure the Application manifest is ready at `clusters/<cluster>/infrastructure/argocd.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  project: infrastructure
  sources:
    - repoURL: https://argoproj.github.io/argo-helm
      targetRevision: 7.7.14
      chart: argo-cd
      helm:
        valueFiles:
          - $values/infrastructure/argocd/base/values.yaml
          - $values/infrastructure/argocd/overlays/<cluster>/values.yaml
    - repoURL: https://github.com/osowski/confluent-platform-gitops
      targetRevision: HEAD
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - Replace=true
      - Force=true
  ignoreDifferences:
    - group: ""
      kind: Secret
      name: argocd-secret
      jsonPointers:
        - /data
```

### Step 3: Apply Self-Management Application

The `Force=true` sync option automatically handles deletion and recreation.

```bash
# Apply the Application manifest
kubectl apply -f clusters/<cluster>/infrastructure/argocd.yaml

# Watch the sync process
kubectl get applications -n argocd argocd -w
```

**Expected behavior:**
1. ArgoCD detects selector mismatch
2. Deletes existing Deployments (brief downtime)
3. Creates new Deployments with correct selectors
4. Pods start with correct labels
5. Services select pods successfully

### Step 4: Verify Recreation

```bash
# Watch Deployments being recreated
kubectl get deployments -n argocd -w

# Verify new selectors include instance label
kubectl get deployment argocd-server -n argocd -o jsonpath='{.spec.selector}' | jq
```

Expected output:
```json
{
  "matchLabels": {
    "app.kubernetes.io/name": "argocd-server",
    "app.kubernetes.io/instance": "argocd"
  }
}
```

### Step 5: Verify Service Endpoints

```bash
# Check Services can now select pods
kubectl get endpoints -n argocd

# All services should have endpoints
```

### Step 6: Test Access

```bash
# Test via Ingress (if argocd-ingress is deployed)
curl -k https://argocd.<cluster>.<domain>

# Or port forward
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

---

## Troubleshooting

### Issue: Force=true Not Working

Based on [GitHub Issue #14910](https://github.com/argoproj/argo-cd/issues/14910), `Force=true` at the Application level may fail for several reasons:

#### Cause 1: Diff Not Detected

ArgoCD's diff algorithm may skip immutable fields, preventing OutOfSync status.

**Diagnostic:**
```bash
# Check sync status
kubectl get application argocd -n argocd -o jsonpath='{.status.sync.status}'

# Force hard refresh
argocd app diff argocd --hard-refresh
```

#### Cause 2: Helm Merge Conflicts

Helm's three-way merge may skip immutable fields rather than triggering deletion.

#### Cause 3: Self-Management Protection

ArgoCD may protect against deleting its own critical components.

### Solution 1: Resource-Level Annotations

Add sync annotations directly to Deployments via Helm values (more explicit than Application-level).

**Configure in `infrastructure/argocd/base/values.yaml`:**
```yaml
server:
  deploymentAnnotations:
    argocd.argoproj.io/sync-options: "Force=true,Replace=true"

controller:
  statefulsetAnnotations:
    argocd.argoproj.io/sync-options: "Force=true,Replace=true"

repoServer:
  deploymentAnnotations:
    argocd.argoproj.io/sync-options: "Force=true,Replace=true"
```

**Apply:**
```bash
git add infrastructure/argocd/base/values.yaml
git commit -m "Add resource-level Force annotations"
git push

kubectl patch application argocd -n argocd --type merge -p '{"operation":{"sync":{}}}'
```

### Solution 2: PreSync Hook

Use a Sync Hook to explicitly delete Deployments before sync.

**Create `infrastructure/argocd/base/presync-delete-deployments.yaml`:**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: argocd-presync-delete-deployments
  namespace: argocd
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  template:
    spec:
      serviceAccountName: argocd-application-controller
      containers:
        - name: delete-deployments
          image: bitnami/kubectl:latest
          command:
            - /bin/sh
            - -c
            - |
              kubectl delete deployment -n argocd \
                argocd-server \
                argocd-repo-server \
                argocd-redis \
                argocd-applicationset-controller \
                argocd-notifications-controller \
                argocd-dex-server || true
              kubectl delete statefulset argocd-application-controller -n argocd || true
      restartPolicy: Never
  backoffLimit: 2
```

**One-time manual application:**
```bash
# Apply hook
kubectl apply -f infrastructure/argocd/base/presync-delete-deployments.yaml

# Wait for completion
kubectl wait --for=condition=complete job/argocd-presync-delete-deployments -n argocd --timeout=60s

# Sync
kubectl patch application argocd -n argocd --type merge -p '{"operation":{"sync":{}}}'
```

### Solution 3: Manual Deletion

If automation fails completely:

```bash
# Delete Deployments
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

**Downtime:** 1-3 minutes (ArgoCD UI/API only)

### Common Error: ServerSideApply Schema Validation

**Error message:**
```
ComparisonError: Failed to compare desired state to live state: failed to calculate diff:
error calculating structured merge diff: error building typed value from live resource:
.status.terminatingReplicas: field not declared in schema
```

**Cause:**
- `ServerSideApply=true` validates against OpenAPI schema
- Runtime status fields exist in live resources but not in schema
- Conflicts with `Force=true` strategy

**Solution:**
Remove `ServerSideApply=true` from sync options in the Application manifest.

---

## Post-Migration

### What Was Preserved

- ✅ Secrets (argocd-secret, argocd-redis, argocd-notifications-secret)
- ✅ ConfigMaps (now managed by Helm)
- ✅ Services (updated with new selectors)
- ✅ Admin password and authentication

### What Was Recreated

- ✅ Deployments (with new immutable selectors)
- ✅ Pods (with instance labels)
- ✅ StatefulSet for application-controller

### Verification

```bash
# Verify all Deployments have correct selectors
for deploy in argocd-server argocd-repo-server argocd-redis; do
  echo "=== $deploy ==="
  kubectl get deployment $deploy -n argocd -o jsonpath='{.spec.selector.matchLabels}' | jq
done

# Expected: Both app.kubernetes.io/name AND app.kubernetes.io/instance

# Verify Service endpoints
kubectl get endpoints -n argocd | grep argocd-server
```

### Remove Force Annotations

Once migration is complete, **remove Force=true annotations** to prevent unnecessary deletions:

```bash
# Edit infrastructure/argocd/base/values.yaml
# Remove deploymentAnnotations and statefulsetAnnotations with Force=true
git commit -m "Remove Force annotations post-migration"
git push
```

**Why?** Force=true causes deletion/recreation on EVERY sync, wasting resources and causing unnecessary downtime.

### Update Kustomization

Add the argocd Application to the cluster's infrastructure kustomization:

```bash
# Edit clusters/<cluster>/infrastructure/kustomization.yaml
# Uncomment or add argocd.yaml to resources list
git commit -m "Enable ArgoCD self-management"
git push
```

### Rollback (if needed)

If issues occur, revert to manual installation:

```bash
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

---

## References

- [ArgoCD Sync Options Documentation](https://argo-cd.readthedocs.io/en/latest/user-guide/sync-options/)
- [GitHub Issue #14910 - Replace=true and immutable fields](https://github.com/argoproj/argo-cd/issues/14910)
- [Handle immutable fields in Kubernetes with ArgoCD](https://medium.com/@paolocarta_it/handle-immutable-fields-in-kubernetes-with-argocd-0910253d566e)
- [ArgoCD Self-Management Guide](https://www.teracloud.io/single-post/self-managed-argocd-wait-argocd-can-manage-itself)
- [ArgoCD Official Documentation](https://argo-cd.readthedocs.io/)

---

## Summary

This guide describes the **future state** transition from manual ArgoCD installation to GitOps self-management. The transition involves:

1. Using `Force=true` sync option to handle immutable field conflicts
2. Deleting and recreating Deployments with new selectors
3. Preserving secrets to maintain authentication
4. Verifying successful recreation and service endpoints

**Current Recommendation:** Keep ArgoCD as a manual installation until infrastructure components are stable. When ready to transition, follow this guide carefully and expect 1-3 minutes of ArgoCD UI downtime during the migration.
