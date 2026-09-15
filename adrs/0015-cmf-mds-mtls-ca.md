# 15. CMF mTLS-to-MDS Certificate Authority

Date: 2026-09-15

## Status

Accepted

## Context

Epic #408 moved every other MDS client (`KafkaRestClass`/`SchemaRegistry`/`ControlCenter`,
#411) to LDAP-backed bearer-token authentication. CMF's own leg to MDS
(`cmf.authorization.mdsRestConfig`) cannot follow that path — its Helm
chart's `authentication.type` only supports `oauth` or `mtls`, no
`bearer`/`basic` option. The epic's supportability decision (#408) is for
CMF to use mTLS while everything else uses LDAP-backed bearer tokens.

`flink-demo-rbac` (this cluster) has no existing CA chain — only
`selfsigned-cluster-issuer`, which issues standalone leaf certificates with
no shared signing authority. A sibling cluster, `flink-demo-rbac-mtls`, has
already solved an equivalent problem for a different purpose (Flink SQL
Kafka client mTLS, ADR-0011) via a dedicated root CA (`rbac-mtls-ca`) and
CA-type `ClusterIssuer` (`rbac-mtls-ca-issuer`).

## Decision

Mirror that precedent: a new root `Certificate` (`cmf-mds-mtls-ca`,
`isCA: true`, signed by `selfsigned-cluster-issuer`) backs a new CA-type
`ClusterIssuer` (`cmf-mds-mtls-ca-issuer`), scoped to this cluster only.
Two leaf certificates are issued from it: MDS's own REST-listener server
certificate (CN=`kafka`) and CMF's mTLS client certificate (CN=`cmf`,
mapped via `principalMappingRules` directly onto the existing `User:cmf`
superuser identity — no new RBAC bindings needed).

A real CA (not a single hardcoded leaf trusted directly) was chosen because
MDS's truststore trusting a CA, rather than one specific leaf certificate,
lets future mTLS-to-MDS clients be added by issuing new leaves from the
same issuer — no MDS-side truststore change required per additional client.

cert-manager's native `spec.keystores.jks` (not a hand-rolled PEM→JKS
conversion) generates the JKS keystore/truststore CMF's chart-side
`confluent.metadata.ssl.*` config requires — this is a different
credential-format requirement than ADR-0011's Flink Kafka client (which
needed raw PEM for its KIP-651 keystore loader); the two should not be
conflated even though both are "cert-manager mTLS for Confluent Platform."

## Consequences

**Positive.** No manual keystore-conversion tooling (no init container, no
`keytool`/`openssl` step) — cert-manager generates the JKS files natively
in the same Secret as the standard PEM output. A single CA covers both the
MDS server identity and CMF's client identity, and can issue further
mTLS-to-MDS client certs later without new MDS-side trust configuration.

**Negative.** A fourth distinct CA/issuer now exists across this repo's
cluster fleet (`selfsigned-cluster-issuer`, `rbac-mtls-ca-issuer` on
`flink-demo-rbac-mtls`, and now `cmf-mds-mtls-ca-issuer` here) — one more
trust root to track per cluster. Scoped deliberately to this cluster only,
not shared, to avoid cross-cluster trust coupling.
