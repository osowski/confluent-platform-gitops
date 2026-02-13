# 1. Use ArgoCD App of Apps Pattern

Date: 2025-02-02

## Status

Accepted

## Context

This homelab GitOps repository needs to manage multiple Kubernetes applications across one or more clusters. The key requirements are:

- **Declarative application management**: All applications should be defined in Git
- **Automated synchronization**: Changes to Git should automatically sync to clusters
- **Multi-cluster support**: The repository should support deploying to multiple homelab clusters
- **Application organization**: Infrastructure components and workloads should be separately managed
- **RBAC boundaries**: Infrastructure apps need cluster-scoped permissions, workloads should be namespace-scoped
- **Scalability**: Adding new applications should be simple and require minimal boilerplate

Alternative approaches considered:

1. **Flat Application Structure**: Define each ArgoCD Application manually in a single directory
   - Simple for small deployments
   - Doesn't scale well - requires creating ArgoCD Applications manually for each app
   - No clear separation between infrastructure and workloads

2. **ApplicationSets with Generators**: Use ArgoCD ApplicationSets to generate Applications
   - More powerful and flexible
   - More complex to understand and debug
   - Overkill for single or small number of clusters
   - Better suited for large-scale multi-cluster deployments

3. **App of Apps Pattern**: Use parent Applications that watch directories and create child Applications
   - Middle ground between simplicity and flexibility
   - Well-documented pattern in ArgoCD community
   - Easy to understand and maintain
   - Scales well for homelab use case

## Decision

We will use the **App of Apps pattern** with the following structure:

1. **Bootstrap Layer**: Helm chart (`bootstrap/`) that creates:
   - ArgoCD Project CRDs (infrastructure, workloads)
   - Parent Applications (infrastructure-apps, workloads-apps)

2. **Parent Applications**: Two top-level Applications that watch cluster-specific directories:
   - `infrastructure-apps`: Watches `clusters/<cluster>/infrastructure/`
   - `workloads-apps`: Watches `clusters/<cluster>/workloads/`

3. **Child Applications**: Individual ArgoCD Application manifests in cluster directories that reference:
   - Kustomize overlays in `workloads/<app>/overlays/<cluster>/`
   - Helm charts in `infrastructure/<component>/`

4. **Directory Structure**:
   ```
   bootstrap/              # Bootstrap Helm chart
   argocd-projects/        # Project CRD definitions
   infrastructure/         # Infrastructure component bases
   workloads/             # Workload application bases
   clusters/              # Cluster-specific application instances
     <cluster>/
       infrastructure/    # Infrastructure apps for this cluster
       workloads/        # Workload apps for this cluster
   ```

5. **RBAC Separation**: Two ArgoCD Projects with different permission levels:
   - `infrastructure`: Can create cluster-scoped resources (CRDs, PVs, etc.)
   - `workloads`: Namespace-scoped only (Deployments, Services, Ingress, etc.)

## Consequences

### Positive

- **Simple to add applications**: Just create a new Application manifest in `clusters/<cluster>/<type>/`
- **Clear organization**: Infrastructure and workloads are clearly separated
- **RBAC enforcement**: Projects enforce security boundaries automatically
- **Multi-cluster ready**: Easy to add new clusters by creating new directory under `clusters/`
- **Self-documenting**: Directory structure makes it clear what's deployed where
- **Automated sync**: Parent Applications automatically create child Applications
- **Standard pattern**: Well-documented in ArgoCD community with good examples

### Negative

- **Three-layer hierarchy**: Bootstrap → Parent Apps → Child Apps adds some complexity
- **Directory watching**: Parent Applications watch directories, so incorrect paths silently fail
- **Bootstrap dependency**: Parent Applications must be deployed via bootstrap chart
- **Debugging overhead**: Need to check parent Application logs if child Applications aren't created

### Neutral

- **Not using ApplicationSets**: We may need to migrate to ApplicationSets if we scale to many clusters
- **Helm for bootstrap**: Could use raw manifests, but Helm provides cleaner templating for cluster-specific values
- **Manual cluster onboarding**: Adding a new cluster requires creating directories and values file

### Risks

- **Parent Application failure**: If a parent Application fails, no child Applications are created
  - Mitigation: Monitor parent Application health, use automated sync with self-heal
- **Directory path changes**: Renaming cluster directories breaks parent Applications
  - Mitigation: Document cluster directory structure, use consistent naming conventions
- **RBAC misconfiguration**: Assigning wrong Project to an Application could grant excessive permissions
  - Mitigation: Review Application manifests for correct `project` field during code review

### Follow-up Decisions

- Future: May need ADR for secret management strategy (Sealed Secrets vs External Secrets Operator)
- Future: May need ADR for migrating to ApplicationSets if we exceed ~5 clusters
- Future: May need ADR for ArgoCD self-management (ArgoCD managing its own configuration)

## References

- [ArgoCD App of Apps Pattern Documentation](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
- [Architecture Documentation](../docs/architecture.md)
- [Bootstrap Procedure](../docs/bootstrap-procedure.md)
- [GitHub Issue #2](https://github.com/osowski/homelab-argocd/issues/2)
