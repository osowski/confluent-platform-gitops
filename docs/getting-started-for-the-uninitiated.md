# Getting Started for the Completely Uninitiated

If you know what Kubernetes is but have no idea what ArgoCD, GitOps, or anything else in this repository means — this guide is for you. It covers the shortest path from a fresh macOS environment to a running cluster with everything deployed. The reference cluster for this guide is [`flink-demo`](../clusters/flink-demo/README.md), using the domain `*.flink-demo.confluentdemo.local`.

## Prerequisites

1. Install required tools via Homebrew:

```bash
brew install colima \
    kind \
    kubectl \
    kubectx \
    yq
```

2. Add the following entries to `/etc/hosts` (all pointing to `127.0.0.1`). If
   you're following this guide from a remote VM with a public IP rather than
   your own machine, run `./scripts/generate-hosts-entries.sh flink-demo`
   instead — it detects that IP for you and points these same hostnames at
   it:

```
127.0.0.1  alertmanager.flink-demo.confluentdemo.local
127.0.0.1  argocd.flink-demo.confluentdemo.local
127.0.0.1  cmf.flink-demo.confluentdemo.local
127.0.0.1  controlcenter.flink-demo.confluentdemo.local
127.0.0.1  grafana.flink-demo.confluentdemo.local
127.0.0.1  headlamp.flink-demo.confluentdemo.local
127.0.0.1  kafka.flink-demo.confluentdemo.local
127.0.0.1  prometheus.flink-demo.confluentdemo.local
127.0.0.1  s3.flink-demo.confluentdemo.local
127.0.0.1  s3-console.flink-demo.confluentdemo.local
127.0.0.1  schema-registry.flink-demo.confluentdemo.local
127.0.0.1  vault.flink-demo.confluentdemo.local
```

> [!WARNING]
> If you experience ~5-second timeouts when accessing services, you may need to add IPv6 entries as well. Some HTTP clients (including the Confluent CLI) prefer IPv6 and will timeout trying `::1` before falling back to IPv4. Add these additional entries to `/etc/hosts` if needed:
> ```
> ::1  alertmanager.flink-demo.confluentdemo.local
> ::1  argocd.flink-demo.confluentdemo.local
> ::1  cmf.flink-demo.confluentdemo.local
> ::1  controlcenter.flink-demo.confluentdemo.local
> ::1  grafana.flink-demo.confluentdemo.local
> ::1  headlamp.flink-demo.confluentdemo.local
> ::1  kafka.flink-demo.confluentdemo.local
> ::1  prometheus.flink-demo.confluentdemo.local
> ::1  s3.flink-demo.confluentdemo.local
> ::1  s3-console.flink-demo.confluentdemo.local
> ::1  schema-registry.flink-demo.confluentdemo.local
> ::1  vault.flink-demo.confluentdemo.local
> ```

## Checkout the Latest Release

3. List available release tags and checkout the latest one:

```bash
git tag --sort=-v:refname
git checkout <latest-tag>   # e.g., git checkout v0.2.0
```

Checking out a release tag ensures you are working from a known-good snapshot where all `targetRevision` values are pinned to that version. If you stay on `main`, the deployment will track `HEAD` and may include in-progress changes. See [Release Process](release-process.md) for details.

## Cluster Setup

4. Start Colima (provides the Docker runtime that kind uses):

```bash
colima start --arch arm64 --memory 16 --cpu 8 --disk 256
```

Then raise the Colima VM's inotify limits. The default `fs.inotify.max_user_instances` of `128` is **not enough** for a multi-node kind cluster running Confluent Platform, and exhausting it breaks the cluster in confusing ways:

```bash
colima ssh -- sudo sh -c 'cat > /etc/sysctl.d/99-inotify-k8s.conf <<EOF
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 1048576
EOF
sysctl -p /etc/sysctl.d/99-inotify-k8s.conf'
```

To make this survive a Colima VM *recreation* (`colima delete`), also add a provision block to `~/.colima/default/colima.yaml`, replacing the default `provision: null`:

```yaml
provision:
  - mode: system
    script: |
      cat > /etc/sysctl.d/99-inotify-k8s.conf <<'SYSCTL'
      fs.inotify.max_user_instances = 1024
      fs.inotify.max_user_watches = 1048576
      SYSCTL
      sysctl -p /etc/sysctl.d/99-inotify-k8s.conf
```

Verify the limit is in effect before creating the cluster:

```bash
colima ssh -- cat /proc/sys/fs/inotify/max_user_instances   # expect 1024
```

5. Create the kind cluster:

```bash
kind create cluster --config ./clusters/flink-demo/kind-config.yaml --name flink-demo
```

6. Select the flink-demo Kubernetes context:

```bash
kubectx kind-flink-demo
```

## ArgoCD Installation

7. Create the ArgoCD namespace:

```bash
kubectl create namespace argocd
```

8. Install ArgoCD:

```bash
kubectl apply --namespace argocd --server-side --force-conflicts --filename https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

9. Wait for all ArgoCD pods to be ready:

```bash
kubectl wait pods --namespace argocd --all --for=condition=Ready --timeout=300s
```

## Bootstrap

10. Apply the cluster bootstrap:

```bash
kubectl apply --filename ./clusters/flink-demo/bootstrap.yaml
```

ArgoCD will create the `infrastructure` and `workloads` parent Applications, which in turn deploy all configured components automatically.

## Access ArgoCD

11. Retrieve the initial admin password:

```bash
kubectl get secret --namespace argocd argocd-initial-admin-secret --output jsonpath='{.data.password}' | base64 -d | pbcopy
```

12. Open ArgoCD in your browser:

- URL: [`https://argocd.flink-demo.confluentdemo.local`](https://argocd.flink-demo.confluentdemo.local)
    - **NOTE:** Ensure that this is using `https` as we are using a self-signed cert for ArgoCD ingress.
- Username: `admin`
- Password: paste from clipboard (copied in the previous step)

You should see the `bootstrap`, `infrastructure`, and `workloads` Applications syncing.

## Deploy Confluent and Flink Workloads

The `confluent-resources`, `flink-resources`, and `colors-and-shapes` Applications are not configured for automatic sync, as they depend on the operators and namespaces being fully ready first. Trigger them manually once the `workloads` Application is healthy.

13. In the ArgoCD UI, click on the `confluent-resources` Application, then click **Sync** → **Synchronize**. Wait for it to reach a `Healthy` status before proceeding.

14. Click on the `flink-resources` Application, then click **Sync** → **Synchronize**. Wait for it to reach a `Healthy` status.

15. Click on the `colors-and-shapes` Application, then click **Sync** → **Synchronize**. Wait for it to reach a `Healthy` status. This deploys the two-tenant (`shapes`/`colors`) demo the rest of this guide walks through.
   - For future self-paced research or reuse, reference the [colors-and-shapes/README.md](https://github.com/osowski/confluent-platform-gitops/blob/main/workloads/colors-and-shapes/README.md) document for a full detail on this sample artifact.

## Access Control Center

16. Open Confluent Control Center in your browser:

- URL: [`https://controlcenter.flink-demo.confluentdemo.local`](https://controlcenter.flink-demo.confluentdemo.local)

> [!NOTE]
> **Two ways to deploy a Flink job:** `colors-and-shapes` deploys the same logical pipeline twice, side by side, using both models CMF supports:
>
> - **Native `FlinkApplication` (JAR)** — a compiled Java job (`shapes`, `colors`) submitted as a Kubernetes custom resource. You bring a JAR; CMF/CFK run it. This is the model for hand-written stream processing applications.
> - **Flink SQL (`FlinkStatement`)** — a declarative SQL `INSERT INTO ... SELECT` (`shapes-sql-enrich`, `colors-sql-enrich`), submitted through the CMF UI or REST API rather than compiled. This is the model for analysts and anyone who'd rather write SQL than Java.
>
> Both read the same `*-input` topic and write to their own output topic (`*-output` for the JAR, `*-sql-output` for SQL), so you can compare them directly on identical data. The rest of this guide uses the `colors` tenant as the running example — everything applies equally to `shapes`.

## Access the CMF UI

17. Open the CMF UI in your browser:

- URL: [`https://cmf-ui.flink-demo.confluentdemo.local`](https://cmf-ui.flink-demo.confluentdemo.local)

Take a moment to orient yourself around the main tabs:

- **Environments** — `colors-env`/`shapes-env` (one per tenant) plus `default`
- **Compute Pools** — `colors-pool`/`shapes-pool`, where SQL statements actually run
- **Applications** — the JAR `FlinkApplication`s (`colors`, `shapes`)
- **Statements** — the SQL `FlinkStatement`s (`colors-sql-enrich`, `shapes-sql-enrich`) plus any ad hoc statement you submit yourself
- **Artifacts** — uploaded JARs available to reference from SQL (used later for the UDF)

## Scale Up the Producers

Both tenants ship with their producer `Deployment`s scaled to zero, so there's no traffic until you turn them on.

18. Generate traffic for both tenants:

```bash
kubectl -n flink-colors scale deploy/colors-producer --replicas=1
kubectl -n flink-shapes scale deploy/shapes-producer --replicas=1
```

Confirm messages are flowing in Control Center (**Topics** → `colors-input` → **Messages**). You only need to use `colors` or `shapes` for this tutorial; both are not required.

## Explore the Running Jobs in CMF

19. In the CMF UI, open **Environments** and click into **`colors-env`**. This scopes the rest of the page to just the `colors` tenant — its own Compute Pools, Applications, Statements, and Artifacts, rather than the cluster-wide lists from the previous step. Do the remaining steps in this guide from inside this environment view unless noted otherwise.

20. Open **Applications** → `colors` to see the JAR job's graph, parallelism, and checkpoint history, then open **Statements** → `colors-sql-enrich` to see the SQL job's equivalent view. Both should show a `RUNNING` status once the producer traffic above reaches them.

## Run a Flink SQL Statement

21. Submit your own ad hoc statement against the `colors` tenant: in the CMF UI (inside `colors-env`), open the **Statements** tab and start a new statement via **Add statement** _(exact wording may vary by CMF version)_ against compute pool `colors-pool`, catalog `colors-catalog`, database `colors-database`, and run a simple read to confirm the setup:

```sql
SELECT * FROM `colors-input` LIMIT 10;
```

Once you've seen results, compare it against the "real" pipeline already running: `colors-sql-enrich`'s statement (viewable from **Statements** in the CMF UI) follows the same `INSERT INTO ... SELECT ... FROM colors-input` shape you'll use again in the next section.

## Deploy and Reference a UDF

This section walks through registering a user-defined function and calling it from SQL — the full version, with more background on artifacts and troubleshooting, lives in [colors-and-shapes' UDF demo](../workloads/colors-and-shapes/udf-demo/README.md).

This section requires Java and Maven. Confirm you have them with `java -version && mvn -version`, or install via Homebrew if needed:

```bash
brew install openjdk maven
```

22. Build the function JAR:

```bash
cd workloads/colors-and-shapes/udf-demo
mvn package
```

This writes `target/udfs.jar`, containing a scalar function `com.example.ToUpperCase`.

23. Upload the JAR as a CMF artifact:

   - **Via the browser** at [`https://cmf.flink-demo.confluentdemo.local/home/environments/details/colors-env/artifacts/list`](https://cmf.flink-demo.confluentdemo.local/home/environments/details/colors-env/artifacts/list) — use the upload control to select `target/udfs.jar` directly from your machine.

   - **Or, via `curl`:**

     ```bash
     # Extract the CA cert cert-manager generated for cmf-tls (self-signed; only needed once per session)
     kubectl get secret cmf-tls --namespace operator -o jsonpath='{.data.ca\.crt}' \
       | base64 --decode > /tmp/cmf-ca.crt

     cat > /tmp/artifact.json <<'EOF'
     {
       "apiVersion": "cmf.confluent.io/v1",
       "kind": "Artifact",
       "metadata": {
         "name": "udfs.jar"
       },
       "spec": {}
     }
     EOF

     curl -X POST https://cmf.flink-demo.confluentdemo.local/cmf/api/v1/environments/colors-env/artifacts \
       --cacert /tmp/cmf-ca.crt \
       -F 'artifact=@/tmp/artifact.json;type=application/json' \
       -F 'file=@target/udfs.jar'
     ```

A successful upload returns HTTP 201 with the created artifact at version 1. Confirm it in the browser: open the CMF UI's **Artifacts** tab (inside `colors-env`) and refresh — `udfs.jar` should now be listed at version 1.

24. Register the function: start a new SQL statement against environment `colors-env`, compute pool `colors-pool`, catalog `_env_colors-env`, database `default`, and run:

```sql
CREATE FUNCTION IF NOT EXISTS to_upper
  AS 'com.example.ToUpperCase'
  USING JAR 'cmf://colors-env/udfs.jar';
```

25. Stop the existing `colors-sql-enrich` statement so it isn't also writing to `colors-sql-output` while you test the UDF:

```bash
kubectl delete flinkstatement -n flink-colors colors-sql-enrich
```

Deleting the `FlinkStatement` CR tells CFK to reconcile the deletion into CMF; within a few seconds, `colors-sql-enrich` should disappear from the CMF UI's **Statements** tab (inside `colors-env`) and its Flink job stops.

26. Apply the function: start a **new** statement, same environment/pool, but with catalog `colors-catalog` and database `colors-database` this time (the catalog where `colors-input`/`colors-sql-output` live), and run:

```sql
INSERT INTO `colors-sql-output`
/*+ OPTIONS('kafka.producer.transaction.timeout.ms' = '900000') */
(`timestamp`, `type`, `location`, `value`, `status`, `id`, `encoded`, `error`, `original`)
SELECT `timestamp`, `_env_colors-env`.`default`.`to_upper`(`type`) AS `type`, `location`, `value`,
  `_env_colors-env`.`default`.`to_upper`(`status`) AS `status`, `id`,
  CAST(NULL AS STRING) AS `encoded`, CAST(NULL AS STRING) AS `error`, CAST(NULL AS STRING) AS `original`
FROM `colors-input`
/*+ OPTIONS('properties.group.id' = 'colors-udf-demo') */;
```

> [!WARNING]
> An unqualified `to_upper()` here fails validation — function resolution is scoped to the current catalog (`colors-catalog`), and `to_upper` was registered in `_env_colors-env`. It must be called by its fully-qualified path, as above.

## Verify in Control Center

27. Open Control Center → **Topics** → `colors-sql-output` → **Messages**, and browse records. Every record should show `type`/`status` in upper case — since `colors-sql-enrich` was deleted in the previous section, this UDF statement is now the only thing writing to `colors-sql-output`. (If you skipped that deletion, you'll instead see upper-cased records interleaved with original-case ones, since both statements read `colors-input` independently but write to the same sink.)

## Cleanup

28. When you're done experimenting, tear down what you added (the base `colors-and-shapes` deployment stays running):

In the CMF UI's **Statements** tab (inside `colors-env`), stop/delete the ad hoc statements you submitted above — the `SELECT * FROM colors-input LIMIT 10` test and the `INSERT INTO colors-sql-output ... to_upper(...)` statement. Unlike `colors-sql-enrich` (a named `FlinkStatement` CR), ad hoc statements get an auto-generated ID as their name, something like `c3-20260911-163407-fe8658440bc1bc028c65c233` — match them by their SQL preview in the Statements list, not by name. Then drop the function:

```sql
DROP FUNCTION IF EXISTS to_upper;
```

Then scale the producers back down if you're pausing rather than finishing:

```bash
kubectl -n flink-colors scale deploy/colors-producer --replicas=0
kubectl -n flink-shapes scale deploy/shapes-producer --replicas=0
```

---

> **Note on flag style:** All `kubectl` commands in this guide use long-form flags (e.g. `--namespace`, `--filename`, `--output`) for clarity. In day-to-day use, most practitioners use the equivalent short-form flags (e.g. `-n`, `-f`, `-o`).
