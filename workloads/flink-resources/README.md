# Flink Resources

Core Confluent for Kubernetes (CFK) / Confluent Manager for Apache Flink (CMF)
integration, plus a generic, single-tenant Flink SQL demo. Deployed
uniformly on all four clusters (`flink-demo`, `flink-demo-rbac`,
`flink-demo-rbac-mtls`, `eks-demo`) — auth mode is the only per-cluster
difference.

## Deployment Modes

`base/` is the anonymous variant, used as-is on `flink-demo`. On
`flink-demo-rbac`, `flink-demo-rbac-mtls`, and `eks-demo`, the
`components/oauth` Kustomize Component layers on:

- OAuth authentication on the `CMFRestClass` (CFK-operator-to-CMF, via
  `cfk-cmf-oauth-client` — operator-level, not end-user)
- A new OAuth-secured credential chain for the `default` environment's Kafka
  SQL catalog/database, since these clusters have no anonymous Kafka/SR
  listener unlike `flink-demo`. Uses the `cmf` service account for both the
  Kafka and Schema Registry connections — `default` has no dedicated
  per-tenant identity the way `colors-and-shapes`' `shapes`/`colors` tenants
  do (see that workload's README).

This is the **only** owner of `cmf-rest-class` in the `flink` namespace on
every cluster — `colors-and-shapes` only ever references it via
`cmfRestClassRef`, never defines its own copy.

## Who Can Write to the `default` Environment (RBAC clusters)

CMF delegates authorization to MDS via `ConfluentRolebinding`, scoped per
FlinkEnvironment through `clustersScopeByIds.flinkEnvironmentId`. Unlike
`colors-and-shapes`' `shapes`/`colors` tenants (which grant their own groups
`DeveloperManage`/`ClusterAdmin` on `shapes-env`/`colors-env`), `default` has
no dedicated tenant group — only `cmf` (the CFK operator's own identity) and
`admin@osow.ski`/`admin@dspdemos.com` hold a `ClusterAdmin` binding scoped to
it (`cmf-clusteradmin-default`, `admin-clusteradmin-default` in each RBAC
cluster's `confluent-resources` overlay, e.g.
[`confluentrolebindings.yaml`](../confluent-resources/overlays/flink-demo-rbac/confluentrolebindings.yaml)
on `flink-demo-rbac`).

**Practical effect:** on `flink-demo-rbac`, `flink-demo-rbac-mtls`, and
`eks-demo`, only the `admin` user (logged into CMF UI/API via SSO) can
create or update FlinkApplications/statements in `default` — any other
authenticated user gets a 401, even with a valid token, because no
`ConfluentRolebinding` grants them access to this environment. A cluster-wide
`SystemAdmin` binding scoped only by `cmfId` (no `flinkEnvironmentId`) does
**not** substitute for this — CMF requires the environment-scoped grant in
practice, confirmed by direct REST API testing during #349.

## What's Included

- **CMFRestClass** (`cmf-rest-class`) — the CFK-operator-to-CMF communication
  bridge.
- **FlinkEnvironment** (`default`) — the single environment for both native
  `FlinkApplication`s and Flink SQL (Compute Pools/Statements). Replaces the
  earlier `env1`/`default-flink-env` split.
- **Reference FlinkApplication** (`default-flink-app`) — an optional
  `StateMachineExample` JAR job demonstrating native Kubernetes deployment
  against the `default` environment. Not required for Flink SQL usage.
- **Generic Flink SQL demo** for the [cp-flink-sql](https://github.com/rjmfernandes/cp-flink-sql)
  repository — `myevent`/`myaggregated` topics and Avro schemas, a
  `FlinkKafkaCatalog` (`kafka-cat`) bound to Schema Registry, a
  `FlinkKafkaDatabase` (`main-kafka-cluster`) bound to the Kafka cluster, and a
  `FlinkComputePool` (`pool`, DEDICATED) with S3 checkpoint/savepoint storage.
- **Model server** (`model-server-ttm`) — serves the `ttm` time series model
  that the `AI_FORECAST` and `AI_DETECT_ANOMALIES` functions call, at
  `http://model-server-ttm.flink.svc.cluster.local:8080/v1/forecast`. It is a
  one-replica Deployment with a Service, a NetworkPolicy and a 5Gi PVC
  (`model-server-ttm-cache`) that keeps the Hugging Face download across pod
  restarts. The PVC uses the cluster's default storage class (`gp3` is set
  explicitly on eks-demo; `standard` on kind). A startup probe on `/readyz`
  allows up to 10 minutes for the model download and load and restarts the
  container if it has not become ready within that window; after it passes,
  readiness (`/readyz`) and liveness (`/livez`) probes take over (every probe
  allows 5 seconds per check), and the Deployment's
  progress deadline is 20 minutes. The NetworkPolicy admits only pods labeled
  `type: flink-native-kubernetes` from the `flink`, `flink-colors` and
  `flink-shapes` namespaces, and takes effect only where the cluster's CNI
  enforces NetworkPolicy. All four resources sit in sync wave 90, after every
  other resource in this
  Application, so a slow model download never holds up the Flink SQL chain.
- **AI functions** (`base/ai-functions/`) — `AI_FORECAST` and
  `AI_DETECT_ANOMALIES` ready to use in `default`; see
  [AI functions](#ai-functions-default-environment).

The Flink SQL resources are declarative CFK custom resources (CFK 3.3.0+),
not imperative CMF API calls. They form a dependency chain that must be
applied in order and deleted in reverse; sync waves 5/10/30/35/40/45/50/52/55
enforce both directions (the model server's wave 90 sits after the chain,
outside it; RBAC clusters additionally use waves 10/20/30 for
the `default`-env Secret/FlinkSecret/mapping chain, alongside the reference
`FlinkApplication` at wave 10 — the two don't depend on each other, so
sharing a wave number is harmless). See
[architecture.md](../../docs/architecture.md#intra-application-sync-waves-flink-sql-resources)
for the constraints that apply to the whole chain.

## AI functions (`default` environment)

`AI_FORECAST` and `AI_DETECT_ANOMALIES` work in the `default` environment with
no manual steps, once the `ttm` model server (deployed by this Application, see
above) is Ready. Three pieces make the functions usable:

| Wave | Resource | What it does |
|---|---|---|
| 52 | Job `ai-functions-setup-default` (Sync hook, after the compute pool) | Waits for CMF to have the `default` environment, writes `ai.models.ttm.endpoint` into its `interactive` and `detached` statement defaults, and uploads the function JAR as artifact `ai-functions.jar` unless it exists; an existing artifact must be `READY` with the pinned sha256 |
| 55 | FlinkStatement `create-ai-forecast` | `CREATE FUNCTION IF NOT EXISTS AI_FORECAST ... USING JAR 'cmf://default/ai-functions.jar'` |
| 55 | FlinkStatement `create-ai-detect-anomalies` | The same for `AI_DETECT_ANOMALIES` |

The Job writes the statement defaults instead of the `FlinkEnvironment` CR
because CFK does not send `statementDefaults` to CMF, on create or on any later
edit. CMF's environment update replaces every default it omits, so the Job reads
the environment first and changes only the `ai.models.*` keys.

For setting up and calling the functions, see the Confluent documentation
([set up AI functions](https://docs.confluent.io/cp-flink/current/jobs/sql-statements/ai/set-up-ai-functions.html),
[forecast](https://docs.confluent.io/cp-flink/current/jobs/sql-statements/ai/forecast.html),
[detect anomalies](https://docs.confluent.io/cp-flink/current/jobs/sql-statements/ai/detect-anomalies.html)).
The design, failure behavior, exit codes and the teardown constraint are in
[ADR-0026](../../adrs/0026-cmf-ai-functions-in-owning-applications.md#consequences).

## Prerequisites

The following must be deployed before this application:
- Confluent for Kubernetes (CFK) operator
- Confluent Manager for Apache Flink (CMF) operator
- Kafka cluster with Schema Registry
- RustFS for object storage (deployed as infrastructure application)

## Getting Started (Flink SQL demo)

Once this application is synced in ArgoCD, you can proceed directly to the
"Let's Play" section of the
[cp-flink-sql repository](https://github.com/rjmfernandes/cp-flink-sql?tab=readme-ov-file#lets-play).

On `flink-demo`, access CMF via the Ingress endpoint (not port-forward):
`http://cmf.flink-demo.confluentdemo.local`.

## Reference

For detailed setup instructions and examples, see the parent repository:
https://github.com/rjmfernandes/cp-flink-sql
