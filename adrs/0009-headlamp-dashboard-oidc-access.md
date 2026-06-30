# 9. Headlamp Kubernetes Dashboard: Deployment and Authentication

Date: 2026-06-30

## Status

Accepted

## Context

Issue [#148](https://github.com/osowski/confluent-platform-gitops/issues/148) adds an in-cluster Kubernetes dashboard to all clusters. Headlamp was selected over the upstream Kubernetes Dashboard for its lighter footprint, React-based extensibility, and active maintenance.

Two questions had to be settled: how Headlamp is deployed/exposed, and how users authenticate. The clusters fall into two groups — three run Keycloak (`flink-demo-rbac`, `flink-demo-rbac-mtls`, `eks-demo`) and one does not (`flink-demo`) — so Keycloak OIDC SSO was initially attractive for the Keycloak clusters.

## Decision

### 1. Headlamp as the default in-cluster dashboard for all clusters

Headlamp is deployed as a Helm-based infrastructure ArgoCD Application (`headlamp` chart 0.43.0, namespace `headlamp`), sync-wave 50. The Traefik IngressRoute and cert-manager Certificate live in the centralized ingresses Application at sync-wave 80 (so Traefik and cert-manager are ready first). It is exposed at `headlamp.<cluster>.<domain>` with a cluster-specific cert, and is added to `scripts/new-cluster.sh` so every new cluster gets it by default.

The chart creates a `cluster-admin`-bound ServiceAccount for Headlamp.

### 2. Token-based authentication on all clusters

All clusters — including the three Keycloak clusters — use Headlamp's **token login**: the user pastes a Kubernetes bearer token, and Headlamp uses that token's identity for every API call. Access is gated by possession of a valid token, and the user's own RBAC applies.

No per-cluster Helm overlay is required; the base values are token-only. (The Application manifests still reference an optional `overlays/<cluster>/values.yaml` via `ignoreMissingValueFiles: true`, leaving room for future per-cluster configuration.)

### 3. Rejected: Keycloak built-in OIDC + `unsafeUseServiceAccountToken`

The first implementation configured the three Keycloak clusters with Headlamp's built-in OIDC (`config.oidc.*`) plus `config.unsafeUseServiceAccountToken: true`, on the assumption that OIDC would gate UI login while the cluster-admin ServiceAccount performed API calls.

**This does not gate access and was rejected on security grounds.** Verified empirically: with `unsafeUseServiceAccountToken` set, Headlamp's backend uses the pod's cluster-admin ServiceAccount for **every** request regardless of authentication state. Unauthenticated requests to the Headlamp API (no token, no session cookie) returned HTTP 200 with live data — e.g. `GET /clusters/main/api/v1/secrets` returned cluster Secrets. Headlamp's OIDC button only affects the frontend; hitting the API path directly bypasses it. The chart's own documentation states this flag "disables per-user authentication and is only safe behind an auth proxy."

Exposed at `headlamp.<cluster>.<domain>`, that configuration would have granted **unauthenticated cluster-admin** (including read of all Secrets) to anyone able to reach the URL.

This decision also removes the machinery that approach required: per-cluster OIDC Helm overlays, a `headlamp` Keycloak client (base + eks-demo realms) and its realm-sync-job secret update, reflection of `keycloak-tls` into the `headlamp` namespace, and the in-cluster issuer-reachability workaround (a non-GitOps CoreDNS rewrite / `hostAliases`). It also eliminates an infra→workload ordering dependency (the OIDC pod blocking on a Keycloak-tier secret).

### 4. Keycloak SSO deferred to a future auth-proxy design

Genuine Keycloak SSO will be reintroduced by placing a real authentication gate **in front of** Headlamp — `oauth2-proxy` performing the OIDC flow, enforced via a Traefik `forwardAuth` middleware — with Headlamp keeping `unsafeUseServiceAccountToken` behind the proxy. That is the topology the flag is designed for. It is tracked as a separate follow-up rather than blocking the dashboard rollout.

## Consequences

**Positive:**

- All clusters get a consistent dashboard with no open-access hole; access requires a valid Kubernetes token, and the token's own RBAC applies (no blanket cluster-admin for every visitor).
- Removing the OIDC overlays, Keycloak client, cert reflection, and CoreDNS step makes the feature fully GitOps-managed with no manual bootstrap steps.

**Negative / constraints:**

- No single sign-on yet on the Keycloak clusters; users must supply a token (e.g. `kubectl -n headlamp create token <sa>`) until the auth-proxy follow-up lands.
- The chart-created ServiceAccount remains `cluster-admin`; a user who obtains that SA's token gets cluster-admin. A read-only default ClusterRole would be a safer baseline and should be considered in the SSO follow-up.

## Related

- [#148](https://github.com/osowski/confluent-platform-gitops/issues/148)
- `infrastructure/headlamp/` (base manifests; per-cluster overlays optional)
- [ADR-0002](0002-cfk-component-sync-wave-ordering.md) — sync-wave ordering conventions
- [docs/architecture.md](../docs/architecture.md) — infrastructure application deployment model
