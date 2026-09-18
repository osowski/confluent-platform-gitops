# 18. CFK<->CMF mTLS

Date: 2026-09-17

## Status

Accepted

## Context

Issue #422 tracked an open gap on `flink-demo-rbac`: CFK's own operator-to-CMF
connection (`CMFRestClass`, used by every `FlinkSecret`/`FlinkKafkaCatalog`/
`FlinkKafkaDatabase`/`FlinkStatement`/`FlinkApplication` CRD) could not
authenticate to CMF in any combination tried after #419 moved CMF's
end-user login to embedded-MDS `LDAP_WITH_OAUTH` (see
[the milestone doc](../docs/milestone-cmf-embedded-mds-ldap-with-oauth.md)):
`oauth` reconciled to `state: ERROR` with no explicit rejection, and
`basic`/`bearer` were hard-rejected at reconcile time
(`"authentication type basic/bearer is not supported"`). `docs-operator/co-flink-overview.rst`
documents mTLS as the one mechanism CFK's operator actually supports for this
connection (*"CO can authenticate to CMF without authentication or using
mTLS"*), so #423 tried it — the milestone doc's own summary table had left it
as "Not yet tried."

CMF's login leg (embedded MDS, `LDAP_WITH_OAUTH`) and its CFK-connection leg
(`cmf.authentication`/`cmf.ssl`, the app's own incoming-request validation)
are independent systems (confirmed via the chart's `values.schema.json` and
`templates/configmap.yaml`) — this ADR's decision only touches the latter.

## Decision

Issue a dedicated CA (`cfk-cmf-mtls-ca`, self-signed, `infrastructure/cert-manager-resources/overlays/flink-demo-rbac/cfk-cmf-mtls-ca.yaml`)
separate from any other cluster's mTLS CA, and two leaf certificates from it:
CMF's server cert (`cmf-server-tls`, JKS output via `keystores.jks.create: true`
— cert-manager has no separate `spec.truststore` field despite the plan's
original guess; one `Certificate` produces both `keystore.jks` and
`truststore.jks` under one shared password) and CFK's client cert
(`cfk-cmf-client-tls`, plain PEM — `ca.crt`/`tls.crt`/`tls.key`, cert-manager's
native key names; no copy-Job was needed because `CMFRestClass.spec.cmfRest.tls.jksPassword`
is optional, so `tls.secretRef` alone accepts PEM directly, confirmed live).

Configure CMF for **dual-auth** rather than an all-or-nothing switch:

```yaml
# workloads/cmf-operator/overlays/flink-demo-rbac/values.yaml
cmf:
  ssl:
    keystore: /mnt/secrets/tls/keystore.jks
    keystore-password: ${CMF_SSL_KEYSTORE_PASSWORD}
    trust-store: /mnt/secrets/tls/truststore.jks
    trust-store-password: ${CMF_SSL_TRUSTSTORE_PASSWORD}
    client-auth: want   # not need - LDAP/UI/SSO sessions present no cert
  authentication:
    type: mtls
    config:
      auth.ssl.principal.mapping.rules: "RULE:^CN=(.*?),.*$/$1/,RULE:^CN=([^,]+)$/$1/,DEFAULT"
      ssl.client.authentication: REQUESTED
```

`client-auth: want` (Spring Boot's `server.ssl.client-auth`, a sibling block
of `cmf.authentication`, not nested inside it) keeps the CMF UI and
`LDAP_WITH_OAUTH` browser/CLI logins from #419 working unmodified — only
CFK's `CMFRestClass` is expected to ever present a client certificate.

Two field-name corrections from the plan's original draft, confirmed against
`docs-cp-flink/installation/authentication.rst`'s own worked mTLS example
(not just inferred): `extraEnv`/`${ENV_VAR}` placeholders are required for the
keystore passwords (`secretKeyRef` nested under `cmf.ssl` is passed through
`toYaml` verbatim with no Helm-side secret resolution), and the field names
are the asymmetric `keystore`/`keystore-password` (no hyphen) plus
`trust-store`/`trust-store-password` (hyphenated) — not a uniform pair.

`CMFRestClass` (`workloads/flink-resources/overlays/flink-demo-rbac/cmfrestclass-mtls-patch.yaml`)
switches to `type: mtls` via an overlay-local strategic-merge patch, layered
on top of the shared `components/oauth` base used by `flink-demo-rbac-mtls`
and `eks-demo` (both untouched — #423 is scoped to `flink-demo-rbac` only).
Kustomize's SMP merge for this CRD is a plain deep JSON-merge (no registered
OpenAPI merge schema), so the patch must explicitly null out the oauth
component's leftover block (`authentication.oauth: null`) or it survives
alongside the new `mtls` fields instead of being replaced.

RBAC binding for the mapped certificate principal: `mds.super-users:
"User:admin;User:cfk-operator"` — semicolon-separated, confirmed (not
assumed) by extracting `CacheBackedAuthorizer.configure()` from a full CMF
Java source checkout (`raw.toString().split(";")`), consistent with
`MdsConfig.java`'s own `"Type:Name"` javadoc. A successful mTLS handshake
does not itself grant CMF RBAC access — the mapped principal needs this
separate grant alongside the pre-existing LDAP `User:admin` super-user
binding.

### Two additional bugs found only by live verification (commit `eec5c32`)

Both Tasks 1-3's own live-verification steps and the CRD schema left these
two facts unknowable ahead of time; both were caught by actually reconciling
against a running CMF pod, not guessed at:

1. **`cmf.ssl.client-auth` alone does not make CMF extract a certificate
   principal.** It only governs the Tomcat/Spring Boot TLS socket's
   willingness to *request* a client certificate at the transport layer.
   CMF's own application-level authenticator (a jetty8-era
   `AuthenticationHandler` from the shared security-plugins library, bridged
   into Spring via `SecurityInterceptor` — see `cp-flink-cmf`'s
   `SecurityInterceptor.java`) has its own, separate
   `ssl.client.authentication` property, defaulting to `NONE`, which skips
   client-cert principal extraction entirely regardless of the TLS-layer
   setting. Confirmed live: CMF logged *"Skipping impersonation identity
   validation as client auth is not set"* and every CFK request got an
   identical 401 whether or not it presented a cert. `REQUESTED` (not
   `REQUIRED`) is the documented value for this exact dual-auth shape — see
   `docs-platform/security/authorization/rbac/migrate-ldap-to-mtls.rst` —
   `REQUIRED` would force every request, including LDAP/browser sessions, to
   present a client certificate, breaking #419's login path.
2. **The CFK client cert's bare-CN subject fell through the principal-mapping
   rule to `DEFAULT`.** Task 1 only set `commonName` (no OU/O components) on
   the client cert, so the original rule
   (`RULE:^CN=(.*?),.*$/$1/,DEFAULT`, which requires a trailing comma-separated
   RDN) never matched; the raw DN string (`"CN=cfk-operator"`) was used as
   the principal verbatim, never matching the `User:cfk-operator` RBAC
   grant. Fixed by adding a second rule for a bare CN with nothing after it,
   ahead of `DEFAULT`.

## Live Verification (Task 4)

Direct `openssl`/`curl` mTLS test against the CMF pod, from a pod mounting
`cfk-cmf-client-tls` directly: **200 with the CFK client cert presented, 401
without it** — deterministic proof the fix works at the transport+authn
layer, independent of CFK's operator.

`CMFRestClass.status` never populates a `state` field on success in this CFK
operator build (only on `ERROR`) — `endpoint` set + `observedGeneration`
matching `metadata.generation` + no `state` field is this environment's
"healthy" signal, not the `state: CREATED` the CRD schema's `enum` might
suggest. Confirmed reproducible: a genuinely healthy `CMFRestClass` and a
genuinely broken one (transiently reverted to the pre-#423 `oauth` config
mid-session by an operator error unrelated to this feature, then corrected)
both live-differ only in whether `state` is absent or `"ERROR"`.

All four downstream CRD kinds (`FlinkSecret`, `FlinkKafkaCatalog`,
`FlinkKafkaDatabase`, `FlinkStatement`) reach `cmfSync.status: Created` live,
across all three namespaces (`flink`, `flink-colors`, `flink-shapes`) —
including `kafka-conn-secret-id-colors`/`kafka-conn-secret-id-shapes` and
`colors-sql-enrich`/`shapes-sql-enrich`, stuck in the CMFRestClass "phase
error" state since before #419. `FlinkApplication default-flink-app` (a
JAR-based `StateMachineExample` job, not a SQL statement) reaches
`cmfSync.status: Created` and its Flink job reaches `RUNNING`/`STABLE` live.

`LDAP_WITH_OAUTH` login (#419) has no regression: both `admin`/`admin123` and
`user-square`/`square123` still authenticate successfully via
`confluent login --url https://cmf.flink-demo-rbac.confluentdemo.local:<port>
--certificate-authority-path <cmf-server-tls ca.crt>` against CMF's embedded
MDS, unaffected by `client-auth: want`.

An actual Flink SQL `FlinkStatement` running to completion could **not** be
demonstrated in this environment, but not for a reason this ADR's own scope
owns: every catalog available on this cluster — `colors-catalog`/
`shapes-catalog` (`sasl.mechanism: PLAIN`, per ADR-0017) and `kafka-cat`
(`sasl.mechanism: OAUTHBEARER`, apparently never updated after #410 moved the
`kafka.kafka.svc.cluster.local:9071` listener to LDAP/PLAIN-only) — fails
Flink's own catalog initialization with a `ConfigException` inside the Flink
job, a level below and unrelated to CFK<->CMF authentication. Every one of
these `FlinkStatement`s still reaches `cmfSync.status: Created` (proving
#423's own scope works even for a statement that then fails for an unrelated
reason); ad hoc `FlinkStatement`s created purely to test this reach the same
`cmfSync.status: Created` / catalog-`ConfigException` outcome. See
[ADR-0017](0017-flink-sql-kafka-client-ldap-plain.md) for the pre-existing,
already-tracked root cause; fixing `kafka-cat`'s credentials to match is out
of #423's scope.

## Consequences

**Positive.** CFK can now manage Flink SQL/CRD resources against a CMF that
also serves LDAP-authenticated human/CLI logins — the two use cases no
longer force an all-or-nothing choice of authentication mechanism. All four
previously-stuck CRD kinds (`FlinkSecret`, `FlinkKafkaCatalog`,
`FlinkKafkaDatabase`, `FlinkStatement`) heal, unblocking #413's remaining
CRD-based-Flink-SQL-management goal at the CFK<->CMF layer.

**Neutral.** `CMFRestClass.status.state` is not a reliable "is it working"
signal in this CFK operator build — its absence (not an explicit `CREATED`)
is what a healthy reconcile actually looks like. Anyone debugging this again
should check `endpoint`/`observedGeneration` and, more usefully, whether
downstream CRDs' `cmfSync.status` reaches `Created`, rather than waiting for
a `state: CREATED` that may never appear.

**Negative/Deferred.** A real end-to-end Flink SQL statement still cannot run
to completion on this cluster — blocked entirely by the pre-existing,
already-tracked Kafka-listener-credential mismatch (ADR-0017), not by
anything in this ADR's scope. `kafka-cat`'s Kafka credentials
(`default-cmf-kafka-credentials`, still `OAUTHBEARER`) appear to have the
same class of staleness ADR-0017 already fixed for colors/shapes; updating
them is a follow-up, tracked separately, not part of #423.
