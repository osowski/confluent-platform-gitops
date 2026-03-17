# 4. Use ClusterIssuer for Cross-Namespace Certificate Signing

Date: 2026-03-16

## Status

Accepted

## Context

The `flink-demo-mtls` cluster requires mTLS authentication between Confluent Flink components across multiple namespaces:
- CMF server certificate in `operator` namespace
- CMF client certificate in `flink` namespace
- Root CA certificate in `cert-manager` namespace

These certificates must all be signed by the same Certificate Authority (CA) to establish a trust chain for mutual authentication.

cert-manager supports two approaches for certificate issuance:

1. **Namespace-scoped Issuer**: CA secret must exist in the same namespace as the Issuer
   - Requires syncing the CA secret from `cert-manager` namespace to `operator` and `flink` namespaces
   - Needs external tools like Reflector or kubed to replicate secrets
   - More complex GitOps workflow (secret replication not declarative)
   - Each namespace needs its own Issuer resource

2. **Cluster-scoped ClusterIssuer**: CA secret can be in any namespace (typically `cert-manager`)
   - References CA secret by namespace (e.g., `cert-manager/cmf-root-ca`)
   - No secret syncing required
   - Single ClusterIssuer can sign certificates across all namespaces
   - Fully declarative GitOps workflow

Alternative approaches considered:

**Option A: Namespace-scoped Issuers with Reflector**
- Pros: Secrets isolated to specific namespaces, follows namespace boundaries
- Cons: Requires external dependency (Reflector), more complex, annotations-based replication

**Option B: Namespace-scoped Issuers with manual secret copying**
- Pros: No external dependencies, explicit secret management
- Cons: Not declarative, manual intervention required, breaks GitOps principles

**Option C: ClusterIssuer (chosen)**
- Pros: No secret syncing, simpler architecture, fully declarative, GitOps-friendly
- Cons: Cluster-scoped resource (requires cluster-admin during bootstrap)

## Decision

We will use **ClusterIssuer** for all certificate signing in cluster variants that require mTLS:

1. **Root CA**: Created in `cert-manager` namespace (single source of truth)
   ```yaml
   apiVersion: cert-manager.io/v1
   kind: Certificate
   metadata:
     name: cmf-root-ca
     namespace: cert-manager
   ```

2. **ClusterIssuer**: References CA secret in `cert-manager` namespace
   ```yaml
   apiVersion: cert-manager.io/v1
   kind: ClusterIssuer
   metadata:
     name: cmf-ca-issuer
   spec:
     ca:
       secretName: cmf-root-ca
   ```

3. **Server/Client Certificates**: Reference ClusterIssuer, can be in any namespace
   ```yaml
   apiVersion: cert-manager.io/v1
   kind: Certificate
   metadata:
     name: cmf-server-tls
     namespace: operator
   spec:
     issuerRef:
       name: cmf-ca-issuer
       kind: ClusterIssuer
       group: cert-manager.io
   ```

4. **Namespace placement**:
   - Root CA: `cert-manager` namespace (centralized CA management)
   - ClusterIssuer: Cluster-scoped (no namespace)
   - Server cert: `operator` namespace (where CMF service runs)
   - Client cert: `flink` namespace (where Flink workloads run)

## Consequences

### Positive

- **Eliminates external dependencies**: No need for Reflector or kubed for secret syncing
- **Simpler architecture**: One ClusterIssuer vs multiple namespace Issuers
- **Fully declarative**: All resources defined in Git, no manual secret copying
- **GitOps-friendly**: cert-manager handles everything, no side-channel operations
- **Scalable**: Easy to add more certificates in other namespaces
- **Standard pattern**: Follows cert-manager best practices for multi-namespace PKI
- **Single source of truth**: CA secret exists in one place (`cert-manager` namespace)

### Negative

- **Cluster-scoped permission required**: Creating ClusterIssuer requires cluster-admin privileges
  - Mitigated: Only needed during initial bootstrap, managed via ArgoCD with appropriate RBAC
- **Less namespace isolation**: All namespaces can reference the same ClusterIssuer
  - Mitigated: RBAC controls who can create Certificate resources
- **CA secret access**: ClusterIssuer has access to CA private key across all namespaces
  - Mitigated: cert-manager ServiceAccount has restricted RBAC, CA secret is in `cert-manager` namespace

### Neutral

- **Centralized CA**: All cluster certificates signed by same CA
  - Could be positive (unified PKI) or negative (single point of compromise)
  - For homelab/demo purposes, this is acceptable
- **Migration path**: If we need namespace isolation in production, can switch to namespace Issuers
  - Would require adding secret syncing mechanism at that time

### Risks

- **ClusterIssuer deletion**: Accidentally deleting ClusterIssuer breaks all certificate renewals
  - Mitigation: Use ArgoCD with automated sync and self-heal to recreate
- **CA secret corruption**: If CA secret is lost/corrupted, all certificates become invalid
  - Mitigation: Implement backup strategy for `cert-manager` namespace secrets
- **Permission escalation**: Compromised ClusterIssuer could sign certificates for any namespace
  - Mitigation: Monitor Certificate creations, implement admission control policies

### Follow-up Decisions

- Future: May need ADR for production CA strategy (external CA vs self-signed)
- Future: May need ADR for certificate backup and disaster recovery procedures
- Future: May need ADR for certificate monitoring and expiry alerting strategy

## References

- [cert-manager ClusterIssuer Documentation](https://cert-manager.io/docs/configuration/ca/)
- [cert-manager Multi-tenancy Guide](https://cert-manager.io/docs/tutorials/acme/multi-tenancy/)
- [GitHub Issue #71](https://github.com/osowski/confluent-platform-gitops/issues/71) - mTLS implementation
- [flink-demo-mtls Cluster README](../clusters/flink-demo-mtls/README.md#mtls-configuration)
- [flink-resources mTLS Overlay](../workloads/flink-resources/overlays/flink-demo-mtls/)
