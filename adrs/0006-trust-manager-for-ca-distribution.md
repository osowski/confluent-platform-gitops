# 6. Use trust-manager for CA Certificate Distribution

Date: 2026-03-16

## Status

Accepted

## Context

The `flink-demo-mtls` cluster implements mTLS authentication between Confluent Flink components. For clients to verify the CMF server certificate, they need access to the Certificate Authority (CA) certificate that signed it.

The CA certificate needs to be distributed to:
- **operator namespace**: For CMF service to verify client certificates
- **flink namespace**: For Flink CLI and hook jobs to verify CMF server certificate
- Any future namespaces that need to communicate with CMF via mTLS

The CA certificate is stored in a Secret by cert-manager, but applications typically consume CA certificates from ConfigMaps (mounted as files). We need a solution to:
1. Extract CA certificate from the Secret
2. Create ConfigMaps in target namespaces
3. Keep ConfigMaps synchronized with CA certificate renewals
4. Support namespace-based targeting (don't distribute to all namespaces)

Alternative approaches considered:

1. **Manual ConfigMap creation**: Copy CA certificate to ConfigMaps manually
   - Pros: Simple, no external dependencies
   - Cons: Not declarative, manual work, doesn't handle CA renewal, breaks GitOps

2. **cert-manager Certificate resources**: Create Certificate in each namespace
   - Pros: Uses existing cert-manager infrastructure
   - Cons: Creates duplicate certificates, wastes resources, doesn't solve distribution problem

3. **Reflector/kubed**: Use secret/configmap reflection tools
   - Pros: Generic solution, can reflect any secret/configmap
   - Cons: Another tool to manage, annotation-based (less declarative), broader scope than needed

4. **trust-manager (chosen)**: Purpose-built for CA certificate distribution
   - Pros: Designed for this use case, declarative, integrates with cert-manager
   - Cons: Additional component (but part of cert-manager ecosystem)

## Decision

We will use **trust-manager** to distribute CA certificates to namespaces:

1. **Install trust-manager**: Deploy as part of infrastructure (sync-wave 30)
   ```yaml
   # clusters/<cluster>/infrastructure/trust-manager.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: trust-manager
   spec:
     source:
       chart: trust-manager
       repoURL: https://charts.jetstack.io
   ```

2. **Create Bundle resources**: Define CA distribution policies
   ```yaml
   # workloads/flink-resources/overlays/flink-demo-mtls/certificates/trust-bundle.yaml
   apiVersion: trust.cert-manager.io/v1alpha1
   kind: Bundle
   metadata:
     name: cmf-ca-bundle
   spec:
     sources:
     - secret:
         name: cmf-root-ca
         key: ca.crt
         namespace: cert-manager
     target:
       configMap:
         key: ca.crt
       namespaceSelector:
         matchLabels:
           cmf-mtls: enabled
   ```

3. **Label target namespaces**: Use labels to control distribution
   ```yaml
   # Apply via kustomize patch
   - patch: |-
       - op: add
         path: /metadata/labels/cmf-mtls
         value: enabled
     target:
       kind: Namespace
       name: operator
   ```

4. **Consume ConfigMaps**: Applications mount ConfigMaps as volumes
   ```yaml
   volumeMounts:
   - name: ca-bundle
     mountPath: /certs/ca
     readOnly: true
   volumes:
   - name: ca-bundle
     configMap:
       name: cmf-ca-bundle
   ```

## Consequences

### Positive

- **Declarative CA distribution**: Bundle resources define distribution policy in Git
- **Automatic synchronization**: trust-manager watches Secret, updates ConfigMaps on CA renewal
- **Namespace targeting**: Use label selectors to control which namespaces receive CA
- **cert-manager integration**: Part of cert-manager ecosystem, consistent tooling
- **Read-only distribution**: CA certificate (public key) distributed via ConfigMap, CA private key stays in Secret
- **Standard format**: ConfigMaps with `ca.crt` key is Kubernetes convention
- **Multiple CA support**: Can create multiple Bundles for different CAs
- **RBAC friendly**: Namespaces can read their own ConfigMaps without accessing cert-manager namespace

### Negative

- **Additional component**: Another controller to deploy and manage
  - Mitigated: trust-manager is lightweight, part of cert-manager project
- **Label dependency**: Namespaces must be labeled before Bundle creates ConfigMaps
  - Mitigated: ArgoCD sync waves ensure namespaces created before workloads
- **Eventual consistency**: Brief delay between CA renewal and ConfigMap update
  - Mitigated: trust-manager reconciles quickly, applications handle gracefully

### Neutral

- **Bundle scope**: Could use namespaceSelector or explicit namespace list
  - Chose namespaceSelector for flexibility (easier to add namespaces)
- **ConfigMap naming**: Bundle defines ConfigMap name (`cmf-ca-bundle`)
  - Consistent naming across namespaces simplifies configuration

### Risks

- **Bundle deletion**: Accidentally deleting Bundle removes CA ConfigMaps from all namespaces
  - Mitigation: ArgoCD automated sync recreates Bundle immediately
  - Mitigation: Applications gracefully handle missing CA (fail closed)
- **Label removal**: Removing `cmf-mtls: enabled` label deletes CA ConfigMap
  - Mitigation: Document label requirements, use kustomize to manage labels
- **trust-manager failure**: If trust-manager pod crashes, CA updates stop
  - Mitigation: High availability deployment in production
  - Mitigation: CA renewals have 30-day threshold, plenty of time to recover
- **Namespace selector mismatch**: Wrong label selector distributes CA to wrong namespaces
  - Mitigation: Use specific labels (`cmf-mtls`), not generic (`enabled`)
  - Mitigation: Review Bundle configuration during code review

### Follow-up Decisions

- Future: May need ADR for handling multiple CA hierarchies (different CAs for different services)
- Future: May need ADR for CA rotation strategy (how to safely rotate root CA)
- Future: May need ADR for trust-manager high availability in production

## References

- [trust-manager Documentation](https://cert-manager.io/docs/trust/trust-manager/)
- [trust-manager Bundle API](https://cert-manager.io/docs/trust/trust-manager/api-reference/)
- [GitHub Issue #71](https://github.com/osowski/confluent-platform-gitops/issues/71) - mTLS implementation
- [flink-demo-mtls Cluster README](../clusters/flink-demo-mtls/README.md#architecture)
- [trust-bundle resource](../workloads/flink-resources/overlays/flink-demo-mtls/certificates/trust-bundle.yaml)
