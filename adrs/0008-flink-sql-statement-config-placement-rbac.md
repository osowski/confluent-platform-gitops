# 8. Flink SQL Statement Configuration Placement in CMF under RBAC

Date: 2026-06-22

## Status

Accepted

## Context

Issue [#158](https://github.com/osowski/confluent-platform-gitops/issues/158) adds a standalone Flink SQL statement pipeline to the `flink-demo-rbac` cluster: a continuous `INSERT INTO` statement, created through the CMF Statements API, that reads an existing input topic and writes enriched records to a dedicated output topic — running alongside the existing JAR-based `FlinkApplication` jobs, under the cluster's OAuth/OIDC + MDS RBAC model.

Unlike the JAR applications (which run a purpose-built image with an embedded, non-shaded Kafka client and explicit `kafka.*` Flink config), a CMF SQL statement runs on the stock `confluentinc/cp-flink-sql` image, reads/writes Kafka tables that are **auto-inferred** from Schema Registry by a `KafkaCatalog`, and uses the shaded Kafka client bundled in that image. This combination surfaces several non-obvious requirements that are invisible at `kustomize build` / ArgoCD-sync time and only fail once the statement's Flink job actually starts. During implementation, the statement crash-looped or failed compilation four times, each for a configuration that had been placed in the wrong layer of the stack.

The recurring confusion was **where** a given setting belongs. CP Flink under CMF has at least three distinct configuration layers, and they are not interchangeable:

1. **JVM system properties** of the statement's Flink JobManager/TaskManager processes.
2. **Flink connector / table options** that the Kafka connector reads from the (inferred) table definition.
3. **MDS RBAC** role bindings and Kafka resource-name prefixes.

Putting a connector option into Flink config, or a JVM property into a table hint, renders cleanly and then fails at runtime. The specific failures encountered:

- **OAuth token URL blocked.** The shaded Kafka client (`org.apache.flink.kafka.shaded.org.apache.kafka...`) enforces an OAUTHBEARER token-endpoint allow-list (`...sasl.oauthbearer.allowed.urls`) that defaults to empty, so the JobManager's `SourceCoordinator` could not create a Kafka `AdminClient`: *"URL cannot be accessed due to restrictions. Allowed URL list: []."*
- **Sink transaction timeout rejected.** Flink's Kafka sink uses exactly-once transactions with a default `transaction.timeout.ms` (~1 h) that exceeds the broker's `transaction.max.timeout.ms` (15 min): *"transaction timeout is larger than the maximum value allowed by the broker."*
- **Consumer group denied (latent).** A Flink Kafka source generates a non-deterministic `group.id`; under PREFIXED `shapes-`/`colors-` consumer-group RBAC, a generated group id would be unauthorized.
- **Inferred-sink column mismatch.** The `KafkaCatalog`-inferred sink table has a leading raw `key BYTES` physical column, so a positional `INSERT ... SELECT` of only the value columns fails compilation with a column-count mismatch.
- **Catalog invisible to group users.** `FlinkCatalog` is a CMF cluster-level RBAC resource; group developers had bindings on `FlinkEnvironment` and Kafka topics but none on `FlinkCatalog`, so non-admin users could not see or use their catalog in the SQL UI.

## Decision

Place each setting in the layer that actually owns it, and standardize the following for CMF Flink SQL statements on RBAC-enabled clusters:

1. **OAuth token-endpoint allow-list → compute pool JVM options.** Set it on the `ComputePool` `clusterSpec.flinkConfiguration` as `env.java.opts.all`, using the **shaded** property name:
   `-Dorg.apache.flink.kafka.shaded.org.apache.kafka.sasl.oauthbearer.allowed.urls=<keycloak token url>`.
   This is the only layer that can inject a JVM system property into the statement's JM/TM, and the JM (SourceCoordinator) needs it, not just the TM.

2. **Kafka connector / table options → SQL table hints.** Set per-statement, non-persisted connector options as `/*+ OPTIONS(...) */` hints rather than compute-pool or environment config (the connector does not read them from Flink config):
   - source: `'properties.group.id' = '<env>-sql-enrich'` — pins a deterministic, prefix-authorized consumer group.
   - sink: `'kafka.producer.transaction.timeout.ms' = '900000'` — at or below the broker `transaction.max.timeout.ms`, matching the JAR app.
   For options that should persist on a shared table, `ALTER TABLE ... SET (...)` is the alternative; hints are preferred here because each output topic has a single dedicated writer.

3. **Inferred-sink writes → explicit `INSERT` column list.** Always enumerate the value columns (`INSERT INTO t (col, ...) SELECT ...`) so the inferred leading `key BYTES` column is left NULL, rather than relying on positional insertion.

4. **RBAC → prefixed names + per-resource bindings.** Keep all SQL topics/consumer-groups/transactional-ids under the tenant prefix (`shapes-`/`colors-`) so the existing `sa-<group>-flink` PREFIXED `ResourceOwner` bindings authorize the statement's Kafka I/O, and grant each group `DeveloperManage` on its `FlinkCatalog` (CMF cluster-level resource) so group developers can view and use the catalog. Bindings are LITERAL-scoped per catalog to preserve tenant isolation.

5. **Provisioning idempotency/self-heal.** The `sql-init` PostSync-hook Job upserts the compute pool (POST→PUT, non-fatal if a running statement blocks the update) and, for the statement, deletes a `FAILED` statement before recreating (statement SQL is immutable in CMF) and treats `409` as already-present.

These rules are applied symmetrically to both the `shapes` and `colors` tenants.

## Consequences

**Positive:**

- A repeatable, documented placement model: the next CMF SQL statement (new tenant or new query) is configured correctly the first time instead of through trial-and-error at runtime.
- Configuration failures are attributable to a layer, which shortens debugging.
- Tenant isolation is preserved (LITERAL catalog bindings, prefixed Kafka resources); validated with a non-admin group user seeing only its own resources.
- Exactly-once is retained (transaction timeout aligned to the broker rather than dropping to at-least-once).

**Negative / constraints:**

- The OAuth allow-list uses the **shaded** property name, which is image-internal and could change across `cp-flink-sql` releases; it must be re-verified when the image is bumped.
- Table hints are per-statement: a connector option needed by many writers of the same table is duplicated across statements unless promoted to `ALTER TABLE`.
- The explicit `INSERT` column list couples the statement to the inferred table's value schema; adding/removing a value column requires updating the statement.
- Compute-pool config changes only propagate when the pool can be updated; if a statement is running, the operator must delete the statement first (the init Job's self-heal only covers the `FAILED` case).
- `transaction.timeout.ms` is pinned to the broker's current `transaction.max.timeout.ms` (900000); raising the broker limit later would not automatically widen the statement's timeout.

## Related

- [#158](https://github.com/osowski/confluent-platform-gitops/issues/158)
- `workloads/flink-resources-rbac/` (base manifests and README)
- [ADR-0002](0002-cfk-component-sync-wave-ordering.md) — sync-wave ordering for CFK/CMF resources
