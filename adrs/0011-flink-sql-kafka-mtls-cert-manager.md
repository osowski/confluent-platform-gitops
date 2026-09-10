# 11. Flink SQL Kafka Client mTLS via cert-manager

Date: 2026-09-01

## Status

Accepted

## Context

`flink-demo-rbac-mtls` already runs mTLS on the Kafka↔KRaft controller quorum and inter-broker replication paths (see the cluster README's [mTLS](../clusters/flink-demo-rbac-mtls/README.md#mtls) section). Every client-facing path — CMF, Control Center, producers, and the `shapes`/`colors` Flink SQL tenants — still authenticates via Keycloak OAuth/OIDC. This is the third mTLS demonstration on this cluster, and the first on a *client* connection: one Flink SQL tenant (`secure-sql`) whose Kafka connection authenticates with a cert-manager-issued client certificate instead of an OAuth token.

## Decision

**1. New standalone `secure-sql` tenant, not a `shapes`/`colors` retrofit.** `shapes`/`colors` are human-facing, group-scoped multi-tenant demos (Kubernetes RBAC, Keycloak groups, per-group service accounts). Retrofitting mTLS onto either would conflate two independent variables (OAuth-vs-mTLS, and per-group-vs-shared identity) in one experiment. `secure-sql` is a new, standalone, admin-managed tenant — no Keycloak realm group, no Kubernetes RBAC `ClusterRole` — so the only variable under test is the Kafka client's auth mechanism.

**2. Scoped RBAC principal (`secure-sql-mtls`), not the `cmf` superuser identity.** The mTLS client certificate's `commonName` (`secure-sql-mtls`) maps via the listener's `principalMappingRules` to a dedicated Kafka RBAC principal `User:secure-sql-mtls`, granted `ResourceOwner` scoped to the tenant's own resource prefix — not the existing `cmf` superuser identity `shapes`/`colors` already share for Kafka control-plane operations. A scoped identity is the only way this experiment demonstrates least-privilege mTLS; reusing `cmf` would prove nothing about RBAC and would make the compute pool a de facto superuser.

**3. Direct PEM over PKCS12/JKS for the Kafka client credential.** The compute pool's `podTemplate` mounts the cert-manager Secret's raw `tls.crt`/`tls.key`/`ca.crt` read-only, and a lightweight init container (reusing the `cp-flink-sql:1.19-cp10` image already pulled for the main container — no extra image pull) concatenates `tls.crt`+`tls.key` into one PEM keystore file and copies `ca.crt` to a PEM truststore file, relying on the shipped Kafka client's KIP-651 PEM keystore support (`ssl.keystore.type=PEM`). This avoids a `keytool`/`openssl` conversion step to PKCS12 or JKS entirely. **Live-verified caveat:** cert-manager's default `privateKey.encoding` is PKCS1 (`BEGIN RSA PRIVATE KEY`), which the PEM keystore loader rejects with `algid parse error, not a sequence` — PKCS8 (`BEGIN PRIVATE KEY`, `spec.privateKey.encoding: PKCS8`) is required.

**4. `cmf-operator` mounts the same client certificate as the compute pool — accepted for this experiment only.** CMF's control-plane pod (`cmf-app`, not a thin K8s controller) compiles every Flink SQL statement — DDL and DML alike — synchronously against an in-process Flink `TableEnvironment` before any deployment to a compute pool. Resolving a table reference against an mTLS-secured `FlinkKafkaDatabase` constructs a live Kafka `AdminClient` *in-process, in `cmf-app` itself*, not in the compute pool. Unlike OAuth (a network-fetched bearer token any pod can use against the IdP), a client certificate's private key must physically exist on whatever pod's filesystem performs the TLS handshake — so every mTLS-secured `FlinkKafkaDatabase` forces a mount onto the single, shared, cluster-scoped `cmf-operator` pod, growing blast radius with every tenant added.

This was posted to #cp-flink Slack; engineering confirmed it is expected, current CMF behavior with no near-term fix. Decision: implement it anyway for this experiment, explicitly **not** as the long-term desired approach — reuse the *same* `secure-sql-mtls-client` certificate on `cmf-operator` via Reflector (mirrored `flink-secure-sql` → `operator`, matching the existing `mds-token`/`cmf-mds-oauth-client` mirroring pattern), synced through its own early, auto-syncing `flink-secure-sql-mtls-pki` Application (sync-wave 108) ahead of `cmf-operator`'s own Helm release (wave 118) — solving the chicken-and-egg problem that a resource-level sync-wave inside the tenant's main Application (wave 121) cannot solve, since sync-wave only orders resources *within* one Application. Three candidate long-term resolutions remain unbuilt, recorded here for whoever revisits this:

1. A shared, read/describe-only mTLS "catalog-reader" identity on `cmf-operator`, RBAC-scoped broadly but read-only, decoupling tenant growth from operator mounts.
2. A dedicated CMF instance per mTLS tenant/trust boundary.
3. Drop mTLS from the Kafka data-plane; use OAuth like `shapes`/`colors`, reserving cert-manager mTLS for a boundary outside `cmf-app`'s catalog path.

Also worth an upstream `cp-flink-cmf` issue independent of this repo: the in-process catalog/statement-compile step doesn't compose with tenant-isolated transport-layer credentials on a multi-tenant control plane.

## Consequences

**Positive.** A least-privilege mTLS demo: the compute pool authenticates as a scoped principal, not a superuser, and no certificate or private-key byte ever appears in a CMF-side `FlinkSecret` — only file paths and the `security.protocol` connection property, with the actual credential material living solely in the cert-manager-managed Secret.

**Negative.** The new `flink-sql-mtls` listener adds one more entry to the cluster's auth matrix to keep straight. `cmf-operator` now carries a per-tenant mount that does not scale past a handful of mTLS tenants — flagged in Decision 4, not fixed.

**Negative — undocumented behaviour, found only by running it against a live cluster.** None of the following are documented by CFK/cert-manager; each was discovered live during Task 7 verification and is recorded here because it generalizes beyond this one tenant:

- **CFK does not apply a custom listener's `authentication.mtls.principalMappingRules` to the broker.** It auto-derives `ssl.principal.mapping.rules` only for *built-in* listener types (`controller`, `replication`); a listener declared under `listeners.custom[]` needs the rule set explicitly via `configOverrides.server` (`listener.name.<name>.ssl.principal.mapping.rules=...`). Without it, the listener silently falls back to the cluster-wide default (the raw certificate DN as principal), which matches no RBAC binding. The failure mode is maximally misleading: Kafka's authorizer hides ACL-denied topics as "does not exist" rather than a permission error, so this surfaced as a clean Calcite `Object not found` from Flink SQL compilation — with the RBAC bindings themselves fully correct (confirmed directly against MDS's `/security/1.0/authorize` API before finding the real cause).
- **A new tenant namespace needs adding to at least three separate allow-lists, each maintained by a different component, each failing silently when missed:** CFK operator's own namespace watch-list (`namespaceList`), the Flink Kubernetes Operator's *independent* namespace watch-list (`watchNamespaces`), and every Reflector-mirrored Secret's `reflection-allowed-namespaces` annotation (here, `minio-credentials`). None of the three surfaces an error when a namespace is missing — the affected component just never reconciles anything there.
- **Kafka's `transactional.id` cannot be prefix-scoped for Confluent's managed Kafka sink connector.** The standard Flink Kafka connector option `sink.transactional-id-prefix` has no effect on it — the connector derives `transactional.id` from the Flink job ID (a random UUID) regardless. A `PREFIXED` RBAC pattern can never match an unpredictable per-job ID; this tenant's `TransactionalId` binding is `LITERAL *` for this reason (Topic/Group bindings stay properly prefixed).
- The `Kafka` CRD's schema enforces a `>= 9093` floor on custom listener ports — an off-cluster planning value of 9073 failed live CRD validation.
- Confluent's SR-catalog mechanism auto-creates a shared internal bookkeeping topic (`_confluent_sr_catalog`) outside any tenant's resource prefix on first catalog use, requiring its own explicit RBAC grant per new mTLS/RBAC principal.

**Neutral.** `cp-flink-sql:1.19-cp10`'s shaded Kafka client still requires the pre-existing OAuth token-endpoint allow-list override (`env.java.opts.all`, same as `shapes-pool`/`colors-pool`) for the Schema Registry client, since SR auth stays on OAuth (the `cmf` identity) even though the Kafka data-plane connection is mTLS-only for this tenant.

## References

- Design spec: `docs/superpowers/specs/2026-08-31-flink-sql-kafka-mtls-cert-manager-design.md` (local, gitignored)
- [ADR-0008](0008-flink-sql-statement-config-placement-rbac.md) — which configuration layer owns a given Flink SQL setting
- [ADR-0010](0010-adopt-cfk-preview-flink-sql-crds.md) — adopting the CFK 3.3 Flink SQL CRDs
- Epic [#271](https://github.com/osowski/confluent-platform-gitops/issues/271) (mTLS migration), [#275](https://github.com/osowski/confluent-platform-gitops/issues/275) (Schema Registry HTTPS + mTLS-to-Kafka)
- Epic [#377](https://github.com/osowski/confluent-platform-gitops/issues/377) and its children [#378](https://github.com/osowski/confluent-platform-gitops/issues/378)–[#385](https://github.com/osowski/confluent-platform-gitops/issues/385), [#392](https://github.com/osowski/confluent-platform-gitops/pull/392)
