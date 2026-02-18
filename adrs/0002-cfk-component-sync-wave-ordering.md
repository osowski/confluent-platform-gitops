# 2. CFK Component Sync-Wave Ordering

Date: 2026-02-14

## Status

Accepted

## Context

The Confluent Platform deployment via the `confluent-resources` ArgoCD Application (sync-wave 110) deploys all CFK component manifests simultaneously. ArgoCD submits all resources at once, meaning components with unsatisfied dependencies (e.g., Kafka before KRaftController is ready) are created and must wait/retry until their dependencies become available.

The CFK component dependency chain is:

```
KRaftController → Kafka → SchemaRegistry → ControlCenter
                       ↘ Connect       ↗
```

This causes two problems:

1. **Unnecessary retry loops**: Components that cannot start yet still get created and repeatedly fail/retry, wasting resources and producing noisy logs.
2. **Non-deterministic startup**: Without explicit ordering, startup timing depends on Kubernetes scheduling, which can vary between deployments.

### Alternatives Considered

1. **Separate ArgoCD Applications per component**: Split `confluent-resources` into individual Applications (e.g., `kraft-controller`, `kafka-broker`, etc.) with inter-application sync-wave ordering.
   - Pros: Full isolation, independent sync policies per component
   - Cons: Significant increase in Application count and management overhead; the components are logically a single deployment unit

2. **CFK operator dependency handling only**: Rely solely on CFK's built-in dependency management (the operator waits for dependencies before starting components).
   - Pros: No ArgoCD configuration needed
   - Cons: Resources are still created simultaneously; the operator must handle all retry logic; ArgoCD cannot report accurate health status for individual resources

3. **ArgoCD sync-wave annotations within the single Application**: Add `argocd.argoproj.io/sync-wave` annotations to individual resource manifests within the existing `confluent-resources` Application.
   - Pros: Minimal configuration change; ArgoCD handles ordering natively; resources are only created when dependencies are healthy; no increase in Application count
   - Cons: Requires custom health checks for ArgoCD to evaluate CFK resource health

## Decision

We will use **ArgoCD sync-wave annotations within the existing `confluent-resources` Application** (Alternative 3) combined with **custom Lua health checks** in the ArgoCD ConfigMap.

### Sync-Wave Assignment

| Wave | Resource | CFK Kind | Rationale |
|------|----------|----------|-----------|
| `"0"` | kraft-controller.yaml | KRaftController | No dependencies, must start first |
| `"10"` | kafka-broker.yaml | Kafka | Depends on KRaftController |
| `"10"` | kafkarestclass.yaml | KafkaRestClass | Configuration resource, deploy with Kafka |
| `"20"` | schema-registry.yaml | SchemaRegistry | Depends on Kafka |
| `"20"` | connect.yaml | Connect | Depends on Kafka |
| `"30"` | control-center.yaml | ControlCenter | Depends on Kafka, SchemaRegistry, Connect |
| `"30"` | kafkatopic.yaml | KafkaTopic | Depends on Kafka + KafkaRestClass |

### Custom Health Checks

ArgoCD defaults to `Progressing` status for unknown CRDs, which would prevent sync waves from advancing. Custom Lua health check scripts are added to the `argocd-cm` ConfigMap for 5 CFK resource types:

- `platform.confluent.io_KRaftController`
- `platform.confluent.io_Kafka`
- `platform.confluent.io_SchemaRegistry`
- `platform.confluent.io_Connect`
- `platform.confluent.io_ControlCenter`

Each health check evaluates `obj.status.state`:
- `nil` → `Progressing` (resource just created)
- `"RUNNING"` → `Healthy`
- Any other value → `Progressing` (still starting up)

## Consequences

### Positive

- **Ordered startup**: Components deploy in dependency order, eliminating unnecessary retry loops
- **Accurate health reporting**: ArgoCD UI shows meaningful health status for each CFK resource
- **Minimal change**: Reuses the existing single-Application pattern; only adds annotations and health checks
- **Faster overall deployment**: Components don't waste time creating resources that will fail to start

### Negative

- **Health check maintenance**: Custom Lua scripts must be maintained if CFK changes its `status.state` semantics
- **ArgoCD dependency**: The ordering relies on ArgoCD sync-wave behavior; deploying manifests outside ArgoCD would not enforce ordering

### Risks

- **CFK status field changes**: If future CFK versions change the `status.state` field name or values, health checks will need updating
  - Mitigation: Pin CFK operator version; update health checks as part of CFK upgrade process
- **Sync timeout**: If a component fails to reach `RUNNING` state, ArgoCD will wait at that wave indefinitely
  - Mitigation: ArgoCD's default sync timeout and retry policies handle this; operators can check ArgoCD UI for blocked waves

## References

- [ArgoCD Sync Waves Documentation](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/)
- [ArgoCD Custom Health Checks](https://argo-cd.readthedocs.io/en/stable/operator-manual/health/)
- [Confluent for Kubernetes Documentation](https://docs.confluent.io/operator/current/overview.html)
- [GitHub Issue #3](https://github.com/osowski/confluent-platform-gitops/issues/3)
- [Architecture Documentation](../docs/architecture.md)
