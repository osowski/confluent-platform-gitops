# Flink SQL Kafka mTLS (`secure-sql`)

A standalone, single-cluster Flink SQL tenant (`flink-demo-rbac-mtls` only) demonstrating a Kafka client connection authenticated by a cert-manager-issued mTLS client certificate instead of Keycloak OAuth — the cluster's first client-facing mTLS path. See [ADR-0011](../../adrs/0011-flink-sql-kafka-mtls-cert-manager.md) for the design decisions and the constraints found only by running this against a live cluster.

Unlike `shapes`/`colors`, this is an admin-managed demo tenant: no Keycloak realm group, no per-group Kubernetes RBAC. The only variable under test is the Kafka client's auth mechanism.

## The two-object credential split

Two entirely distinct Kubernetes objects both called "the credential," for two different consumers:

- **`secure-sql-mtls-client`** (a cert-manager `Certificate`/`Secret`, `tls.crt`/`tls.key`/`ca.crt`) holds the *actual* mTLS credential material. It is mounted directly, read-only, into both the `FlinkComputePool` pod template and (Reflector-mirrored into `operator`) `cmf-operator`'s own pod — see "Two Applications" below for why this Certificate lives in its own directory rather than here.
- **`kafka-conn-secret-id-secure-sql`** (a `FlinkSecret`, CMF-side) holds only the *paths* those mounted files resolve to (`/etc/flink/secrets/kafka/keystore.pem`/`truststore.pem`) plus `security.protocol: SSL` — no certificate, private-key, or PEM-block byte ever appears in it. Both `cmf-app` (statement compile time) and the compute pool (runtime) read the identical paths, which is why `cmf-operator`'s init container and the compute pool's init container write to the same location using the same command.

## Why `cmf-operator` carries a mount for this tenant

CMF's control-plane pod (`cmf-app`) compiles every Flink SQL statement synchronously against an in-process Flink `TableEnvironment` before any deployment to a compute pool — resolving a table reference against this tenant's `FlinkKafkaDatabase` constructs a live Kafka `AdminClient` **in `cmf-app` itself**. A client certificate isn't network-portable the way an OAuth bearer token is: the private key must physically exist on whatever pod performs the TLS handshake. `workloads/cmf-operator/overlays/flink-demo-rbac-mtls/values.yaml` therefore mounts the same `secure-sql-mtls-client` cert (via Reflector) that the compute pool mounts.

**This is accepted for this experiment only, not the long-term approach** — see [ADR-0011](../../adrs/0011-flink-sql-kafka-mtls-cert-manager.md#decision) for the three candidate long-term resolutions and why none is built yet.

## Two ArgoCD Applications

This tenant is split across two Applications, not one:

| Application | Sync-wave | Sync policy | Owns |
|---|---|---|---|
| `flink-secure-sql-mtls-pki` | 108 | **auto-sync** | `Certificate secure-sql-mtls-client` only (`workloads/flink-secure-sql-mtls-pki/`) |
| `flink-secure-sql-mtls` | 121 | **manual sync** | everything else (this directory) |

The Certificate must be issued and its Secret must exist — Reflector-mirrored into `operator` — *before* `cmf-operator`'s Helm release applies (wave 118). A resource-level sync-wave only orders resources *within* one Application, so the Certificate needs its own, much earlier, auto-syncing Application rather than living inside this tenant's main one (wave 121, long after `cmf-operator`). Per this repo's GitOps convention, which Application owns a resource should be answerable by which directory it lives in — so the Certificate lives in its own sibling directory (`workloads/flink-secure-sql-mtls-pki/`, no shared `base/`, matching the `workloads/mds-keygen/` precedent), not nested inside or cross-referenced from this one.

## Resources and sync waves

| Wave | Resource | Notes |
|---|---|---|
| 0 (via `confluent-resources`) | `flink-sql-mtls` Kafka listener (port **9095** — CFK's `Kafka` CRD schema enforces a `>= 9093` floor on custom listener ports) | mTLS required; `ssl.principal.mapping.rules` set explicitly via `configOverrides.server` — CFK only auto-derives this for built-in listener types (`controller`/`replication`), not custom ones |
| 0 (via `confluent-resources`) | `ConfluentRolebinding`s for `secure-sql-mtls`: `ResourceOwner` `PREFIXED secure-sql-` on `Topic`/`Group`; `ResourceOwner` `LITERAL *` on `TransactionalId` (see note below); `ResourceOwner` `LITERAL _confluent_sr_catalog` on `Topic` | `ClusterAdmin` on `secure-sql-env` for `cmf`/`admin@osow.ski` |
| 108 (own Application) | `Certificate secure-sql-mtls-client` — `privateKey.encoding: PKCS8` (cert-manager's PKCS1 default is rejected by Kafka's PEM keystore loader) | Reflector-mirrored `flink-secure-sql` → `operator` |
| 5 | `FlinkEnvironment secure-sql-env` | |
| 10 | `Secret secure-sql-cmf-kafka-credentials` (paths only); `Secret secure-sql-cmf-sr-credentials` (OAuth, reuses `cmf`) | |
| 20 | `FlinkSecret kafka-conn-secret-id-secure-sql`; `FlinkSecret sr-conn-secret-id-secure-sql` | |
| 30 | `FlinkEnvironmentSecretMapping` × 2 | |
| 30 | `KafkaTopic secure-sql-input`/`secure-sql-output` | |
| 35 | `Schema secure-sql-input-value`/`secure-sql-output-value` (Avro) | |
| 40 | `FlinkKafkaCatalog secure-sql-catalog` (Schema Registry via `cmf` OAuth identity) | |
| 50 | `FlinkKafkaDatabase secure-sql-database` (`bootstrap.servers: kafka.kafka.svc.cluster.local:9095`) | |
| 60 | `FlinkComputePool secure-sql-pool` — mTLS podTemplate (cert mount + PEM-prep init container) + OAuth allow-list for the Schema Registry client (`env.java.opts.all`, same requirement as `shapes-pool`/`colors-pool`) | |
| 70 | `FlinkStatement secure-sql-enrich` — `` INSERT INTO `secure-sql-output` SELECT ... FROM `secure-sql-input` `` | |

**Why `TransactionalId` is `LITERAL *`, not `PREFIXED secure-sql-`:** Confluent's managed Kafka sink connector derives `transactional.id` from the Flink job ID (a random UUID), not the target table name — the standard Flink connector option `sink.transactional-id-prefix` has no effect on it. A prefix pattern can never match an unpredictable per-job ID, so this one resource type is intentionally unscoped for this tenant; `Topic`/`Group` bindings stay properly prefixed.

**Why `_confluent_sr_catalog` needs its own grant:** the SR-catalog mechanism auto-creates this shared internal bookkeeping topic outside any tenant's resource prefix, the first time any catalog uses it.

## Verify

```bash
# Render checks (no live cluster needed)
kubectl kustomize workloads/flink-secure-sql-mtls/overlays/flink-demo-rbac-mtls
kubectl kustomize workloads/flink-secure-sql-mtls-pki/overlays/flink-demo-rbac-mtls
grep -E "BEGIN CERTIFICATE|BEGIN.*PRIVATE KEY|tls\.crt|tls\.key" <(kubectl kustomize workloads/flink-secure-sql-mtls/overlays/flink-demo-rbac-mtls)
# Expected: no output — confirms no cert/key material in any rendered Secret

# Live cluster
confluent --environment secure-sql-env flink statement list
kubectl -n flink-secure-sql get flinkstatement secure-sql-enrich   # phase RUNNING, cfkInternalState CREATED
kubectl -n flink-secure-sql get pods                                # JobManager + TaskManager Running, 0 restarts
```

Live-verified end to end (see [ADR-0011](../../adrs/0011-flink-sql-kafka-mtls-cert-manager.md) for what it took to get here): `secure-sql-enrich` reached `RUNNING`/`STABLE` with every task (`Source`, `Calc`, `ConstraintEnforcer`, `Writer`, `Committer`) `RUNNING` and zero restarts; a batch insert into `secure-sql-input` produced the matching count of records in `secure-sql-output` on the corresponding partition, consumed and re-produced entirely over the mTLS listener.
