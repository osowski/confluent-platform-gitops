# 9. Headlamp Kubernetes Dashboard: Deployment Model and OIDC Access

Date: 2026-06-30

## Status

Accepted

## Context

Issue [#148](https://github.com/osowski/confluent-platform-gitops/issues/148) adds an in-cluster Kubernetes dashboard to all clusters. The options considered were Kubernetes Dashboard (the upstream project) and Headlamp. Headlamp was selected for its native OIDC support, React-based extensibility, and active maintenance cadence.

Three questions arose during implementation:

1. **How is Headlamp deployed and exposed?** — as a Helm chart via ArgoCD, consistent with all other infrastructure apps.
2. **Who performs Kubernetes API authorization after login?** — Headlamp's own ServiceAccount or the end-user's OIDC identity mapped through the kube-apiserver.
3. **How does Headlamp's pod reach the external Keycloak OIDC issuer on self-signed kind clusters?** — go-oidc (used by Headlamp) strictly validates that the `issuer` in the discovery document matches the configured URL; it cannot be disabled.

## Decision

### 1. Headlamp as the default in-cluster dashboard for all clusters

Headlamp is deployed as a Helm-based infrastructure ArgoCD Application (`headlamp` chart 0.43.0, namespace `headlamp`). The Application manifest carries sync-wave 50 (alongside other infrastructure services); the Traefik IngressRoute and cert-manager Certificate are in a separate Application at sync-wave 80 to ensure Traefik and cert-manager are ready first.

Headlamp is exposed at `headlamp.<cluster>.<domain>` via Traefik IngressRoute with a cluster-specific TLS certificate issued by cert-manager.

The `headlamp` infrastructure Application is added to `scripts/new-cluster.sh` so every new cluster gets it by default.

### 2. Authorization model: OIDC gates login; cluster ServiceAccount performs API calls

`config.unsafeUseServiceAccountToken: true` is set in all clusters. After a user authenticates (via OIDC or a bearer token), all Kubernetes API calls are made using Headlamp's own `cluster-admin`-bound ServiceAccount token, not the user's OIDC identity.

This means **every authenticated user has effective cluster-admin access**. This is acceptable for these demo clusters and avoids the alternative: configuring the kube-apiserver `--oidc-*` flags and per-group RBAC bindings, which would require cluster-wide API-server reconfiguration and is explicitly out of scope for the demo environments.

For production use, the ServiceAccount token approach must be replaced with end-user OIDC passthrough. The client secret should be provisioned via `config.oidc.externalSecret` (referencing an ExternalSecret) rather than an inline value.

### 3. Per-cluster auth matrix

| Cluster | Auth method |
|---|---|
| flink-demo | Token login only (no OIDC; no Keycloak) |
| flink-demo-rbac | Keycloak OIDC SSO |
| flink-demo-rbac-mtls | Keycloak OIDC SSO |
| eks-demo | Keycloak OIDC SSO |
| New clusters (script default) | Token login only |

### 4. In-cluster OIDC issuer reachability for self-signed kind clusters

On `flink-demo-rbac` and `flink-demo-rbac-mtls`, Keycloak is exposed at an external hostname (`keycloak.<cluster>.<domain>`) with a self-signed certificate issued by a cluster-local `selfsigned-cluster-issuer`. Headlamp's go-oidc library performs strict issuer URL comparison — the `issuer` in Keycloak's discovery document must exactly match the configured issuer URL — and provides no TLS-skip flag.

Two mechanisms are combined to make Headlamp's pod reach Keycloak:

**a. Certificate trust:** The `keycloak-tls` Secret (created by cert-manager in the `keycloak` namespace) is reflected into the `headlamp` namespace via Reflector. Headlamp's Deployment mounts this cert and sets `SSL_CERT_FILE` so go-oidc trusts it.

**b. DNS resolution:** A CoreDNS rewrite rule is added so `keycloak.<cluster>.<domain>` resolves to the in-cluster Traefik ClusterIP. This preserves the exact external hostname (and therefore the `Host` header / SNI), keeping the issuer claim consistent. The rewrite is a one-time bootstrap step applied via `kubectl` — it cannot be expressed purely in GitOps because the CoreDNS ConfigMap is managed by kind and patching it via ArgoCD would conflict. The exact command is documented in each cluster's README.

`eks-demo` requires neither mechanism: it uses real DNS and a Let's Encrypt certificate.

The `selfsigned-cluster-issuer` is a pure `SelfSigned` issuer and does not produce a shared CA certificate, ruling out a simpler CA-bundle injection approach.

## Consequences

**Positive:**

- All clusters get a consistent, OIDC-capable dashboard with minimal per-cluster configuration.
- The per-cluster auth matrix is explicit and auditable in Git.
- The ServiceAccount token model is simple to reason about for demo environments.
- The certificate reflection + CoreDNS approach avoids TLS errors without patching Headlamp itself.

**Negative / constraints:**

- `unsafeUseServiceAccountToken: true` grants every authenticated user cluster-admin. This is a deliberate demo tradeoff and must not be carried forward to production clusters.
- The CoreDNS rewrite is a documented manual bootstrap step (not GitOps-managed). Any cluster rebuild requires re-applying it; this is noted in each cluster's README.
- The reflected `keycloak-tls` Secret must be re-reflected after cert-manager renews the Keycloak certificate. Reflector handles this automatically if configured, but the annotation must be present on the source Secret.
- Headlamp chart upgrades must be verified against the `config.oidc` and `config.unsafeUseServiceAccountToken` API surface; breaking changes in the values schema would require overlay updates across all Keycloak clusters.

## Related

- [#148](https://github.com/osowski/confluent-platform-gitops/issues/148)
- `infrastructure/headlamp/` (base manifests and per-cluster overlays)
- `clusters/flink-demo-rbac/README.md` and `clusters/flink-demo-rbac-mtls/README.md` (CoreDNS rewrite commands)
- [ADR-0002](0002-cfk-component-sync-wave-ordering.md) — sync-wave ordering conventions
- [docs/architecture.md](../docs/architecture.md) — infrastructure application deployment model
