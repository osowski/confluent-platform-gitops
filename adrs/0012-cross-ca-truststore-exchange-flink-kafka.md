# ADR-0012: Cross-CA Truststore Exchange Between CP Flink and a Kafka Endpoint

## Status

Accepted (spike findings — Issue #395, Epic #377)

## Context

Epic #377's `secure-sql` tenant (ADR-0011) proved mTLS *credential delivery*:
a cert-manager-issued client certificate reaches a Flink SQL job's Kafka
connection without ever passing through CMF config. It did not prove
*trust negotiation*, because `secure-sql-mtls-client` and the broker's
`kafka-broker-mtls` server certificate are both signed by the same
`rbac-mtls-ca-issuer`. Nothing in that work ever exchanged a truststore
across two independent PKIs.

That is the actual customer-reported scenario that motivated the epic: a
Flink client and a Kafka endpoint whose certificates are signed by
**different, mutually-untrusted CAs**. A background documentation search
(2026-09-01) confirmed `docs-cp-flink/configure/catalog.rst`'s
`FlinkKafkaCatalog`/`FlinkKafkaDatabase` `connectionConfig` documents only
`bootstrap.servers`/`schema.registry.url`/plain `SASL_PLAINTEXT` — no
`ssl.truststore.*` guidance anywhere in `docs-cp-flink` or `docs-platform`.

This ADR records the spike (Issue #395) in two passes. The first (findings
1–3 below) reproduced both trust-direction failures with a second CA the
broker never trusts, using a disposable `ClusterIssuer` (`foreign-ca-issuer`)
pointed at the existing `flink-sql-mtls` listener without modifying it.

The second pass corrects the framing of the problem itself. The right
mental model, confirmed via internal engineering guidance:

> CFK-managed components can authenticate to Kafka with client
> certificates, provided Kafka's mTLS listener trusts the CA chain that
> issued those client certificates. It does not necessarily have to be
> the same CA used for Kafka's server certificate, but that CA must be
> present in the listener's client-authentication truststore. For large
> client populations, trusting an issuing/intermediate CA is generally
> preferable to adding every client certificate individually.

Two disjoint, mutually-untrusted CAs is the trivially-broken case
(findings 1–3). The actually-supported production pattern is a
**different-but-explicitly-trusted** client CA — so findings 4–5 execute
and verify that pattern live: a root/intermediate CA pair, independent of
`rbac-mtls-ca-issuer`, merged into the `flink-sql-mtls` listener's trust
anchors, with two leaf certificates issued from the intermediate to prove
trust delegates through the chain. All spike resources (both passes) were
disposable and have been deleted; the live `secure-sql` tenant was
verified healthy before, during, and after every live change.

## Decision

### 1. Two independent trust directions exist, and only one is mTLS-specific

TLS establishes trust in both directions independently:

- **Server-trust direction** (applies to plain TLS too, not just mTLS):
  the Flink client must trust the CA that signed the broker's server
  certificate. This is `ssl.truststore.location`/`type` on the Flink
  Kafka connector config.
- **Client-trust direction** (mTLS-specific): the broker must trust the
  CA that signed the client's certificate. This is the broker
  listener's own truststore, built by CFK from the `Certificate`'s
  cert-manager Secret.

A customer can have either direction wrong independently. "Exchange a
truststore" is really two separate, independently-failing configurations.

### 2. The server-trust failure is clear; the client-trust failure is not

Reproduced against the live `flink-sql-mtls` listener (broker cert signed
by `rbac-mtls-ca-issuer`):

| Direction | Client config | Result |
|---|---|---|
| Server-trust broken | Client trusts only `foreign-ca` (not `rbac-mtls-ca`) | `SslAuthenticationException: SSL handshake failed` → `PKIX path building failed: unable to find valid certification path to requested target`. Clear, standard, well-documented TLS error. |
| Client-trust broken | Client correctly trusts `rbac-mtls-ca`, but presents a `foreign-ca`-signed client cert | `SslAuthenticationException: Failed to process post-handshake messages, SNI host name: empty`. Opaque — does not read as a certificate-trust error, gives no indication which side or which CA is at fault. |

The second result is TLS 1.3's client-certificate exchange happening as a
**post-handshake** message flow (client `Certificate` + `CertificateVerify`
sent *after* the server's initial `Finished`), so a broker's rejection of
an untrusted client cert surfaces to the Kafka client library as a generic
post-handshake processing failure rather than a `PKIX path building
failed`-style message. This is almost certainly close to what the
customer actually hit.

### 3. The broker gives zero log evidence for the client-trust failure, even at DEBUG

Enabled DEBUG on `kafka.network.Processor`,
`org.apache.kafka.common.network.{Selector,SslTransportLayer,KafkaChannel}`
on all 3 brokers via the broker-logger API and re-ran the client-trust
failure. Result: **no log line, at any level, on any broker, mentions the
connection, the listener, or the failure** — confirmed by exact-timestamp
log inspection immediately before and after the failing request. The
client-side exception is the *only* evidence this event happened; the
server side is completely silent. This is a stronger and more actionable
finding than "the client error message is unclear" — an operator debugging
this live has no broker-side log to correlate against, at any verbosity.

### 4. CFK's custom-listener TLS has no multi-CA field — but has a per-listener escape hatch

`kubectl explain kafka.spec.listeners.custom.tls` exposes only
`secretRef` (+ `jksPassword`, `ignoreTrustStoreConfig`,
`directoryPathInContainer`) — no `trustStoreRef` or equivalent for a
second, independent trust anchor. CFK builds the listener's broker-side
truststore as a PKCS12 file (`/mnt/sslcerts/truststore.p12`, confirmed
live via `kafka-configs --describe --all` on `flink-sql-mtls`) from
whatever is in the `ca.crt` key of the `Certificate`'s cert-manager-managed
Secret. To trust a second CA, that `ca.crt` key needs both roots' PEM
content present before CFK's init-container builds the PKCS12 truststore.

Two mechanical constraints shape how to actually do that safely:

- `kafka-broker-mtls` (the cluster-wide `spec.tls.secretRef`, feeding
  every TLS-enabled listener) is **owned by cert-manager** — hand-editing
  its `ca.crt` gets reconciled back to the single-CA chain on
  cert-manager's own schedule, so a durable merge can't live there
  directly.
- `spec.listeners.custom[].tls.secretRef` is a **per-listener override**
  of the cluster-wide default. Pointing just `flink-sql-mtls` at a
  separate, non-cert-manager-managed Secret changes trust for that one
  listener only, leaving `kafka-broker-mtls`, replication, and every
  other listener completely untouched.

Executed live: built a Secret (`kafka-broker-mtls-spike-merged`, in the
`kafka` namespace, not cert-manager-managed) by copying `kafka-broker-mtls`'s
existing `tls.crt`/`tls.key` verbatim — the broker's server identity
doesn't change, so existing `secure-sql` clients' server-trust direction
is unaffected — and setting `ca.crt` to the original `rbac-mtls-ca` cert
concatenated with a new intermediate CA's cert (see finding 5). A JSON
patch added `tls.secretRef: kafka-broker-mtls-spike-merged` to
`flink-sql-mtls` only (`spec.listeners.custom[1].tls.secretRef`).

CFK's operator picked up the change as a **partition-based staged rolling
restart** of the Kafka StatefulSet (`spec.updateStrategy.rollingUpdate.partition`,
decremented by the operator itself, not `kubectl rollout`'s own default
behavior — `kubectl rollout status` reports "complete" as soon as the pods
above the *current* partition value are updated, which can be a false
signal if the operator hasn't finished decrementing the partition to 0
yet; watch `.status.updatedReplicas` against the StatefulSet's replica
count, not `kubectl rollout status` alone). All 3 brokers restarted, one
at a time; `secure-sql`'s running `FlinkStatement` pods were verified
`Running` with unchanged pod age before, during, and after — confirming
the additive trust change caused zero disruption to the existing tenant.
The same secretRef patch was removed and the StatefulSet rolled a second
time to restore the original single-CA state exactly.

### 5. A different-but-trusted client CA works exactly as described, including through an intermediate

Built a root CA (`client-only-ca`, self-signed) → intermediate CA
(`client-only-intermediate`, signed by the root) → two leaf client
certificates (`client-leaf-1`, `client-leaf-2`, both issued from the
intermediate). The broker's merged truststore (finding 4) trusted the
**intermediate directly** — the root was never added to it, matching the
"trust the issuing CA" half of the corrected framing.

| Test | Client CA relationship to broker's trust | Result |
|---|---|---|
| Untrusted (finding 2, `foreign-ca`) | No relationship — broker trusts neither the CA nor anything it issued | Opaque post-handshake failure |
| `client-leaf-1` | Broker's truststore has the *intermediate* that issued this leaf (root never added) | **Connected successfully** — `kafka-topics --list` returned cleanly, no `SslAuthenticationException` |
| `client-leaf-2` (different leaf, same intermediate) | Same trust state as above, zero additional broker-side change | **Connected successfully**, proving trust delegates to every certificate the trusted intermediate issues |

Both successful connections returned an empty topic list rather than an
error — expected, since these throwaway principals (`User:client-leaf-1`,
`User:client-leaf-2`, via the existing
`ssl.principal.mapping.rules`) were never granted any `ConfluentRolebinding`.
Authentication (TLS trust) and authorization (RBAC) are independent
layers; this spike verifies the former; the latter is already established
in ADR-0011. The absence of an `SslAuthenticationException` — the same
evidence standard used in findings 1–2 — is what actually confirms the
handshake succeeded.

## Consequences

- **The corrected mental model is confirmed, not just asserted:** a
  Flink client certificate does not need to share a CA with the Kafka
  broker's server certificate. It only needs its issuing CA (root or
  intermediate) present in the broker listener's client-authentication
  truststore. Trusting one intermediate CA covers every certificate it
  issues — no per-client broker configuration required.
- **For customers hitting this today:** if a Flink-to-Kafka mTLS
  connection fails with `Failed to process post-handshake messages, SNI
  host name: empty` (or any post-handshake `SslAuthenticationException`
  that isn't a `PKIX path building failed`), the fix is almost always to
  add the client certificate's issuing CA to the broker listener's
  truststore — **not** to reissue the client certificate from the same
  CA as the broker. The broker's own logs will not confirm this
  diagnosis either way (finding 3); rely on the client-side exception
  shape instead.
- **The safe, low-blast-radius way to merge a CA into an existing listener**
  (verified live, see finding 4): don't touch the cert-manager-owned
  cluster-wide TLS secret. Build a separate, non-cert-manager-managed
  Secret carrying the existing server `tls.crt`/`tls.key` plus a merged
  `ca.crt`, and set it via that one listener's own
  `spec.listeners.custom[].tls.secretRef`. This confines both the trust
  change and the resulting rolling restart to the one listener/tenant
  that needs it.
- **Documentation gap, confirmed:** `docs-cp-flink/configure/catalog.rst`
  should gain an SSL/mTLS `connectionConfig` example
  (`ssl.truststore.location`, `ssl.truststore.type`, PEM vs. JKS vs.
  PKCS12) alongside the existing `SASL_PLAINTEXT` example, plus the
  corrected framing from this ADR: client and server CAs may differ,
  trust is established by adding the issuing CA to the relevant
  truststore, and trusting an intermediate scales better than trusting
  individual leaf certificates. Filed as a documentation follow-up (see
  Issue #395).
- A production version of this pattern (e.g., onboarding a real
  customer-supplied CA) should use a durable, GitOps-managed way to keep
  the merged `ca.crt` in sync — a `trust-manager` `Bundle` writing into a
  dedicated, non-cert-manager-owned Secret referenced by the listener's
  `tls.secretRef`, rather than the one-off Secret built for this spike.
  That's a real implementation task, not a spike, if a concrete cross-CA
  customer scenario needs a permanent home in this repo.
- Spike resources (`foreign-ca`, `foreign-ca-issuer`, `foreign-mtls-client`,
  `client-only-ca`, `client-only-ca-issuer`, `client-only-intermediate`,
  `client-only-intermediate-issuer`, `client-leaf-1`, `client-leaf-2`,
  `kafka-broker-mtls-spike-merged`, the `flink-sql-mtls` listener's
  temporary `tls.secretRef` override, and the temporary broker-logger
  DEBUG overrides) were all deleted/reverted after the findings were
  recorded, per Issue #395. `secure-sql`'s `FlinkStatement` pods were
  confirmed `Running` with unchanged pod age throughout every live
  change. No permanent GitOps changes resulted from this spike.

## References

- Issue #395 (spike)
- Epic #377
- ADR-0011 (secure-sql mTLS credential delivery — the foundation this
  spike builds on)
