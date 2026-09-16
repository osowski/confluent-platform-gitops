# Milestone: CMF Embedded MDS — `LDAP_WITH_OAUTH` Validated

Tracks the current, live-verified state of CMF's embedded-MDS authentication
on `flink-demo-rbac`, and the one open gap blocking full Flink SQL
end-to-end verification. See [ADR-0016](../adrs/0016-cmf-embedded-mds-ldap.md)
for the original embedded-MDS decision and [ADR-0017](../adrs/0017-flink-sql-kafka-client-ldap-plain.md)
for the Kafka-client leg.

## Status: end-user login — validated and complete

CMF's embedded MDS (`workloads/cmf-operator/overlays/flink-demo-rbac/values.yaml`,
`cmf.mds.user-store: LDAP_WITH_OAUTH`) authenticates end users two ways at
once, both confirmed live:

| Login path | Mechanism | Verified via |
|---|---|---|
| LDAP direct (Basic) | `LdapAuthenticateCallbackHandler` validates username/password against OpenLDAP, embedded MDS self-signs a JWT (`iss: "Confluent"`, RS256, keyed by `cmf.mds.token-key-path`) | CLI (`confluent login`, `admin`/`user-square`) **and** browser — a captured HAR (`GET /security/1.0/authenticate`) shows a real 6-hour JWT for `admin` issued by this exact path |
| OIDC/SSO (Keycloak) | `jwks-endpoint-url`/`expected-issuer` validate IdP-issued tokens for SSO logins | Configured and live (pod stable, no crash) — **not yet independently exercised via a browser SSO redirect**; only the LDAP-direct path has browser evidence so far |

Root cause and fix: [#419](https://github.com/osowski/confluent-platform-gitops/issues/419),
commit `43fca07` — the missing piece was the **top-level** Helm fields
`cmf.mds.jwks-endpoint-url` + `cmf.mds.expected-issuer` (not `extra-configs`,
not `cmf.authentication.config` — both tried and disproven first). Without
them, `RbacApiApplication.createIdpLoginService` throws
`IllegalArgumentException("Issuer must not be null or empty")` on startup
whenever `sso.mode: oidc` is active, crash-looping the CMF pod.

**Open item:** the SSO/OIDC browser-redirect flow itself remains
unverified — flag before treating that leg as proven, not just configured.

## Status: CFK `CMFRestClass` — open gap, blocks CRD-based Flink SQL

Separate from the login leg above: CFK's own operator-to-CMF connection
(`CMFRestClass`, used by every `FlinkSecret`/`FlinkKafkaCatalog`/
`FlinkKafkaDatabase`/`FlinkStatement`/`FlinkApplication` CRD) cannot
currently authenticate to CMF in any combination tried. Tracked in
[#422](https://github.com/osowski/confluent-platform-gitops/issues/422).

| `authentication.type` tried | Result |
|---|---|
| `oauth` (Keycloak, pre-existing config) | `state: ERROR` — no explicit rejection, reconciliation never succeeds (unchanged before/after #419's fix) |
| `basic` | Rejected at CFK reconcile time: `"authentication type basic is not supported"` |
| `bearer` | Rejected identically: `"authentication type bearer is not supported"` |
| `mtls` | **Not yet tried** — the one mechanism `co-flink-overview.rst` actually documents as supported ("CO can authenticate to CMF without authentication or using mTLS"), despite `basic`/`bearer`/`oauth` being schema-legal on the CRD |

**This blocks [#413](https://github.com/osowski/confluent-platform-gitops/issues/413)'s
remaining live-verification step** (force-recreating `FlinkKafkaCatalog`/
`FlinkKafkaDatabase` and running a real Flink SQL statement) — that step
needs a working `CMFRestClass`, which #422 currently prevents regardless of
`cmf.mds.user-store`.

**Per standing direction:** don't keep permuting `CMFRestClass` auth types
speculatively. The next step here should be driven by a specific,
customer-validated requirement — `mtls` is the doc-confirmed candidate if
CRD-based Flink SQL management via CFK turns out to be needed at all; if a
customer manages Flink purely through CMF's own UI/REST/CLI, this gap may
not matter to them.

## Summary

| Question | Answer |
|---|---|
| Does CMF support LDAP-based end-user login? | **Yes, validated.** LDAP Basic-auth is live and browser-confirmed. |
| Does CMF support LDAP + SSO together (`LDAP_WITH_OAUTH`)? | **Yes, configured and stable.** SSO leg not yet independently browser-verified. |
| Should this be embedded MDS or CP-MDS (broker-hosted)? | Embedded MDS is proven sufficient for CMF login alone. CP-MDS only earns its complexity if a customer needs one unified RBAC surface across Kafka **and** Flink — a requirement to confirm with them, not assume. |
| Can CFK (the Kubernetes operator) manage Flink SQL resources against this CMF? | **No — open gap (#422).** Only matters if the customer needs CRD-based management rather than CMF's own UI/REST/CLI. |
