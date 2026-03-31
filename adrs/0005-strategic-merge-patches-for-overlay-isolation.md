# 5. Use Strategic Merge Patches for Overlay Isolation

Date: 2026-03-16

## Status

Accepted

## Context

The repository supports multiple cluster variants that share common workloads but require different configurations:
- `flink-demo`: Basic cluster with HTTP/no-auth
- `flink-demo-mtls`: Enhanced cluster with HTTPS/mTLS authentication

The key requirements are:
- **Base resources remain reusable**: Base configurations should work for all clusters without modification
- **Overlay-specific changes**: Cluster variants need to add/modify resources without affecting base
- **No cross-contamination**: Changes for one cluster shouldn't require changes to other clusters
- **Clear separation**: Easy to understand what's different between clusters
- **GitOps compatibility**: All changes declarative and managed in Git

For the `flink-demo-mtls` cluster, we need to:
- Transform HTTP endpoints (port 80) to HTTPS endpoints (port 443)
- Add certificate volume mounts to hook jobs
- Add mTLS flags to `confluent flink` CLI commands
- Add wait-for-certificates initContainers

Alternative approaches considered:

1. **Modify base resources**: Add mTLS configuration directly in base, use conditionals
   - Pros: All configuration in one place
   - Cons: Breaks other clusters, makes base non-reusable, violates DRY

2. **Duplicate resources per cluster**: Copy base to each cluster overlay, modify independently
   - Pros: Complete isolation, no shared state
   - Cons: Massive duplication, maintenance nightmare, difficult to track changes

3. **JSON 6902 patches**: Use RFC 6902 JSON Patch operations
   - Pros: Precise control, can handle complex transformations
   - Cons: Verbose, hard to read, requires exact path specifications, brittle

4. **Strategic Merge Patches (chosen)**: Use Kubernetes strategic merge semantics
   - Pros: Readable YAML, intuitive merging, works with Kustomize naturally
   - Cons: Less precise than JSON patches, requires understanding merge semantics

## Decision

We will use **Strategic Merge Patches** in Kustomize overlays to transform base resources for cluster variants:

1. **Base resources**: Define minimal, cluster-agnostic configurations
   ```yaml
   # workloads/cp-flink-sql-sandbox/base/cmf-init-job.yaml
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: cmf-catalog-database-init
   spec:
     template:
       spec:
         containers:
         - name: cmf-init
           env:
           - name: CMF_URL
             value: "http://cmf-service.operator.svc.cluster.local:80"
   ```

2. **Strategic merge patches**: Apply targeted changes in overlays
   ```yaml
   # workloads/cp-flink-sql-sandbox/overlays/flink-demo-mtls/cmf-init-job-patch.yaml
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: cmf-catalog-database-init
   spec:
     template:
       spec:
         initContainers:
         - name: wait-for-certificates
           # ... initContainer spec
         containers:
         - name: cmf-init
           env:
           - name: CMF_URL
             value: "https://cmf-service.operator.svc.cluster.local:443"
           volumeMounts:
           - name: client-certs
             mountPath: /certs/client
         volumes:
         - name: client-certs
           secret:
             secretName: cmf-client-tls
   ```

3. **Kustomization orchestration**:
   ```yaml
   # workloads/cp-flink-sql-sandbox/overlays/flink-demo-mtls/kustomization.yaml
   resources:
     - ../../base

   patches:
     - path: cmf-init-job-patch.yaml
       target:
         kind: Job
         name: cmf-catalog-database-init
   ```

4. **Patch scope**: Only overlay-specific changes, never modify base files

## Consequences

### Positive

- **Base stays clean**: Base resources work for all clusters without cluster-specific logic
- **Overlay isolation**: Changes in one overlay don't affect other overlays or base
- **Readable patches**: YAML format is intuitive, shows what changes vs base
- **Easy testing**: Can test base independently, then test overlays
- **Clear intent**: Patch files explicitly show what's different for this cluster
- **Maintainable**: Changes to base automatically propagate to overlays unless overridden
- **DRY principle**: Common configuration in base, differences in overlays
- **Kustomize native**: Uses built-in Kustomize functionality, no external tools

### Negative

- **Learning curve**: Requires understanding strategic merge semantics (lists vs maps)
- **Merge behavior**: Sometimes non-intuitive (e.g., list replacement vs merge)
  - Mitigated: Use `patchesStrategicMerge` with explicit merge directives when needed
- **Debugging overhead**: Need to mentally merge base + patch to see final result
  - Mitigated: Use `kustomize build` to preview final rendered output
- **Patch file maintenance**: Need to keep patches in sync with base structure
  - Mitigated: Kustomize validates patches during build

### Neutral

- **Multiple patch files**: Each resource that needs changes gets its own patch file
  - Could be positive (explicit) or negative (more files)
  - For this repository, explicit is better (clarity over conciseness)
- **Patch order matters**: Patches applied in order listed in kustomization.yaml
  - Not an issue if patches target different resources
  - Relevant if multiple patches modify the same resource

### Risks

- **Base structure changes**: Significant changes to base might break patches
  - Mitigation: Run validation on all overlays when modifying base
  - Mitigation: Automated CI/CD testing of kustomize builds
- **Patch conflicts**: Multiple patches modifying same field could conflict
  - Mitigation: Design patches to be orthogonal (modify different sections)
  - Mitigation: Use `kustomize build` to verify before committing
- **Strategic merge edge cases**: Complex nested structures might not merge as expected
  - Mitigation: Test patch behavior, use JSON 6902 patches for complex cases
  - Mitigation: Document any non-obvious merge behaviors

### Follow-up Decisions

- Future: May need ADR for when to use JSON 6902 patches vs strategic merge
- Future: May need ADR for overlay validation strategy (CI/CD testing)
- Future: May need ADR for handling breaking changes to base resources

## References

- [Kustomize Strategic Merge Patches](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/#patches)
- [Kubernetes Strategic Merge Patch Spec](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-api-machinery/strategic-merge-patch.md)
- [GitHub Issue #71](https://github.com/osowski/confluent-platform-gitops/issues/71) - mTLS implementation
- [flink-demo-mtls Cluster README](../clusters/flink-demo-mtls/README.md#how-it-works)
- [cp-flink-sql-sandbox base](../workloads/cp-flink-sql-sandbox/base/)
- [cp-flink-sql-sandbox flink-demo-mtls overlay](../workloads/cp-flink-sql-sandbox/overlays/flink-demo-mtls/)
