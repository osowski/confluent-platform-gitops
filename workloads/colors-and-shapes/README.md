# Colors and Shapes

A two-tenant Flink demo — `shapes` and `colors` — showing both native
`FlinkApplication` (JAR) and Flink SQL (`FlinkStatement`) deployment models
side by side, reading the same input topic and writing to separate output
topics.

## Deployment Modes

`base/` is the anonymous variant, used as-is on `flink-demo`. On
`flink-demo-rbac`, `flink-demo-rbac-mtls`, and `eks-demo`, the
`components/rbac-oauth` Kustomize Component layers on Kubernetes RBAC
(namespaces already in base; per-group Roles/RoleBindings/ServiceAccounts
added by the component), Keycloak OAuth secrets, and the OAuth-flavored
`flinkConfiguration`/env var fields the base intentionally omits.

**On `flink-demo`:** Kafka and Schema Registry are anonymous, so none of the
shapes/colors resources carry any auth configuration — no
`kafka.security.protocol`, no OAuth secrets, no per-group Kubernetes RBAC.
Anyone with cluster access can manage either tenant.

**On `flink-demo-rbac`, `flink-demo-rbac-mtls`, `eks-demo`:** the
`rbac-oauth` component implements a three-layer authorization model for
group-based multi-tenant isolation. Every field the component patches back
onto base was deliberately stripped out when `colors-and-shapes` was
extracted into an anonymous base — see `docs/architecture.md`'s Flink SQL
sections for what CMF/CFK require of each one.

### Layer 1 — Kubernetes RBAC

Controls kubectl/CRD access, namespace isolation:

- Namespaces `flink-shapes` (shapes group) and `flink-colors` (colors group)
- Per-group ServiceAccounts (`shapes-group`, `colors-group`) with full
  `Role`/`RoleBinding` access to Flink/CFK/core/apps/batch resources in
  their own namespace, and read-only `Role`/`RoleBinding`s into the shared
  `kafka` and `flink` namespaces
- `flink-admin` `ClusterRole`/`ClusterRoleBinding` for cluster-wide admin
  access

### Layer 2 — CFK Operator Authentication

CFK's `CMFRestClass` (OAuth client-credentials flow to CMF) is owned by the
`flink-resources` Application, not this one — see
[flink-resources README](../flink-resources/README.md). This workload only
references `cmfRestClassRef: {name: cmf-rest-class, namespace: flink}`
cross-Application; it doesn't own that resource on any cluster.

### Layer 3 — CMF RBAC via MDS

Controls user access to Flink resources via the CMF UI/REST API. When a user
authenticates via Keycloak OAuth, CMF validates the bearer token, extracts
principal + groups, and queries MDS for `ConfluentRolebinding`s
(`workloads/confluent-resources/overlays/<cluster>/confluentrolebindings.yaml`)
scoping `DeveloperManage`/`DeveloperRead` to `shapes-env` or `colors-env`
respectively. **Kubernetes RBAC and CMF RBAC are independent layers**: a
shapes-group user can deploy a `FlinkApplication` CRD into `flink-shapes`
(Layer 1 allows it), but CMF still rejects any attempt to manage
`colors-env` resources through its own API (Layer 3), even though the
operator itself authenticates successfully (Layer 2).

## What's Included

- **Namespaces**: `flink-shapes`, `flink-colors`
- **FlinkEnvironments**: `shapes-env`, `colors-env` — one per tenant, so CMF
  RBAC (on the RBAC clusters) can scope permissions per tenant. These names
  are load-bearing: `confluentrolebindings.yaml` on the RBAC clusters
  hardcodes `flinkEnvironmentId: shapes-env`/`colors-env` — do not rename.
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
forming a dependency chain applied in order and deleted in reverse. On
`flink-demo` (base only) sync waves are 5/40/50/60/70/80; on the RBAC
clusters, the `rbac-oauth` component reintroduces the Secret/FlinkSecret/
mapping chain at waves 10/20/30. See
[architecture.md](../../docs/architecture.md#intra-application-sync-waves-flink-sql-resources)
for the constraints that apply to the whole chain.

### Flink SQL Statement Pipeline

Alongside the JAR-based `FlinkApplication` jobs, each tenant runs a
standalone Flink SQL statement (`shapes-sql-enrich`/`colors-sql-enrich`),
reconciled into CMF by CFK. It **reads the existing `*-input` topic** (shared
with the JAR job) and writes enriched records to a dedicated `*-sql-output`
topic — so the same input feeds both the JAR pipeline (→ `*-output`) and the
SQL pipeline (→ `*-sql-output`), demonstrating JAR/SQL parity. It does
**not** write to the JAR output topics (`*-output`, `*-state`).

1. The statement is a declarative `FlinkStatement` CR in
   `base/flink-statements.yaml`. Its SQL is **immutable once running** — a
   CEL rule on the CRD rejects any update that changes `spec.statement`, so
   editing it in Git fails the sync permanently. Add a versioned CR
   (`shapes-sql-enrich-v2`) instead. See
   [architecture.md](../../docs/architecture.md#changing-the-sql-of-a-running-flinkstatement)
   for that rule and the rest of the Flink SQL CR constraints.
2. The statement reads the inferred `*-input` table, adds an `encoded`
   column (mirroring the JAR enrichment), and writes `ProcessedSensorEvent`
   records to `*-sql-output`. The Kafka tables are auto-inferred from the
   registered SR schemas; an explicit `INSERT` column list leaves the
   inferred sink's leading raw `key` (BYTES) column NULL.
3. On the RBAC clusters, topic/consumer-group/transactional-ID access is
   authorized via the `sa-<tenant>-flink` service account's `ResourceOwner`
   PREFIXED bindings; see
   [ADR-0008](../../adrs/0008-flink-sql-statement-config-placement-rbac.md)
   for how statement configuration spans the compute-pool JVM options,
   SQL table hints, and MDS RBAC layers.

> **OAuth allow-list (RBAC clusters only):** the `cp-flink-sql` image's
> shaded Kafka client enforces an OAUTHBEARER token-endpoint allow-list that
> defaults to empty, so `components/rbac-oauth/flink-compute-pools-oauth-patch.yaml`
> sets `env.java.opts.all` to the Keycloak token URL. Without it the
> statement's Flink job crash-loops with "URL cannot be accessed due to
> restrictions".
>
> **Producer wire format:** the inferred input tables are
> `value.format = 'avro-registry'` with `scan.startup.mode =
> 'earliest-offset'`, so the statement re-reads from offset 0 on every
> (re)start and a single record lacking the Confluent wire prefix (magic
> byte `0x00` + 4-byte schema ID) fails the job permanently — not just for
> the bad record. If a non-Avro producer has ever written to an input
> topic, purge the topic (delete and re-create the `KafkaTopic` CR) before
> scaling a producer back up.

## Prerequisites

The following must be deployed before this application:
- Confluent for Kubernetes (CFK) operator
- Confluent Manager for Apache Flink (CMF) operator, with `flink-resources`
  synced first (this workload references, but does not own, `cmf-rest-class`
  in the `flink` namespace)
- Kafka cluster with Schema Registry
- MinIO for object storage (deployed as infrastructure application)
- On the RBAC clusters: Keycloak (realm + demo users/groups) and MDS, since
  `components/rbac-oauth` depends on both

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
