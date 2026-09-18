# Milestone: CMF Embedded MDS — `LDAP_WITH_OAUTH` Validated

Tracks the current, live-verified state of CMF's embedded-MDS authentication
on `flink-demo-rbac`, and the remaining gap blocking full Flink SQL
end-to-end verification. See [ADR-0016](../adrs/0016-cmf-embedded-mds-ldap.md)
for the original embedded-MDS decision, [ADR-0017](../adrs/0017-flink-sql-kafka-client-ldap-plain.md)
for the Kafka-client leg, and [ADR-0018](../adrs/0018-cfk-cmf-mtls.md) for
how CFK's own operator-to-CMF connection (`CMFRestClass`) was resolved via
mTLS.

## Status: end-user login — validated and complete

CMF's embedded MDS (`workloads/cmf-operator/overlays/flink-demo-rbac/values.yaml`,
`cmf.mds.user-store: LDAP_WITH_OAUTH`) authenticates end users two ways at
once, both confirmed live:

| Login path | Mechanism | Verified via |
|---|---|---|
| LDAP direct (Basic) | `LdapAuthenticateCallbackHandler` validates username/password against OpenLDAP, embedded MDS self-signs a JWT (`iss: "Confluent"`, RS256, keyed by `cmf.mds.token-key-path`) | CLI (`confluent login`, `admin`/`user-square`) **and** browser — a captured HAR (`GET /security/1.0/authenticate`) shows a real 6-hour JWT for `admin` issued by this exact path |
| OIDC/SSO (Keycloak) | `jwks-endpoint-url`/`expected-issuer` validate IdP-issued tokens for SSO logins | **Now browser-verified end-to-end** ([#428](https://github.com/osowski/confluent-platform-gitops/issues/428)) |

Root cause and fix: [#419](https://github.com/osowski/confluent-platform-gitops/issues/419),
commit `43fca07` — the missing piece was the **top-level** Helm fields
`cmf.mds.jwks-endpoint-url` + `cmf.mds.expected-issuer` (not `extra-configs`,
not `cmf.authentication.config` — both tried and disproven first). Without
them, `RbacApiApplication.createIdpLoginService` throws
`IllegalArgumentException("Issuer must not be null or empty")` on startup
whenever `sso.mode: oidc` is active, crash-looping the CMF pod.

**Resolved ([#428](https://github.com/osowski/confluent-platform-gitops/issues/428)):**
the SSO/OIDC browser-redirect flow itself failed on first real exercise —
Keycloak rejected the token exchange (`"Offline tokens not allowed for the
user or client"`) because the `cmf` Keycloak client had no
`offline_access` client scope wired, and every realm user was missing the
`offline_access`/`uma_authorization` realm roles (statically-imported
users don't get Keycloak's default-role auto-assignment). Both fixed in
`workloads/keycloak/base/realm-configmap.yaml` and mirrored into
`realm-sync-job.yaml`'s Admin API calls for already-provisioned realms.

## Status: CFK `CMFRestClass` — resolved via mTLS ([#423](https://github.com/osowski/confluent-platform-gitops/issues/423))

Separate from the login leg above: CFK's own operator-to-CMF connection
(`CMFRestClass`, used by every `FlinkSecret`/`FlinkKafkaCatalog`/
`FlinkKafkaDatabase`/`FlinkStatement`/`FlinkApplication` CRD) could not
authenticate to CMF in any combination tried (tracked in
[#422](https://github.com/osowski/confluent-platform-gitops/issues/422)).
This is now resolved — see [ADR-0018](../adrs/0018-cfk-cmf-mtls.md) for the
full decision record.

| `authentication.type` tried | Result |
|---|---|
| `oauth` (Keycloak, pre-existing config) | `state: ERROR` — no explicit rejection, reconciliation never succeeds (unchanged before/after #419's fix) |
| `basic` | Rejected at CFK reconcile time: `"authentication type basic is not supported"` |
| `bearer` | Rejected identically: `"authentication type bearer is not supported"` |
| `mtls` | **✅ Working, live-verified.** CFK now authenticates to CMF via a dedicated mTLS CA (`cfk-cmf-mtls-ca`), while LDAP_WITH_OAUTH keeps working for human end-users on the same CMF instance (`cmf.ssl.client-auth: want`, not `need`). Two non-obvious fixes were required beyond `type: mtls` alone — see ADR-0018. |

This resolves [#413](https://github.com/osowski/confluent-platform-gitops/issues/413)'s
remaining live-verification step at the control-plane layer: every
`FlinkSecret`/`FlinkKafkaCatalog`/`FlinkKafkaDatabase`/`FlinkStatement`
previously stuck on the `CMFRestClass` gap now reaches `cmfSync.status:
Created`. A real Flink SQL statement *running to completion* remains
blocked, but by a separate, one-layer-down, already-tracked issue: stale
Kafka-listener credentials on individual catalogs (the same class of defect
[ADR-0017](../adrs/0017-flink-sql-kafka-client-ldap-plain.md) already fixed
for colors/shapes, now also confirmed on the "default" env's `kafka-cat`
catalog) — not a CFK↔CMF auth problem.

## Summary

| Question | Answer |
|---|---|
| Does CMF support LDAP-based end-user login? | **Yes, validated.** LDAP Basic-auth is live and browser-confirmed. |
| Does CMF support LDAP + SSO together (`LDAP_WITH_OAUTH`)? | **Yes, configured and stable — SSO leg now browser-verified too** ([#428](https://github.com/osowski/confluent-platform-gitops/issues/428)). |
| Should this be embedded MDS or CP-MDS (broker-hosted)? | Embedded MDS is proven sufficient for CMF login alone. CP-MDS only earns its complexity if a customer needs one unified RBAC surface across Kafka **and** Flink — a requirement to confirm with them, not assume. |
| Can CFK (the Kubernetes operator) manage Flink SQL resources against this CMF? | **Yes — resolved via mTLS ([#423](https://github.com/osowski/confluent-platform-gitops/issues/423)/[ADR-0018](../adrs/0018-cfk-cmf-mtls.md)).** A running SQL statement still needs the separate, out-of-scope Kafka-credential fix noted above. |
