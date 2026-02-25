# Code Review Checklist

This checklist contains all checks for the confluent-platform-gitops repository — including shared development practices and ArgoCD/GitOps-specific items. Review these items **before** creating a pull request.

## Security

### Secrets and Credentials

- [ ] No secrets, API keys, or tokens are hardcoded in any files
- [ ] All secrets are managed via environment variables or external secret management
- [ ] No `.env`, `.env.local`, or credential files are committed to version control
- [ ] Temporary files containing secrets are securely deleted after use
- [ ] File permissions on scripts containing secrets are restrictive (e.g., `chmod 600`)

### Repository Access

- [ ] ArgoCD repository credentials are configured securely
- [ ] No sensitive values are exposed in Helm values files or Kustomize overlays

### Input Validation

- [ ] All user input is validated and sanitized
- [ ] Boundary conditions and edge cases are handled
- [ ] Error messages do not expose sensitive information (stack traces, file paths, credentials)

### Authentication and Authorization

- [ ] Authentication mechanisms are secure (no hardcoded passwords, tokens managed externally)
- [ ] Authorization checks are in place where needed
- [ ] API keys and service account tokens are rotatable

### Network Security

- [ ] HTTPS/TLS is used for external communications
- [ ] Certificate validation is not disabled
- [ ] Firewall rules and network policies are reviewed

## Code Quality

### Defensive Programming

- [ ] Error handling is comprehensive and graceful
- [ ] Edge cases are considered and handled (empty lists, null values, missing files)
- [ ] Assumptions are validated (file exists, variable is set, service is running)
- [ ] Timeouts are set for network operations and long-running tasks

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
- [ ] **AppProject resource audit**: All Kubernetes resource kinds the application will create are permitted by the target AppProject's `clusterResourceWhitelist` and `namespaceResourceWhitelist` — see [AppProject Resource Audit](adding-applications.md#appproject-resource-audit)

### Idempotency

- [ ] Manifests can be applied multiple times without errors
- [ ] Resources use declarative configuration (no imperative operations)
- [ ] Kustomize patches are idempotent
- [ ] State is checked before making changes (e.g., "create if not exists" pattern)
- [ ] Cleanup operations handle already-cleaned resources gracefully

### Dependencies

- [ ] External dependencies are minimized where practical
- [ ] New dependencies are discussed and approved before adding
- [ ] Dependencies are pinned to specific versions or version ranges
- [ ] Dependency updates are tested before merging

### Code Organization

- [ ] Code follows established project patterns and conventions
- [ ] Complex logic is broken into smaller, focused functions/modules
- [ ] Magic numbers and strings are replaced with named constants
- [ ] Code is self-documenting; comments explain "why" not "what"

## Documentation

### Required Documentation Updates

When implementing features, update relevant documentation:

- [ ] **`docs/architecture.md`** - If changing system design, adding components, or modifying sync waves
- [ ] **`docs/changelog.md`** - Always update with new features, fixes, and changes
- [ ] **`README.md`** - If adding new prerequisites, clusters, or applications
- [ ] **Configuration examples** - If adding new configuration options

### Architecture Decision Records

- [ ] Create ADR in `/adrs/` for architectural decisions that impact future development
- [ ] ADRs follow the standard ADR format (see [adr.github.io](https://adr.github.io/))
- [ ] ADRs are referenced in relevant documentation files

## Git and GitHub

### Branch Naming

- [ ] Branch follows format: `feature-<issue-id>/<description>` or `fix-<issue-id>/<description>`
- [ ] Branch is associated with a GitHub Issue
- [ ] Branch is NOT directly on `main`

### Pull Request Description

- [ ] Description accurately reflects implementation (not just a plan)
- [ ] Description explains **what** changed and **why**
- [ ] Includes explicit markdown link to GitHub Issue in the format: `[#123](https://github.com/owner/repo/issues/123)`
- [ ] Not just "Closes #123" or "Resolves #123" — use proper markdown link with issue number visible

### Commits

- [ ] Commit messages clearly state intent and outcome
- [ ] Commits are focused on single logical changes
- [ ] No bleeding of multiple unrelated changes into one commit

## Testing and Verification

### Before Creating PR

- [ ] Changes have been tested locally or in a dev environment
- [ ] Validate Kustomize builds for all affected clusters: `kubectl kustomize <path>/overlays/<cluster>/`
- [ ] Validate Helm templates render without errors: `helm template <release> <chart> -f <values>`
- [ ] Check YAML syntax for all modified files
- [ ] Verify ArgoCD Application manifests are valid
- [ ] Review sync wave ordering for new or modified applications
- [ ] Regression testing performed (existing functionality still works)

### Edge Cases

- [ ] Test with minimal and maximal configurations
- [ ] Verify namespace creation for new applications
- [ ] Ensure resource limits and requests are specified
- [ ] Check that ingress hostnames follow naming conventions: `<service>.<cluster>.<domain>`
- [ ] Edge cases and error conditions have been tested

### Validation

- [ ] Configuration files are syntactically valid
- [ ] Scripts execute without errors in the target environment
- [ ] Dependencies are available and versions are compatible
- [ ] Documentation examples are tested and work as written

## Common Pitfalls (from Past Reviews)

These specific issues have been caught in previous code reviews:

1. **Missing `kustomization.yaml` entry** - New applications must be added to `clusters/<cluster>/<layer>/kustomization.yaml` or the parent Application will not discover them
2. **Wrong ArgoCD Project** - Infrastructure components (cluster-scoped resources) must use the `infrastructure` project; workloads use `workloads`
3. **AppProject resource not whitelisted** - Every Kubernetes resource kind a new Application creates must be present in the target project's `clusterResourceWhitelist` (cluster-scoped) or `namespaceResourceWhitelist` (namespace-scoped). Missing entries cause sync errors at deploy time. Always run the [AppProject Resource Audit](adding-applications.md#appproject-resource-audit) before opening a PR.
4. **Sync wave ordering** - CRDs must deploy before resources that use them (e.g., cert-manager before ClusterIssuer, CFK operator before Confluent resources)
5. **Multi-source `$values` reference** - The Git source must use `ref: values` for the `$values` prefix to resolve in Helm value file paths
6. **Documentation not updated** - Always update `/docs` for major features
7. **Branch naming wrong** - Must follow `feature-<id>/` or `fix-<id>/` pattern
8. **PR description inaccurate** - Ensure specs match actual implementation
9. **Missing `ServerSideApply=true`** - Required for applications that manage CRDs to avoid field ownership conflicts
10. **Hardcoded cluster values in base** - Base manifests should use placeholders or be cluster-agnostic; cluster-specific values belong in overlays
11. **MicroK8s ingress controller is Traefik, not NGINX** - Since MicroK8s v1.28+, the default ingress controller is Traefik (service: `traefik` in namespace `ingress`), not NGINX
12. **Hardcoded secrets** - API keys, tokens, passwords committed to Git (use environment variables or external secret management)
13. **Missing GitHub Issue link** - PR doesn't include explicit markdown link to issue: `[#123](https://github.com/owner/repo/issues/123)`
14. **No ADR for architectural decisions** - Significant design choices made without documenting rationale
15. **Assumptions not validated** - Code assumes files exist, services are running, or variables are set without checking
16. **No idempotency** - Re-running operations causes errors or duplicate resources
17. **External dependencies added without discussion** - New libraries or tools added without considering long-term maintenance burden
