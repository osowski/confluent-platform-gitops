# Design: Consolidated Ingress Applications (Issue #107)

**Date:** 2026-04-14
**Issue:** [#107](https://github.com/osowski/confluent-platform-gitops/issues/107)
**Clusters in scope:** `flink-demo`, `flink-demo-rbac`

---

## Problem Statement

IngressRoute and related ingress resources are currently spread across multiple standalone ArgoCD Applications per cluster — one Application per service (e.g., `argocd-ingress`, `vault-ingress`, `cmf-ingress`, `controlcenter-ingress`). This clutters the ArgoCD UI and makes ingress management inconsistent across clusters.

The `flink-demo-rbac` cluster partially introduced a consolidated pattern via a single `ingresses` workload Application. This design completes and standardizes the pattern across both clusters at both the infrastructure and workload layers.

---

## Design

### Two Consolidated Applications Per Cluster

Each cluster gets exactly two ingress Applications:

| ArgoCD App Name | ArgoCD Project | Manages |
|---|---|---|
| `infra-ingresses` | `infrastructure` | ArgoCD IngressRoute + Certificate + ServersTransport; Vault IngressRoute + Certificate (flink-demo only) |
| `workload-ingresses` | `workloads` | CMF IngressRoute; ControlCenter IngressRoute + Certificate; MDS IngressRoute (flink-demo-rbac only) |

### Directory Structure

#### New: `infrastructure/ingresses/`

```
infrastructure/ingresses/
├── base/
│   └── kustomization.yaml                    # empty base, resources defined per overlay
└── overlays/
    ├── flink-demo/
    │   ├── kustomization.yaml
    │   ├── argocd-ingressroute.yaml           # Host: argocd.flink-demo.confluentdemo.local
    │   ├── argocd-certificate.yaml            # cert-manager Certificate for argocd-server-tls
    │   ├── argocd-serverstransport.yaml       # ServersTransport: insecureSkipVerify for ArgoCD backend
    │   ├── vault-ingressroute.yaml            # Host: vault.flink-demo.confluentdemo.local
    │   └── vault-certificate.yaml             # cert-manager Certificate for vault-server-tls
    └── flink-demo-rbac/
        ├── kustomization.yaml
        ├── argocd-ingressroute.yaml           # Host: argocd.flink-demo-rbac.confluentdemo.local
        ├── argocd-certificate.yaml            # cert-manager Certificate for argocd-server-tls
        └── argocd-serverstransport.yaml       # ServersTransport: insecureSkipVerify for ArgoCD backend
```

#### New: `workloads/ingresses/overlays/flink-demo/`

```
workloads/ingresses/overlays/flink-demo/
├── kustomization.yaml
├── cmf-ingressroute.yaml                     # Host: cmf.flink-demo.confluentdemo.local, namespace: operator
├── controlcenter-ingressroute.yaml           # Host: controlcenter.flink-demo.confluentdemo.local, namespace: kafka, TLS
└── controlcenter-certificate.yaml            # cert-manager Certificate for controlcenter-tls, namespace: kafka
```

The existing `workloads/ingresses/overlays/flink-demo-rbac/` overlay is unchanged in content.

### Cluster Application File Changes

#### `flink-demo`

**Add** `clusters/flink-demo/infrastructure/infra-ingresses.yaml`:
- `metadata.name: infra-ingresses`
- `spec.project: infrastructure`
- `spec.source.path: infrastructure/ingresses/overlays/flink-demo`
- Sync-wave: `"80"` (same as current `argocd-ingress`)

**Add** `clusters/flink-demo/workloads/workload-ingresses.yaml`:
- `metadata.name: workload-ingresses`
- `spec.project: workloads`
- `spec.source.path: workloads/ingresses/overlays/flink-demo`
- Sync-wave: `"110"`

**Remove:**
- `clusters/flink-demo/infrastructure/argocd-ingress.yaml`
- `clusters/flink-demo/infrastructure/vault-ingress.yaml`
- `clusters/flink-demo/workloads/cmf-ingress.yaml`
- `clusters/flink-demo/workloads/controlcenter-ingress.yaml`

**Update** `clusters/flink-demo/infrastructure/kustomization.yaml`:
- Replace `argocd-ingress.yaml` and `vault-ingress.yaml` with `infra-ingresses.yaml`

**Update** `clusters/flink-demo/workloads/kustomization.yaml`:
- Replace `cmf-ingress.yaml` and `controlcenter-ingress.yaml` with `workload-ingresses.yaml`

#### `flink-demo-rbac`

**Add** `clusters/flink-demo-rbac/infrastructure/infra-ingresses.yaml`:
- `metadata.name: infra-ingresses`
- `spec.project: infrastructure`
- `spec.source.path: infrastructure/ingresses/overlays/flink-demo-rbac`
- Sync-wave: `"80"` (same as current `argocd-ingress`)

**Rename** `clusters/flink-demo-rbac/workloads/ingresses.yaml` → `workload-ingresses.yaml`:
- `metadata.name` changes from `ingresses` to `workload-ingresses`
- Path remains `workloads/ingresses/overlays/flink-demo-rbac`

**Remove:**
- `clusters/flink-demo-rbac/infrastructure/argocd-ingress.yaml`
- `clusters/flink-demo-rbac/workloads/ingresses.yaml` (replaced by `workload-ingresses.yaml`)

**Update** `clusters/flink-demo-rbac/infrastructure/kustomization.yaml`:
- Replace `argocd-ingress.yaml` with `infra-ingresses.yaml`

**Update** `clusters/flink-demo-rbac/workloads/kustomization.yaml`:
- Replace `ingresses.yaml` with `workload-ingresses.yaml`

### Old Overlay Cleanup

The following overlay directories become dead code once their parent Applications are removed. They are deleted as part of this change:

| Directory | Reason |
|---|---|
| `infrastructure/argocd-ingress/overlays/flink-demo/` | Absorbed into `infra-ingresses` |
| `infrastructure/argocd-ingress/overlays/flink-demo-rbac/` | Absorbed into `infra-ingresses` |
| `infrastructure/vault-ingress/overlays/flink-demo/` | Absorbed into `infra-ingresses` |
| `workloads/cmf-ingress/overlays/flink-demo/` | Absorbed into `workload-ingresses` |
| `workloads/controlcenter-ingress/overlays/flink-demo/` | Absorbed into `workload-ingresses` |
| `workloads/controlcenter-ingress/overlays/flink-demo-rbac/` | Already orphaned (no ArgoCD Application references it) |

**Base directories** (`infrastructure/argocd-ingress/base/`, `infrastructure/vault-ingress/base/`, `workloads/cmf-ingress/base/`, `workloads/controlcenter-ingress/base/`) are left in place; they can be removed in a follow-up cleanup PR once confirmed no future cluster onboarding requires them.

### AppProject Impact

**No changes required** to the bootstrap Helm chart or AppProject definitions:
- `infrastructure` AppProject: wildcard `*` on both `clusterResourceWhitelist` and `namespaceResourceWhitelist` — covers `traefik.io/ServersTransport` and all other types.
- `workloads` AppProject: already explicitly whitelists `traefik.io/IngressRoute` and `cert-manager.io/Certificate`.

### Sync-Wave Ordering

No changes to sync-wave ordering. Infra ingresses remain at wave `80`; workload ingresses remain at wave `110`.

---

## Resource Inventory by Overlay

### `infrastructure/ingresses/overlays/flink-demo`

| Resource | Kind | Namespace | Source |
|---|---|---|---|
| `argocd-server` | IngressRoute | `argocd` | `infrastructure/argocd-ingress/overlays/flink-demo/ingressroute-patch.yaml` |
| `argocd-server-tls` | Certificate | `argocd` | `infrastructure/argocd-ingress/overlays/flink-demo/certificate-patch.yaml` |
| `argocd-server-insecure-transport` | ServersTransport | `argocd` | `infrastructure/argocd-ingress/base/serverstransport.yaml` |
| `vault-server` | IngressRoute | `vault` | `infrastructure/vault-ingress/overlays/flink-demo/ingressroute-patch.yaml` |
| `vault-server-tls` | Certificate | `vault` | `infrastructure/vault-ingress/overlays/flink-demo/certificate-patch.yaml` |

### `infrastructure/ingresses/overlays/flink-demo-rbac`

| Resource | Kind | Namespace | Source |
|---|---|---|---|
| `argocd-server` | IngressRoute | `argocd` | `infrastructure/argocd-ingress/overlays/flink-demo-rbac/ingressroute-patch.yaml` |
| `argocd-server-tls` | Certificate | `argocd` | `infrastructure/argocd-ingress/overlays/flink-demo-rbac/certificate-patch.yaml` |
| `argocd-server-insecure-transport` | ServersTransport | `argocd` | `infrastructure/argocd-ingress/base/serverstransport.yaml` |

### `workloads/ingresses/overlays/flink-demo`

| Resource | Kind | Namespace | Source |
|---|---|---|---|
| `cmf` | IngressRoute | `operator` | `workloads/cmf-ingress/overlays/flink-demo/ingressroute-patch.yaml` |
| `controlcenter` | IngressRoute | `kafka` | `workloads/controlcenter-ingress/overlays/flink-demo/ingressroute-patch.yaml` (+ base entryPoints/TLS) |
| `controlcenter-tls` | Certificate | `kafka` | `workloads/controlcenter-ingress/overlays/flink-demo/certificate-patch.yaml` |

---

## Success Criteria

1. Both clusters have exactly two ingress Applications (`infra-ingresses`, `workload-ingresses`) and zero standalone ingress Applications.
2. All previously deployed IngressRoutes, Certificates, and ServersTransports continue to function identically after the migration.
3. No orphaned overlay directories remain for the removed Applications.
4. AppProject definitions require no changes.
