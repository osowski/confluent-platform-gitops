# Colors UDF Demo

A minimal walkthrough of [User-Defined Functions in Confluent Manager for
Apache Flink](https://docs.confluent.io/cp-flink/current/jobs/sql-statements/user-defined-functions.html),
scoped to the `colors` tenant of [colors-and-shapes](../README.md) on
`flink-demo`. It registers a scalar UDF (`ToUpperCase`, straight from the
docs) and uses it to upper-case the `type`/`status` columns of the existing
`colors-input` messages, writing the result to the existing
`colors-sql-output` topic.

This directory is local tooling only — a Maven module you build and a
`README` with SQL to paste into the CMF UI. Nothing here is a Kubernetes
manifest, and nothing is applied through ArgoCD; the demo lives entirely
outside GitOps by design, submitted as ad-hoc statements through the CMF UI.

## Prerequisites

Already satisfied on `flink-demo` — no infrastructure changes needed:

- **Artifact management** is enabled cluster-wide
  (`workloads/cmf-operator/base/values.yaml`, `cmf.artifacts.enabled: true`,
  backed by the in-cluster MinIO).
- **Environment catalog** is enabled on this cluster
  (`workloads/cmf-operator/overlays/flink-demo/values.yaml`,
  `cmf.sql.environmentCatalog.enabled: true`).
- The `colors-and-shapes` Application is synced and healthy, so
  `colors-env`, `colors-pool`, `colors-catalog`/`colors-database`, and the
  `colors-input`/`colors-sql-output` topics already exist.
- The `colors-producer` Deployment has been scaled up at least once so
  `colors-input` has messages to read:
  ```bash
  kubectl -n flink-colors scale deploy/colors-producer --replicas=1
  ```

## 1. Build the function JAR

```bash
mvn package
```

This writes `target/udfs.jar`, containing `com.example.ToUpperCase`
(`src/main/java/com/example/ToUpperCase.java`) — the `ScalarFunction`
example from the docs, unmodified.

## 2. Upload the JAR as a CMF artifact

Artifacts are scoped to a CMF environment; `colors-env` is the environment
backing the `colors` tenant.

```bash
export CONFLUENT_CMF_URL=https://cmf.flink-demo.confluentdemo.local

# Extract the CA cert cert-manager generated for cmf-tls (same as the
# flink-demo README's CMF CLI section)
kubectl get secret cmf-tls --namespace operator -o jsonpath='{.data.ca\.crt}' \
  | base64 --decode > /tmp/cmf-ca.crt

cat > /tmp/artifact.json <<'EOF'
{
  "apiVersion": "cmf.confluent.io/v1",
  "kind": "Artifact",
  "metadata": { "name": "udfs.jar" },
  "spec": {}
}
EOF

curl --cacert /tmp/cmf-ca.crt -X POST \
  "$CONFLUENT_CMF_URL/cmf/api/v1/environments/colors-env/artifacts" \
  -F 'artifact=@/tmp/artifact.json;type=application/json' \
  -F 'file=@target/udfs.jar'
```

A successful upload returns HTTP 201 with `status.version: 1`. Re-running
the same `POST` after this point fails with 409 — use the `PUT` form
against `.../artifacts/udfs.jar` instead if you rebuild the jar and want to
upload a new version.

Verify it landed:

```bash
curl --cacert /tmp/cmf-ca.crt \
  "$CONFLUENT_CMF_URL/cmf/api/v1/environments/colors-env/artifacts/udfs.jar"
```

## 3. Register the function

Open the CMF UI at `https://cmf-ui.flink-demo.confluentdemo.local`, start a
new SQL statement against **environment `colors-env`**, **compute pool
`colors-pool`**, **catalog `_env_colors-env`**, **database `default`**, and
run:

```sql
CREATE FUNCTION IF NOT EXISTS to_upper
  AS 'com.example.ToUpperCase'
  USING JAR 'cmf://colors-env/udfs.jar';
```

This is metadata-only and completes immediately (`sqlKind:
CREATE_FUNCTION`). Confirm it registered:

```sql
SHOW USER FUNCTIONS;
```

## 4. Apply the UDF to colors-input

Start a **second** statement, same environment and compute pool, but this
time set **catalog `colors-catalog`**, **database `colors-database`** (the
Kafka catalog the `colors-input`/`colors-sql-output` topics live under —
functions registered in the environment catalog are callable from here the
same way a built-in function is). Run:

```sql
INSERT INTO `colors-sql-output`
(`timestamp`, `type`, `location`, `value`, `status`, `id`, `encoded`, `error`, `original`)
SELECT `timestamp`, to_upper(`type`) AS `type`, `location`, `value`,
  to_upper(`status`) AS `status`, `id`,
  CAST(NULL AS STRING) AS `encoded`, CAST(NULL AS STRING) AS `error`, CAST(NULL AS STRING) AS `original`
FROM `colors-input`
/*+ OPTIONS('properties.group.id' = 'colors-udf-demo') */;
```

Notes:

- The explicit column list matches the inferred `colors-sql-output` table
  and is required for the same reason as the existing `colors-sql-enrich`
  statement (see [colors-and-shapes README](../README.md)): an implicit
  `INSERT INTO` leaves the sink's leading raw `key` (BYTES) column NULL.
- `encoded`/`error`/`original` are set to `NULL` here — this statement
  doesn't populate them; that's `colors-sql-enrich`'s job. Both statements
  run independently against the same `colors-input` source and the same
  `colors-sql-output` sink, so consumers of `colors-sql-output` will see a
  mix of records from each: some with `type`/`status` upper-cased and
  `encoded` NULL (this statement), others with original-case
  `type`/`status` and `encoded` populated (`colors-sql-enrich`). That's
  expected — this demo isn't meant to replace `colors-sql-enrich`.
- `properties.group.id` is set to a name distinct from
  `colors-sql-enrich`'s so the two statements read `colors-input`
  independently rather than splitting its partitions between them.

## 5. Verify

Open Control Center (`https://controlcenter.flink-demo.confluentdemo.local`)
→ Topics → `colors-sql-output` → Messages, and browse records (Control
Center resolves the Avro schema from Schema Registry automatically). Look
for records with `type`/`status` in upper case, interleaved with
`colors-sql-enrich`'s original-case records.

## Cleanup

Delete the query statement from the CMF UI (Statements list → delete), then
drop the function:

```sql
DROP FUNCTION IF EXISTS to_upper;
```

Deleting the statement stops its job; it does not remove any records it
already wrote to `colors-sql-output`.

## Related

- [User-Defined Functions in CMF](https://docs.confluent.io/cp-flink/current/jobs/sql-statements/user-defined-functions.html)
- [Manage Environment Catalogs in CMF](https://docs.confluent.io/cp-flink/current/configure/environment-catalog.html)
- [Manage Artifacts in CMF](https://docs.confluent.io/cp-flink/current/configure/artifacts.html)
- [colors-and-shapes README](../README.md)
