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
