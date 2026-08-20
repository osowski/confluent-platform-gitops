# 10. Adopt CFK 3.3 Flink SQL CRDs While They Are a Preview Feature

Date: 2026-08-07

## Status

Accepted

## Context

CMF's Flink SQL object model — secrets, secret mappings, catalogs, databases, compute pools and statements — had no declarative Kubernetes representation before CFK 3.3.0. This repository drove it through the CMF REST API from ArgoCD hook Jobs: two `sql-init` Jobs on `flink-resources-rbac` (now folded into `colors-and-shapes`) running seven `curl` steps each, plus two more on `cp-flink-sql-sandbox` (now folded into `flink-resources`). Roughly 1,400 lines of shell and JSON-in-ConfigMap.

That approach had costs beyond its size:

- **Invisible to ArgoCD.** The Jobs were fire-and-forget. ArgoCD could not diff, prune, or report the state of anything they created, so the CMF-side objects were untracked drift by construction.
- **No upsert.** The CMF API has none, so every step carried a create-then-update fallback, with a `409` treated as success and `PUT` failures swallowed as warnings.
- **A token refresh loop.** CMF 2.2's embedded Schema Registry client rejected `OAUTHBEARER` as a `bearer.auth.credentials.source`. The Jobs worked around this by minting a Keycloak access token at runtime and embedding it in each catalog as a `STATIC_TOKEN`. That token expires, which is the reason the Jobs had to re-run on every sync — the imperative machinery existed largely to service its own workaround.

CFK 3.3.0 (chart `0.1718.10`) introduced six CRDs covering the whole model: `FlinkSecret`, `FlinkEnvironmentSecretMapping`, `FlinkKafkaCatalog`, `FlinkKafkaDatabase`, `FlinkComputePool` and `FlinkStatement`. Separately, CMF 2.3.1 added `OAUTHBEARER` support for Schema Registry catalog authentication with automatic token refresh, removing the reason the `STATIC_TOKEN` workaround existed. This repository runs CMF 2.4.0.

The complication: Confluent documents Flink SQL support in CFK 3.3.0 as a **preview feature**, with the explicit guidance *"Do not use preview features in production."* The CRDs are also gated behind two Helm flags (`enableCMFDay2Ops`, `enableFlinkSQL`), the second of which defaults to `false`.

## Decision

Adopt the CFK 3.3 Flink SQL CRDs across this repository's clusters, and delete the hook Jobs they replace.

The preview designation is accepted rather than worked around. This repository exists to demonstrate and exercise Confluent Platform on Kubernetes; every cluster in it is a demo or reference environment, none carries production traffic or an availability commitment, and exercising new operator capability ahead of GA is part of its purpose. Weighed against that, the imperative Jobs were the larger practical risk: untracked, unpruneable, and dependent on a credential-refresh loop.

Supporting decisions taken alongside it:

- **Enable both feature gates** (`enableCMFDay2Ops`, `enableFlinkSQL`) in the CFK operator base values, and whitelist the six kinds in the `workloads` ArgoCD `AppProject`.
- **Gate the chain on health.** Add Lua health checks in `argocd-cm` for every CMF-backed Flink kind. Without them ArgoCD treats an unknown custom resource as Healthy the instant it is created, which both hides failures and makes the dependency-chain sync waves decorative.
- **Enable CMF secret encryption**, which `FlinkSecret` requires.
- **Keep the credential split** the previous ConfigMaps documented: Kafka connections use the `cmf` service account, Schema Registry uses the per-group `sa-<group>-flink` account.

## Consequences

**Positive.** ~1,400 lines of shell and JSON become ~24 custom resources. CMF-side objects are visible, diffable and prunable in ArgoCD. Credentials are declarative and rotate by editing a Kubernetes Secret, with CFK tracking its `resourceVersion`. The `STATIC_TOKEN` refresh loop and its expiry failure mode are gone. Sync waves genuinely order the dependency chain now that health is evaluated.

**Negative — preview risk.** The API may change incompatibly before GA, and CFK upgrades must be treated as potentially breaking for these kinds. Rollback means reinstating the hook Jobs from git history; they are removed from the tree but not from history, and the CMF REST API they used is unchanged.

**Negative — undocumented behaviour is discovered by running it.** Several constraints are not in the CFK documentation and were found only against a live cluster. They are recorded in [architecture.md](../docs/architecture.md); the load-bearing ones:

- The `FlinkSecret`, its `FlinkEnvironmentSecretMapping`, and the `connectionSecretId` that references them must all share one identical name. The docs state only the mapping half of the rule.
- CFK does not refresh `FlinkStatement.status.phase` once a statement starts running — a healthy statement reads `PENDING` indefinitely — so health checks must not gate on `RUNNING`.
- `FlinkComputePool.status.phase` carries the pool *type*, not a lifecycle state.
- `FlinkKafkaCatalog.status.environmentsWithAccess` is unset on correctly configured catalogs and cannot be used as a health signal.
- Renaming a `FlinkSecret` on a live cluster deadlocks against its own secret mapping.

**Neutral — version floor.** This commits the repository to CFK 3.3.0+ and CMF 2.3.0+ (2.4.0 in practice), and to a `cp-flink-sql` image matching the CMF version. Downgrading below those floors is no longer possible without reverting the whole approach.

## References

- Epic [#318](https://github.com/osowski/confluent-platform-gitops/issues/318) and its children [#319](https://github.com/osowski/confluent-platform-gitops/issues/319)–[#326](https://github.com/osowski/confluent-platform-gitops/issues/326)
- [Manage Apache Flink SQL Statements Using Confluent for Kubernetes](https://docs.confluent.io/operator/current/co-manage-flink-sql.html)
- [Manage Global Apache Flink Resources Using Confluent for Kubernetes](https://docs.confluent.io/operator/current/co-flink-global-resources.html)
- [ADR-0008](0008-flink-sql-statement-config-placement-rbac.md) — which configuration layer owns a given Flink SQL setting
