# 26. CMF AI Functions Set Up in the Applications That Own the Environments

Date: 2026-11-20

## Status

Accepted. Tracked in [#575](https://github.com/osowski/confluent-platform-gitops/issues/575).

## Context

`AI_FORECAST` and `AI_DETECT_ANOMALIES` are CMF preview functions. A Flink environment can run them once three things are in place:

- the function JAR is uploaded as an artifact in that environment;
- both functions are registered in the environment's catalog (`_env_<env>`) with `CREATE FUNCTION ... USING JAR 'cmf://<env>/ai-functions.jar'`;
- the environment's statement defaults carry `ai.models.<model>.endpoint` for each model server.

The standard environments are `default` (owned by `flink-resources`), and `colors-env` and `shapes-env` (owned by `colors-and-shapes`). Facts that shape the decision:

- CFK has no CRD for artifacts. Upload is `POST /cmf/api/v1/environments/<env>/artifacts` only, and a second upload under the same name fails.
- The `FlinkEnvironment` CRD has `spec.statementDefaults`, but CFK does not send it to CMF when it creates an environment. Verified live: an environment created from a CR carrying the field has no statement defaults in CMF.
- CMF has no PUT for environments. `POST /cmf/api/v1/environments` is createOrUpdate, and an update replaces every default it omits (`flinkApplicationDefaults`, `computePoolDefaults`, statement defaults).
- A DDL-only `FlinkStatement` settles to COMPLETED, a re-apply of an unchanged one is a no-op, and deleting and recreating it works. Verified live on `kind-flink-demo`.
- No workload here references another workload's Kustomize files, and each Application has to stay syncable alone.

## Decision

- **Each Application sets up the environments it owns.** `flink-resources` sets up `default`. The same Job and script are meant for `colors-and-shapes` to set up its own two environments; that is later work and is not part of `flink-resources`. A cluster without `colors-and-shapes` is unaffected.
- **The `ttm` model server is deployed by the same `flink-resources` Application** (wave 90), as Service `model-server-ttm` at `http://model-server-ttm.flink.svc.cluster.local:8080/v1/forecast`. That is the URL the setup Job writes into the environment.
- **Statement defaults are written by the setup Job through the CMF API**, not by the `FlinkEnvironment` CR. The CR carries no `statementDefaults`. The Job reads the environment, sets only the `ai.models.*` keys in the `interactive` and `detached` blocks, and posts the whole environment back through createOrUpdate, leaving every other default as read. It skips the post when the keys already hold the target values.
- **Artifact upload is an idempotent Argo CD hook Job** (`Sync`, `BeforeHookCreation`, wave 52 in `flink-resources`, with a 30-minute `activeDeadlineSeconds`). It waits for CFK to create the environment in CMF, checks whether `ai-functions.jar` exists, and only otherwise downloads the JAR, verifies its pinned sha256 and uploads it. The pinned `python:3.12-alpine` image runs a standard-library-only script from a ConfigMap generated from `ai_functions_setup.py`. The Job runs in the `flink` namespace on every cluster. On the three OAuth clusters a component patch adds a client-credentials token fetch from the `cfk-cmf-oauth-client` Secret.
- **`CREATE FUNCTION` stays a `FlinkStatement`.** `create-ai-forecast` and `create-ai-detect-anomalies` (wave 55, after the compute pool and the setup Job) use `IF NOT EXISTS`. The live gate on the fallback conditions passed, so no statement-submitting code goes in the Job.
- **The script is to be duplicated between the two Applications.** Each Application carries its own copy so it can sync alone.

## Alternatives Considered

- **All AI setup in `flink-resources`.** One copy of the script, but it would target environments owned by an Application that syncs later, and it breaks on a cluster without `colors-and-shapes`.
- **A new `ai-functions` Application.** Model servers and function setup belong with the environments and servers they extend.
- **`statementDefaults` on the `FlinkEnvironment` CR.** Declarative and the first choice, but CFK does not send it to CMF at creation, so it has no effect.
- **A blind environment update carrying only the AI keys.** Rejected: the update replaces `flinkApplicationDefaults`, including the Prometheus reporter and Schema Registry OAuth settings.
- **`CREATE FUNCTION` inside the Job.** The fallback; not needed.

## Consequences

- **The setup runs on Argo CD sync and does not repair itself.** If CMF loses its state, the artifact, functions and defaults are not restored until the cluster is rebuilt from zero.
- **A change to either `CREATE FUNCTION` statement is a new CR with a versioned name,** because `spec.statement` is immutable once running. With `IF NOT EXISTS` a new CR is a no-op while the function is still registered, so a changed class or JAR also needs a `DROP FUNCTION` first.
- **The JAR is pinned.** Moving to a later JAR needs a new URL and checksum, a new artifact version, and a re-registration; it is not handled automatically.
- **On the RBAC clusters the Job's principal is `cmf`.** According to the Confluent access-control role table ([access-control](https://docs.confluent.io/cp-flink/current/configure/access-control.html)), the `cmf` principal's `ClusterAdmin` binding on `default` covers artifacts and statements.
- **The Job runs after the compute pool and before the `CREATE FUNCTION` statements.** The environment (wave 5) comes first and the pool (50) needs neither the statement defaults nor the artifact, so a failed or stuck Job cannot block the base SQL demo: topics, schemas, catalog, database and pool sync before it. The statements (55) need the artifact, so they follow the Job. `activeDeadlineSeconds: 1800` bounds the Job.
- **A CFK reconcile of the `default` FlinkEnvironment CR clears the statement defaults.** A spec change to the CR makes CFK post the environment to CMF without `statementDefaults`, which empties the `ai.models.*` keys (verified live: after a CR edit, CMF reported `statementDefaults` as null for both `interactive` and `detached`). Restarting the CFK operator alone does not trigger a reconcile. Until the next Argo CD sync, new statements that call a model fail with `has no model server URL in this environment`; the sync's Job restores the keys (verified live). A hand edit of the CR therefore needs a sync afterwards.
- **Deleting the `default` FlinkEnvironment CR needs the functions dropped and the artifact deleted first.** CMF refuses to delete an environment that still holds an artifact (`Environment '<env>' cannot be deleted because it has 1 artifact ('ai-functions.jar') that must be deleted first.`) or a registered function (`... it has 2 functions ('ai_detect_anomalies', 'ai_forecast') in the default catalog database that must be deleted first.`). The CR stays in CFK state `ERROR` with its finalizer until `DELETE /cmf/api/v1/environments/<env>/artifacts/<name>` removes the artifact and a `DROP FUNCTION` statement removes each function. Deleting the `CREATE FUNCTION` statement CRs does not drop the functions, and a `DROP FUNCTION` needs a compute pool, so the drop must run before the Application's resources are deleted: the pool (wave 50) is deleted before the environment (wave 5). The README's teardown section has the steps. Verified live.
- **Once both Applications carry the script, there are two copies to keep in step.**
