# Getting Started for IBM TSAW Workshops

This guide is a workshop-day variant of [Getting Started for the Uninitiated](getting-started-for-the-uninitiated.md), adapted for the IBM TSAW workshop environment. That environment provisions the underlying container runtime and the kind Kubernetes cluster for you, with `kubectx` already pointed at it — so this guide picks up at tool installation and skips straight to ArgoCD. The reference cluster is [`flink-demo`](../clusters/flink-demo/README.md), using the domain `*.flink-demo.confluentdemo.local`.

Once the cluster is bootstrapped, this guide continues past Control Center into a hands-on tour of Confluent Manager for Apache Flink (CMF): the CMF UI, generating traffic, running Flink SQL statements, and deploying a user-defined function (UDF).

## Prerequisites

1. Request a new environment on TechZone via `https://techzone.ibm.com/collection/watsonx-data-integration-tech-sales/environments`, selecting **Confluent Platform Lab - TSAW**. The environment may take 40 - 60 minutes to provision entirely, so plan ahead accordingly.

2. While waiting on the environment to be provisioned, clone this repository locally and checkout the latest tagged release. The latest tagged release may differ from the inline documentation in this walkthrough.

```bash
git clone https://github.com/osowski/confluent-platform-gitops.git
cd confluent-platform-gitops
git tag --sort=-v:refname | head -n 1
git checkout v0.8.2      # e.g., git checkout v0.2.0
```

Checking out a release tag ensures you are working from a known-good snapshot where all `targetRevision` values are pinned to that version. If you stay on `main`, the deployment will track `HEAD` and may include in-progress changes. See [Release Process](release-process.md) for details.

3. Once the environment is provisioned, create the SSH key locally on your machine to access the remote environment. This is available under the **Outputs** -> **SSH private key** section of the TechZone environment instance page.
   - Copy the entire string below **SSH private key**, including the `-----BEGIN OPENSSH PRIVATE KEY-----` header and `-----END OPENSSH PRIVATE KEY-----` footer.
   - Save this to a local file on your workstation. (e.g. `~/.ssh/techzone-lab-key.pem`)
   - Ensure the permissions are appropriately set for the private key. (e.g. `chmod 0600 ~/.ssh/techzone-lab-key.pem`)

4. Update local `/etc/hosts` entries to handle browser-based access.

Underneath the **Connect** heading, you will see a line similar to `ssh -i lab-key.pem root@256.256.256.256`.  The IP address in this command is your instance's unique public IP address. We will generate a list of all the Ingress endpoints that run inside the Kubernetes cluster to point to this public IP address.

```bash
# from inside the `confluent-platform-gitops` cloned repository
./scripts/generate-hosts-entries.sh flink-demo 256.256.256.256
```

  The above command will output something similar to the following (when substituting your actual IP address). Add the generated entries to `/etc/hosts` on your local machine (not the remote VM!):
```bash
# /etc/hosts entries for flink-demo (generated 2026-09-11T21:00:18Z)
256.256.256.256  alertmanager.flink-demo.confluentdemo.local
256.256.256.256  argocd.flink-demo.confluentdemo.local
256.256.256.256  cmf-ui.flink-demo.confluentdemo.local
256.256.256.256  cmf.flink-demo.confluentdemo.local
256.256.256.256  controlcenter.flink-demo.confluentdemo.local
256.256.256.256  grafana.flink-demo.confluentdemo.local
256.256.256.256  headlamp.flink-demo.confluentdemo.local
256.256.256.256  kafka.flink-demo.confluentdemo.local
256.256.256.256  prometheus.flink-demo.confluentdemo.local
256.256.256.256  s3-console.flink-demo.confluentdemo.local
256.256.256.256  s3.flink-demo.confluentdemo.local
256.256.256.256  schema-registry.flink-demo.confluentdemo.local
256.256.256.256  vault.flink-demo.confluentdemo.local
```

5. From your local machine, connect to the remote machine via your preferred SSH method. This can be done most simply on Macs and WSL via:

```bash
ssh -i ~/.ssh/techzone-lab-key.pem root@256.256.256.256
```

Everything from here on — every `kubectl` command, the `mvn package` build, and the `curl` calls in the UDF section — runs inside this SSH session, on the remote VM. Only the browser-based UI steps (ArgoCD, Control Center, CMF) happen on your local machine.

## ArgoCD Installation

6. The workshop environment has already created the kind cluster and pointed your `kubectl` context at it. Confirm with the commands below:

```bash
kubectl config current-context # current context is marked with `*` and should be `kind-flink-demo`

# if you need to reset your kubeconfig pointing to the correct context for whatever reason
export KUBECONFIG=/root/.kube/config
```

7. Create the ArgoCD namespace:

```bash
kubectl create namespace argocd
```

8. Install ArgoCD:

```bash
kubectl apply --namespace argocd --server-side --force-conflicts --filename https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.1/manifests/install.yaml
```

9. Wait for all ArgoCD pods to be ready:

```bash
kubectl wait pods --namespace argocd --all --for=condition=Ready --timeout=300s
```

## Bootstrap

10. The environment already has this repository cloned into `/opt/lab/confluent-platform-gitops` on the VM — this is the root working directory for the rest of the workshop:

```bash
cd /opt/lab/confluent-platform-gitops
```

11. Apply the cluster bootstrap:

```bash
kubectl apply --filename ./clusters/flink-demo/bootstrap.yaml
```

ArgoCD will create the `infrastructure` and `workloads` parent Applications, which in turn deploy all configured components automatically.

## Access ArgoCD

12. Retrieve the initial admin password:

```bash
kubectl get secret --namespace argocd argocd-initial-admin-secret --output jsonpath='{.data.password}' | base64 -d && echo ""
```

13. Open ArgoCD in your browser:

- URL: [`https://argocd.flink-demo.confluentdemo.local`](https://argocd.flink-demo.confluentdemo.local)
    - **NOTE:** Ensure that this is using `https` as we are using a self-signed cert for ArgoCD ingress.
- Username: `admin`
- Password: paste from clipboard (copied in the previous step)

You should see the `bootstrap`, `infrastructure`, and `workloads` Applications syncing. If they are not fully synchronized within a few minutes, select **Refresh Apps** → **All** → **Refresh** for ArgoCD to check again.

## Deploy Confluent and Flink Workloads

The `confluent-resources`, `flink-resources`, and `colors-and-shapes` Applications are not configured for automatic sync, as they depend on the operators and namespaces being fully ready first. Trigger them manually once the `workloads` Application is healthy.

14. In the ArgoCD UI, click on the `confluent-resources` Application, then click **Sync** → **Synchronize**. Wait for it to reach a `Healthy` status before proceeding. This may take a few minutes as Kafka and Control Center come fully online.

15. Click on the `flink-resources` Application, then click **Sync** → **Synchronize**. Wait for it to reach a `Healthy` status.

16. Click on the `colors-and-shapes` Application, then click **Sync** → **Synchronize**. Wait for it to reach a `Healthy` status. This deploys the two-tenant (`shapes`/`colors`) demo the rest of this guide walks through.
   - For future self-paced research or reuse, reference the [colors-and-shapes/README.md](https://github.com/osowski/confluent-platform-gitops/blob/main/workloads/colors-and-shapes/README.md) document for a full detail on this sample artifact.

## Access Control Center

17. Open Confluent Control Center in your browser:

- URL: [`https://controlcenter.flink-demo.confluentdemo.local`](https://controlcenter.flink-demo.confluentdemo.local)

> [!NOTE]
> **Two ways to deploy a Flink job:** `colors-and-shapes` deploys the same logical pipeline twice, side by side, using both models CMF supports:
>
> - **Native `FlinkApplication` (JAR)** — a compiled Java job (`shapes`, `colors`) submitted as a Kubernetes custom resource. You bring a JAR; CMF/CFK run it. This is the model for hand-written stream processing applications.
> - **Flink SQL (`FlinkStatement`)** — a declarative SQL `INSERT INTO ... SELECT` (`shapes-sql-enrich`, `colors-sql-enrich`), submitted through the CMF UI or REST API rather than compiled. This is the model for analysts and anyone who'd rather write SQL than Java.
>
> Both read the same `*-input` topic and write to their own output topic (`*-output` for the JAR, `*-sql-output` for SQL), so you can compare them directly on identical data. The rest of this guide uses the `colors` tenant as the running example — everything applies equally to `shapes`.

## Access the CMF UI

18. Open the CMF UI in your browser:

- URL: [`https://cmf-ui.flink-demo.confluentdemo.local`](https://cmf-ui.flink-demo.confluentdemo.local)

Take a moment to orient yourself around the main tabs:

- **Environments** — `colors-env`/`shapes-env` (one per tenant) plus `default`
- **Compute Pools** — `colors-pool`/`shapes-pool`, where SQL statements actually run
- **Applications** — the JAR `FlinkApplication`s (`colors`, `shapes`)
- **Statements** — the SQL `FlinkStatement`s (`colors-sql-enrich`, `shapes-sql-enrich`) plus any ad hoc statement you submit yourself
- **Artifacts** — uploaded JARs available to reference from SQL (used later for the UDF)

## Scale Up the Producers

Both tenants ship with their producer `Deployment`s scaled to zero, so there's no traffic until you turn them on.

19. Generate traffic for both tenants:

```bash
kubectl -n flink-colors scale deploy/colors-producer --replicas=1
kubectl -n flink-shapes scale deploy/shapes-producer --replicas=1
```

Confirm messages are flowing in Control Center (**Topics** → `colors-input` → **Messages**). You only need to use `colors` or `shapes` for this tutorial; both are not required.

## Explore the Running Jobs in CMF

20. In the CMF UI, open **Environments** and click into **`colors-env`**. This scopes the rest of the page to just the `colors` tenant — its own Compute Pools, Applications, Statements, and Artifacts, rather than the cluster-wide lists from the previous step. Do the remaining steps in this guide from inside this environment view unless noted otherwise.

21. Open **Applications** → `colors` to see the JAR job's graph, parallelism, and checkpoint history, then open **Statements** → `colors-sql-enrich` to see the SQL job's equivalent view. Both should show a `RUNNING` status once the producer traffic above reaches them.

## Run a Flink SQL Statement

22. Submit your own ad hoc statement against the `colors` tenant: in the CMF UI (inside `colors-env`), open the **Statements** tab and start a new statement (labeled something like **+ New Statement** — exact wording may vary by CMF version) against compute pool `colors-pool`, catalog `colors-catalog`, database `colors-database`, and run a simple read to confirm the setup:

```sql
SELECT * FROM `colors-input` LIMIT 10;
```

Once you've seen results, compare it against the "real" pipeline already running: `colors-sql-enrich`'s statement (viewable from **Statements** in the CMF UI) follows the same `INSERT INTO ... SELECT ... FROM colors-input` shape you'll use again in the next section.

## Deploy and Reference a UDF

This section walks through registering a user-defined function and calling it from SQL — the full version, with more background on artifacts and troubleshooting, lives in [colors-and-shapes' UDF demo](../workloads/colors-and-shapes/udf-demo/README.md).

The lab VM already has Java and Maven installed for this — confirm with `java -version && mvn -version` before continuing.

23. Build the function JAR:

```bash
cd workloads/colors-and-shapes/udf-demo
mvn package
```

This writes `target/udfs.jar`, containing a scalar function `com.example.ToUpperCase`.

24. Upload the JAR as a CMF artifact. Since the browser runs on your local machine but `target/udfs.jar` only exists on the remote VM, upload it via `curl` from the same SSH session instead of the browser's file picker:

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

25. Register the function: start a new SQL statement against environment `colors-env`, compute pool `colors-pool`, catalog `_env_colors-env`, database `default`, and run:

```sql
CREATE FUNCTION IF NOT EXISTS to_upper
  AS 'com.example.ToUpperCase'
  USING JAR 'cmf://colors-env/udfs.jar';
```

26. Stop the existing `colors-sql-enrich` statement so it isn't also writing to `colors-sql-output` while you test the UDF:

```bash
kubectl delete flinkstatement -n flink-colors colors-sql-enrich
```

Deleting the `FlinkStatement` CR tells CFK to reconcile the deletion into CMF; within a few seconds, `colors-sql-enrich` should disappear from the CMF UI's **Statements** tab (inside `colors-env`) and its Flink job stops.

27. Apply the function: start a **new** statement, same environment/pool, but with catalog `colors-catalog` and database `colors-database` this time (the catalog where `colors-input`/`colors-sql-output` live), and run:

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

28. Open Control Center → **Topics** → `colors-sql-output` → **Messages**, and browse records. Every record should show `type`/`status` in upper case — since `colors-sql-enrich` was deleted in the previous section, this UDF statement is now the only thing writing to `colors-sql-output`. (If you skipped that deletion, you'll instead see upper-cased records interleaved with original-case ones, since both statements read `colors-input` independently but write to the same sink.)

## Cleanup

29. When you're done experimenting, tear down what you added (the base `colors-and-shapes` deployment stays running):

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
