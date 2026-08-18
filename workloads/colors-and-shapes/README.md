# Colors and Shapes

A two-tenant Flink demo — `shapes` and `colors` — showing both native
`FlinkApplication` (JAR) and Flink SQL (`FlinkStatement`) deployment models
side by side, reading the same input topic and writing to separate output
topics.

## Deployment Modes

This workload has no per-cluster auth fork of its own: `base/` is the
anonymous variant, used as-is on `flink-demo`. On `flink-demo-rbac`,
`flink-demo-rbac-mtls`, and `eks-demo`, a `rbac-oauth` Kustomize Component
(added in a later phase — see the Epic in
[#345](https://github.com/osowski/confluent-platform-gitops/issues/345))
layers on Kubernetes RBAC (namespaces already in base; per-group
Roles/RoleBindings/ServiceAccounts added by the component), Keycloak OAuth
secrets, and the OAuth-flavored `flinkConfiguration`/env var fields this
base intentionally omits.

**On `flink-demo` today:** Kafka and Schema Registry are anonymous, so
none of the shapes/colors resources carry any auth configuration — no
`kafka.security.protocol`, no OAuth secrets, no per-group Kubernetes RBAC.
Anyone with cluster access can manage either tenant.

## What's Included

- **Namespaces**: `flink-shapes`, `flink-colors`
- **FlinkEnvironments**: `shapes-env`, `colors-env` — one per tenant, so CMF
  RBAC (on the RBAC clusters) can scope permissions per tenant
- **FlinkApplications** (`shapes`, `colors`): JAR-based, reading `*-input`
  and writing `*-output`
- **Flink SQL** (`FlinkKafkaCatalog`/`FlinkKafkaDatabase`/`FlinkComputePool`/
  `FlinkStatement` per tenant): a continuous `INSERT INTO` reading the same
  `*-input` topic and writing enriched records to a dedicated `*-sql-output`
  topic — demonstrating JAR/SQL parity from one input stream
- **Producers** (`shapes-producer`, `colors-producer`): `replicas: 0` by
  default; scale to 1 to generate traffic
- **Topics**: `*-input`, `*-output`, `*-state` (compacted), `*-sql-output`
- **Schemas**: `SensorEvent` (input) / `ProcessedSensorEvent` (output),
  identical across both tenants

The Flink SQL resources are declarative CFK custom resources (CFK 3.3.0+)
forming a dependency chain applied in order and deleted in reverse; sync
waves 5/40/50/60/70/80 enforce both directions. See
[architecture.md](../../docs/architecture.md#intra-application-sync-waves-flink-sql-resources)
for the constraints that apply to the whole chain.

## Prerequisites

The following must be deployed before this application:
- Confluent for Kubernetes (CFK) operator
- Confluent Manager for Apache Flink (CMF) operator, with `flink-resources`
  synced first (this workload references, but does not own, `cmf-rest-class`
  in the `flink` namespace)
- Kafka cluster with Schema Registry
- MinIO for object storage (deployed as infrastructure application)

## Validating End-to-End

```bash
# Feed shapes-input / colors-input
kubectl -n flink-shapes scale deploy/shapes-producer --replicas=1
kubectl -n flink-colors scale deploy/colors-producer --replicas=1

# Confirm the JAR FlinkApplications are running
kubectl -n flink-shapes get flinkapplication shapes
kubectl -n flink-colors get flinkapplication colors

# Confirm the Flink SQL statements are running
confluent --environment shapes-env flink statement list
confluent --environment colors-env flink statement list
```
