# 22. CMF 2.5: Flink 2.3 SQL Pools, One Shared Compiler, Compile Workers Only on flink-demo

Date: 2026-11-13

## Status

Accepted.

## Context

CMF 2.5.0 runs Flink SQL statements on Flink 1.19 or Flink 2.3. A compute pool picks the version with `clusterSpec.flinkVersion` and a matching `cp-flink-sql` image. A statement can't move between pools, and CMF rejects a `flinkVersion` change while a pool has resumable statements (`docs-cp-flink/jobs/sql-statements/flink-versions.rst`).

CMF 2.5 compiles statements outside the `cmf` container (`docs-cp-flink/installation/sql-compilers.rst`):

- **Shared compilers** are containers in the CMF pod, one per Flink line. The chart default is a 1.19 and a 2.3 compiler, each with a 2Gi memory request and limit.
- **Compile workers** are a separate pod (3Gi by default). With `cmf.artifacts.enabled` and `cmf.sql.environmentCatalog.enabled`, both on in this repo, the chart adds one worker by default. Statements in environments that have artifacts compile only on the workers.
- CMF and the workers authenticate with TLS client certificates. The chart generates them and keeps them stable with Helm `lookup`. Argo CD renders with `helm template`, where `lookup` returns nothing, so every render would issue a new CA and restart CMF and the workers. The supported fix is to pre-create the Secrets and set `workers.tls.existingSecretPrefix`.

Most statements here don't use CMF artifacts: their JARs are `local://`. The exceptions are the colors-and-shapes UDF demo and UDF testing on flink-demo, which use `USING JAR 'cmf://...'`. CMF 2.5 compiles those only on a compile worker: "only workers load artifacts, and such a statement fails when a shared compiler or the cmf container compiles it" (chart 2.5.0 `values.yaml`, `statementService.workers`). The demo clusters are memory- and CPU-constrained (flink-demo runs on one kind VM).

## Decision

- **Every compute pool runs Flink 2.3** (`flinkVersion: v2_3`, `cp-flink-sql:2.3-cmf2.5-cp1`). The clusters move by teardown and bringup, not live migration.
- **Pools use the Flink 2.x config keys.** Flink 2.3's state backend loader accepts only `hashmap`, `rocksdb` and `forst`, so the 1.19-era `state.backend: filesystem` fails. Pools set `state.backend.type: hashmap` and the `execution.checkpointing.*` keys.
- **CMF runs one shared compiler, for Flink 2.3**, with `-Xmx1g` and a 1536Mi memory request and limit. The heap plus about 512Mi of JVM overhead has to fit the limit, or an OOMKill takes the CMF API down with it.
- **No compile workers by default** (`cmf.statementService.workers.count: 0` in the base values). Where nothing loads artifacts, a worker only adds memory and a second TLS identity.
- **flink-demo runs one compile worker** (`workers.count: 1`, `workers.tls.existingSecretPrefix: cmf-compile-certs`), so `cmf://` UDFs work there. The `cmf-compile-tls` Application (sync wave 117, before `cmf-operator`) runs a Job that creates `cmf-compile-certs-cmf` and `cmf-compile-certs-worker` once and keeps them on later syncs. The chart then renders without generated certificates, so syncs don't restart CMF. The worker needs no `extraEnv`: flink-demo's catalogs are plaintext, and the worker gets artifact JARs from CMF.

## Consequences

**Positive:**

- The CMF pod grows by 1.5Gi rather than about 4Gi (two 2Gi compilers). On flink-demo, the worker pod adds 3Gi.
- The chart generates no compile TLS Secrets, so CMF's pod template renders identically on every sync and Argo CD doesn't restart it.
- Flink 2.3-only SQL features (process table functions, batch statements, topic-subject associations, newer built-in functions) work on every pool.

**Negative / constraints:**

- A pool on any Flink line other than 2.3 can't compile its statements. Adding a 1.19 pool means adding a 1.19 entry to `sharedCompilers`.
- On clusters other than flink-demo, a statement that uses a CMF artifact (a UDF or connector loaded with `cmf://`) fails to compile. Enabling artifacts there means copying flink-demo's worker values and the `cmf-compile-tls` Application. Workers on clusters with authenticated catalogs also need their own copies of the catalog credentials and volumes (`workers.extraEnv`, `workers.mountedVolumes`).
- Raising `workers.count` also means raising `WORKER_COUNT` in the keygen Job, which then reissues both Secrets. CMF and the worker must be restarted to load them.
- Statements on 2.3 start without the state of their 1.19 predecessors.
