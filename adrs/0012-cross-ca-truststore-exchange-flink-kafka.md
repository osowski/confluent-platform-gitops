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

This ADR records the spike (Issue #395): a second, independent
`ClusterIssuer` (`foreign-ca-issuer`) issued a disposable client
certificate (`foreign-mtls-client`), pointed at the existing
`flink-sql-mtls` listener without modifying it, to reproduce both trust
directions and observe the actual failure modes. All spike resources were
disposable and have been deleted; the live `secure-sql` tenant was never
touched.

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

### 4. CFK's custom-listener TLS has no multi-CA trust field

`kubectl explain kafka.spec.listeners.custom.tls` exposes only
`secretRef` (+ `jksPassword`, `ignoreTrustStoreConfig`,
`directoryPathInContainer`) — no `trustStoreRef` or equivalent for a
second, independent trust anchor. CFK builds the listener's broker-side
truststore as a PKCS12 file
(`/mnt/sslcerts/truststore.p12`, confirmed live via
`kafka-configs --describe --all` on `flink-sql-mtls`) from whatever is in
the `ca.crt` key of the `Certificate`'s cert-manager-managed Secret. To
trust a second CA, that `ca.crt` key needs **both** root certificates'
PEM content concatenated before CFK's init-container builds the
PKCS12 truststore — there is no CRD-level "add another trusted CA"
mechanism.

Applying that fix requires a full broker restart (truststore.p12 is only
rebuilt at pod start), which on a shared demo cluster would affect every
listener and tenant on that broker — including the working `secure-sql`
tenant. Per Issue #395's explicit scope boundary, this spike did not
execute that restart; it is recorded here as the concrete next step
rather than performed live.

## Consequences

- **For customers hitting this today:** if a Flink-to-Kafka mTLS
  connection fails with `Failed to process post-handshake messages, SNI
  host name: empty` (or any post-handshake `SslAuthenticationException`
  that isn't a `PKIX path building failed`), the first thing to check is
  the **client-trust direction** — does the broker's listener truststore
  actually contain the CA that signed the Flink client's certificate? —
  because the broker's own logs will not tell you.
- **Documentation gap, confirmed:** `docs-cp-flink/configure/catalog.rst`
  should gain an SSL/mTLS `connectionConfig` example
  (`ssl.truststore.location`, `ssl.truststore.type`, PEM vs. JKS vs.
  PKCS12) alongside the existing `SASL_PLAINTEXT` example, plus an
  explicit note on the two independent trust directions and the
  cross-CA case. Filed as a documentation follow-up (see Issue #395).
- **For a real cross-CA merge in this repo:** the pattern is to bundle
  both roots' PEM into the target `Certificate`'s Secret's `ca.crt`
  before CFK provisions the broker (e.g., via a `trust-manager` `Bundle`
  feeding a combined CA list into that Secret, or a custom cert-manager
  `Certificate` chain), accepting that it forces a broker restart. This
  is a heavier, more disruptive change than anything else delivered
  under Epic #377 and should be scoped as its own task if a real
  multi-CA customer scenario needs to be reproduced end-to-end.
- Spike resources (`foreign-ca`, `foreign-ca-issuer`, `foreign-mtls-client`,
  and the temporary broker-logger DEBUG overrides) were deleted/reverted
  after the finding was recorded, per Issue #395. No permanent GitOps
  changes resulted from this spike.

## References

- Issue #395 (spike)
- Epic #377
- ADR-0011 (secure-sql mTLS credential delivery — the foundation this
  spike builds on)
