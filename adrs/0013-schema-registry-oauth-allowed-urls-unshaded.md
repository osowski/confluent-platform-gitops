# 13. JAR FlinkApplications Need Their Own Unshaded OAuth Allow-List

Date: 2026-09-04

## Status

Accepted

## Context

Issue [#400](https://github.com/osowski/confluent-platform-gitops/issues/400): the `colors` and `shapes` `FlinkApplication`s on `eks-demo` crash-looped with:

```
Caused by: org.apache.kafka.common.config.ConfigException: Invalid value
http://keycloak.keycloak.svc.cluster.local:8080/realms/confluent/protocol/openid-connect/token
for configuration bearer.auth.issuer.endpoint.url: The URL cannot be accessed due to
restrictions. Update the system property 'org.apache.kafka.sasl.oauthbearer.allowed.urls'
to allow the URL to be accessed.
```

[ADR-0008](0008-flink-sql-statement-config-placement-rbac.md) already established an OAUTHBEARER token-endpoint allow-list requirement and set it on `shapes-pool`/`colors-pool` (`FlinkComputePool`), using the **shaded** property name (`org.apache.flink.kafka.shaded.org.apache.kafka...`), because that pool runs `cp-flink-sql` SQL statements (`colors-sql-enrich`/`shapes-sql-enrich`) whose bundled Flink Kafka SQL connector — including its Schema Registry client dependency — is relocated under that shaded package. Those statement pods have run for 17+ days with no restarts; the compute pool's fix is correct and sufficient for them.

The `colors`/`shapes` `FlinkApplication`s are a **different** artifact entirely: a custom JAR (`quay.io/osowski/flink-kafka-demo`) that links the plain (unshaded) `kafka-clients` and Confluent Schema Registry client libraries directly, and runs as its own dedicated Flink application-mode deployment — it does **not** reference or run on `colors-pool`/`shapes-pool` at all. Live inspection confirmed the deployed `FlinkApplication` CR had no `env.java.opts.all` in its `flinkConfiguration` whatsoever; the compute pool's system property, even if it had also set the unshaded name, would never have reached this JAR's JVM. The failing config, `schema.registry.bearer.auth.issuer.endpoint.url`, is checked by this JAR's own (unshaded) Schema Registry client, which reads the plain `org.apache.kafka.sasl.oauthbearer.allowed.urls` system property — exactly the name the runtime error reports, since string literals aren't rewritten by class relocation even when it does apply.

(An earlier draft of this fix mistakenly added the unshaded property to `shapes-pool`/`colors-pool` instead, on the assumption the JAR apps ran on that pool. Live-testing on `eks-demo` before merging caught that the pool's config never reaches this JAR's containers.)

## Decision

Set the JAR `FlinkApplication`'s own OAuth allow-list directly in its own `flinkConfiguration`, using the **unshaded** property name, in `flink-application-colors-oauth-patch.yaml` and `flink-application-shapes-oauth-patch.yaml`:

```
env.java.opts.all: "-Dorg.apache.kafka.sasl.oauthbearer.allowed.urls=<keycloak token url>"
```

This is independent of, and in addition to, the compute-pool-level shaded property ADR-0008 already covers for the SQL-statement path. A tenant with both a JAR `FlinkApplication` and a compute-pool-backed SQL statement needs the allow-list set in both places, with different property names, because each runs a different Kafka/Schema-Registry client implementation.

## Consequences

**Positive:**

- `colors`/`shapes` `FlinkApplication`s no longer crash-loop on Schema Registry OAuth.
- Clarifies, for the next tenant, that "which config layer owns this JVM property" depends on which artifact (JAR app vs. compute-pool-backed SQL statement) is actually running the failing client — not just which namespace or tenant it's in.

**Negative / constraints:**

- The unshaded property name is only correct as long as this JAR keeps using plain `kafka-clients`/Schema-Registry-client libraries; if it's ever rebuilt against a shaded/relocated dependency, this would need to flip to the shaded name instead.
- Two independent config locations (JAR `FlinkApplication` vs. `FlinkComputePool`) must both be kept pointed at the same Keycloak URL by hand for any tenant that has both artifact types.

## Related

- [#400](https://github.com/osowski/confluent-platform-gitops/issues/400)
- [ADR-0008](0008-flink-sql-statement-config-placement-rbac.md) — the shaded-property requirement for the compute pool's SQL-statement path; this ADR covers the separate unshaded requirement for the JAR `FlinkApplication` path
- `workloads/colors-and-shapes/components/rbac-oauth/flink-application-colors-oauth-patch.yaml`
- `workloads/colors-and-shapes/components/rbac-oauth/flink-application-shapes-oauth-patch.yaml`
