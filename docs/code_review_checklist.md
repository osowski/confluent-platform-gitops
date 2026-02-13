# Code Review Checklist

This checklist contains ArgoCD/GitOps-specific checks for the confluent-platform-gitops repository. Review these items **before** creating a pull request.

> **For shared security practices, code quality guidelines, Git workflow, and common development practices, see the [homelab-docs code review checklist](https://github.com/osowski/homelab-docs/blob/main/docs/guides/code-review-checklist.md).**

## Security

### Repository Access
- [ ] ArgoCD repository credentials are configured securely
- [ ] No sensitive values are exposed in Helm values files or Kustomize overlays

## Code Quality

### Manifest Validation
- [ ] YAML syntax is valid for all modified manifests
- [ ] Kustomize overlays build successfully: `kubectl kustomize overlays/<cluster>/`
- [ ] Helm templates render correctly: `helm template <release> <chart> -f values.yaml`
- [ ] ArgoCD Application manifests reference correct `repoURL`, `path`, and `targetRevision`

### Sync Wave Ordering
- [ ] Sync wave annotations are set correctly for deployment ordering
- [ ] Dependencies deploy before dependents (e.g., CRDs before resources, operator before CRs)
- [ ] No circular dependencies between sync waves
- [ ] Wave numbers follow established conventions (see [Architecture - Sync Waves](architecture.md#sync-waves))

### Kustomize
- [ ] `kustomization.yaml` lists all resources
- [ ] Patches target the correct resources (group, version, kind, name)
- [ ] Base manifests are cluster-agnostic; cluster-specific values are in overlays
- [ ] Labels and annotations are applied consistently

### Helm
- [ ] Multi-source pattern is used correctly (`$values` reference resolves)
- [ ] Base values and cluster overlay values are properly separated
- [ ] Chart version is pinned in Application manifest (`targetRevision`)
- [ ] Namespace is specified and `CreateNamespace=true` is set if needed

### ArgoCD Applications
- [ ] Application belongs to the correct ArgoCD Project (`infrastructure` or `workloads`)
- [ ] `destination.namespace` is set correctly
- [ ] Sync policy includes `automated`, `prune`, and `selfHeal` where appropriate
- [ ] `ServerSideApply=true` is set for applications managing CRDs
- [ ] Application is added to the cluster's `kustomization.yaml`

### Idempotency
- [ ] Manifests can be applied multiple times without errors
- [ ] Resources use declarative configuration (no imperative operations)
- [ ] Kustomize patches are idempotent

## Documentation

### Required Documentation Updates
When implementing features, update these files in `/docs`:

- [ ] **`docs/architecture.md`** - If changing system design, adding components, or modifying sync waves
- [ ] **`docs/changelog.md`** - Always update with new features, fixes, and changes
- [ ] **`README.md`** - If adding new prerequisites, clusters, or applications

### Architecture Decision Records
- [ ] Create ADR in `/adrs/` for architectural decisions that impact future development
- [ ] ADRs follow the format from [homelab-docs ADR template](https://github.com/osowski/homelab-docs/blob/main/adrs/0000-template.md)
- [ ] ADRs are referenced in relevant documentation files

> **For Git workflow, branch naming, PR descriptions, and commit guidelines, see the [homelab-docs code review checklist](https://github.com/osowski/homelab-docs/blob/main/docs/guides/code-review-checklist.md#git-and-github).**

## Testing and Verification

### Before Creating PR
- [ ] Validate Kustomize builds for all affected clusters: `kubectl kustomize <path>/overlays/<cluster>/`
- [ ] Validate Helm templates render without errors: `helm template <release> <chart> -f <values>`
- [ ] Check YAML syntax for all modified files
- [ ] Verify ArgoCD Application manifests are valid
- [ ] Review sync wave ordering for new or modified applications

### Edge Cases
- [ ] Test with minimal and maximal configurations
- [ ] Verify namespace creation for new applications
- [ ] Ensure resource limits and requests are specified
- [ ] Check that ingress hostnames follow naming conventions: `<service>.<cluster>.<domain>`

## Common Pitfalls (from Past Reviews)

These specific issues have been caught in previous code reviews:

1. **Missing `kustomization.yaml` entry** - New applications must be added to `clusters/<cluster>/<layer>/kustomization.yaml` or the parent Application will not discover them
2. **Wrong ArgoCD Project** - Infrastructure components (cluster-scoped resources) must use the `infrastructure` project; workloads use `workloads`
3. **Sync wave ordering** - CRDs must deploy before resources that use them (e.g., cert-manager before ClusterIssuer, CFK operator before Confluent resources)
4. **Multi-source `$values` reference** - The Git source must use `ref: values` for the `$values` prefix to resolve in Helm value file paths
5. **Documentation not updated** - Always update `/docs` for major features
6. **Branch naming wrong** - Must follow `feature-<id>/` or `fix-<id>/` pattern
7. **PR description inaccurate** - Ensure specs match actual implementation
8. **Missing `ServerSideApply=true`** - Required for applications that manage CRDs to avoid field ownership conflicts
9. **Hardcoded cluster values in base** - Base manifests should use placeholders or be cluster-agnostic; cluster-specific values belong in overlays
10. **MicroK8s ingress controller is Traefik, not NGINX** - Since MicroK8s v1.28+, the default ingress controller is Traefik (service: `traefik` in namespace `ingress`), not NGINX
