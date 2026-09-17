# 17. Flink SQL Kafka Client LDAP PLAIN

Date: 2026-09-16

## Status

Accepted

## Context

Issue #410 switched the `internal` Kafka listener (port 9071, `kafka.kafka.svc.cluster.local:9071`)
to LDAP-backed SASL/PLAIN, disconnecting it from Keycloak OAuth. The colors/shapes Flink SQL
Kafka connection Secrets (`shapes-cmf-kafka-credentials` and `colors-cmf-kafka-credentials` in
`workloads/colors-and-shapes/components/rbac-oauth/flink-secrets.yaml`) continued to declare
`sasl.mechanism: OAUTHBEARER` with Keycloak bearer tokens against that same listener — a
configuration that was incompatible with the listener's new LDAP/PLAIN authentication model
after #410 landed. The incompatibility was discovered by inspection: the CFK-managed
`FlinkKafkaCatalog` and `FlinkKafkaDatabase` resources using these Secrets showed a stale
`Created` status that predated #410's listener swap, and no running `FlinkApplication` existed
to have surfaced the auth failure live.

## Decision

Switch `shapes-cmf-kafka-credentials` and `colors-cmf-kafka-credentials` to `sasl.mechanism: PLAIN`
via `org.apache.kafka.common.security.plain.PlainLoginModule`, with the LDAP service principal
`uid=cmf,ou=services,dc=confluentdemo,dc=local` (password `cmf-secret`), keeping the existing
shared-`cmf`-identity design. This principal was seeded
by #409 (the OpenLDAP directory task) and already holds Kafka superuser permissions from
#410's `kafka-patch.yaml`. Did not implement true MDS-issued-bearer-token/OAUTHBEARER validation
on this listener — that path is deferred to #420, which requires broker-listener and external
MDS changes beyond this plan's scope. The listener validates PLAIN credentials against LDAP only.

## Consequences

**Positive.** Flink SQL's Kafka connection is now LDAP-authenticated and compatible with the
listener's current mode. This is consistent with Schema Registry and Control Center's existing
connections to the same port-9071 listener (#411), both of which already authenticate as their
own LDAP principals (`sr` and `c3`) via MDS-issued bearer tokens.

**Neutral.** The `cmf` principal already holds Kafka `superuser` status from #410, so no
new `ConfluentRolebinding` was needed.

**Negative/Deferred.** Schema Registry's HTTP Basic connection to Schema Registry (a separate,
unrelated listener) remains Keycloak-backed and is not touched by this change — its eventual
swap to LDAP/MDS-bearer authentication is tracked separately in #420 alongside the true
OAUTHBEARER validation path for the port-9071 listener. Two follow-up issues document
the deferred work: #420 (broker-listener OAUTHBEARER support + Schema Registry bearer swap)
and #421 (the raw JAR-based FlinkApplication jobs' independent OAUTHBEARER Kafka config against
the same port-9071 listener, tracked separately since it is a different workload from Flink SQL
statements and out of #413's scope).

## Update (#426, 2026-09-17): Schema Registry leg resolved, without #420's broker changes

The Schema Registry gap flagged above as deferred to #420 has been resolved — for colors/shapes'
Flink SQL Kafka client Secrets (`shapes-cmf-sr-credentials`/`colors-cmf-sr-credentials`) and the
`default` environment's equivalents (which had never received *any* part of this ADR's fix —
`default-cmf-kafka-credentials` was still full OAUTHBEARER, not just its SR leg).

**Turns out #420's premise was wrong: no broker-listener changes were needed.** Schema Registry
has run with `spec.authorization.type: rbac` (MDS-backed, since #411) all along, and MDS-backed
RBAC on Schema Registry validates **HTTP Basic** credentials the same way it validates bearer
tokens — confirmed live via `curl -u cmf:cmf-secret http://schemaregistry.../subjects` → `200`.
Switching `bearer.auth.*` (Keycloak OAuth) to `basic.auth.credentials.source: USER_INFO` /
`basic.auth.user.info: cmf:cmf-secret` (mirroring this ADR's Kafka-side `cmf`/`cmf-secret`
identity) was sufficient — both in the CMF credential-chain Secrets and in each affected
FlinkEnvironment's `flinkConfiguration` (the running job's own runtime Schema Registry client
config, a separate surface from CMF's own catalog-validation client). #420's broker-listener
OAUTHBEARER-support half remains a legitimate, still-undone enhancement if MDS-issued bearer
tokens are ever specifically required, but it is no longer a blocker for anything.

**Root cause was a trust mismatch, not a missing feature**, the same class of bug as #422:
Keycloak-issued tokens are cryptographically foreign to MDS's signing key, so any
schema-touching operation failed with a generic "Catalog could not be created" — confirmed
live by reproducing all three legs directly (LDAP bind, broker SASL/PLAIN auth, and Schema
Registry HTTP Basic auth) as the `cmf` principal, all three succeeding independently of Flink.

**Still open, confirmed but explicitly out of #426's scope:** with credentials fixed, both
`colors-sql-enrich` and `shapes-sql-enrich` now reach real SQL compilation (`Unknown target
column 'timestamp'`) instead of failing at catalog creation — proving this leg is fully fixed.
That compilation failure traces to #421's raw JAR producer jobs (`colors`/`shapes`
`FlinkApplication`s) never having successfully run even once (same stale-Keycloak-credential
pattern, on both their Kafka *and* Schema Registry legs) to register a schema for the topics
`colors-sql-enrich`/`shapes-sql-enrich` read from — Schema Registry has zero subjects
registered. Fixing #421 is now confirmed to be the actual remaining blocker to a Flink SQL
statement running end-to-end, not a merely-adjacent issue.
