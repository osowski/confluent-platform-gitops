# flink-demo-rbac Cluster

Demo cluster for Confluent Platform with RBAC-enabled Apache Flink integration, showcasing multi-tenant GitOps deployment with Keycloak SSO, MDS-based authorization, and group-scoped Flink SQL environments.

## Overview

The `flink-demo-rbac` cluster demonstrates a complete Confluent Platform deployment with RBAC including:

- **Kafka Cluster**: KRaft-based Kafka with Schema Registry, Control Center, and MDS for authorization
- **Flink Integration**: Flink Kubernetes Operator with CMF, group-scoped catalogs and compute pools
- **Monitoring**: Prometheus, Grafana, and Alertmanager with pre-configured dashboards
- **Security**: Keycloak for SSO/OAuth, MDS for RBAC, cert-manager for TLS, Reflector for secret replication
- **Networking**: Traefik ingress controller with local DNS resolution
- **Storage**: MinIO for S3-compatible object storage (Flink checkpoints and savepoints)

**Domain**: `*.flink-demo-rbac.confluentdemo.local`

## Getting Started

> [!TIP]
> **New to this repository?** Start with the [Getting Started for the Uninitiated](../../docs/getting-started-for-the-uninitiated.md) guide for complete step-by-step setup instructions including:
> - Prerequisites and tool installation
> - DNS configuration (`/etc/hosts` setup with IPv6 timeout workaround)
> - Cluster creation and ArgoCD installation
> - Bootstrap and initial deployment
> - Accessing ArgoCD UI

### Deploy Bootstrap

```bash
kubectl apply -f clusters/flink-demo-rbac/bootstrap.yaml
```

### Verify Deployment

```bash
# Check bootstrap application
kubectl get application bootstrap -n argocd

# Check all applications
kubectl get applications -n argocd

# Watch sync progress
kubectl get applications -n argocd -w
```

### Manual Sync Applications

The `confluent-resources`, `flink-resources`, and `colors-and-shapes` Applications require manual sync to ensure operators and namespaces are fully ready.

**Wait for operators to be healthy:**

```bash
# Check CFK operator
kubectl wait --namespace operator --for=condition=Ready pods -l app=confluent-operator --timeout=300s

# Check CMF operator
kubectl wait --namespace operator --for=condition=Ready pods -l app.kubernetes.io/name=confluent-for-apache-flink --timeout=300s

# Check Flink Kubernetes Operator
kubectl wait --namespace operator --for=condition=Ready pods -l app.kubernetes.io/name=flink-kubernetes-operator --timeout=300s
```

**Sync confluent-resources:**

In the ArgoCD UI:
1. Click on `confluent-resources` Application
2. Click **Sync** → **Synchronize**
3. Wait for `Healthy` status (~5-10 minutes)

**Sync flink-resources:**

In the ArgoCD UI:
1. Click on `flink-resources` Application
2. Click **Sync** → **Synchronize**
3. Wait for `Healthy` status (~2-3 minutes)

**Sync colors-and-shapes:**

In the ArgoCD UI:
1. Click on `colors-and-shapes` Application
2. Click **Sync** → **Synchronize**
3. Wait for `Healthy` status (~3-5 minutes)

### Generate Data

The `colors-and-shapes` Application includes two producer Deployments that write Avro-encoded sensor data to the group input topics. They are deployed with `replicas: 0` by default and must be scaled up to start producing:

```bash
# Start the shapes producer (writes to shapes-input topic in flink-shapes namespace)
kubectl scale deployment shapes-producer -n flink-shapes --replicas=1

# Start the colors producer (writes to colors-input topic in flink-colors namespace)
kubectl scale deployment colors-producer -n flink-colors --replicas=1
```

Each producer authenticates to Kafka via OAuth (OAUTHBEARER) using group-specific service account credentials and publishes at 10 messages/second. Once scaled, data will flow through the `shapes-input` and `colors-input` topics and be visible in Control Center.

To stop producing, scale back to 0:

```bash
kubectl scale deployment shapes-producer -n flink-shapes --replicas=0
kubectl scale deployment colors-producer -n flink-colors --replicas=0
```

## Applications

### Infrastructure Applications

Infrastructure applications are defined in `infrastructure/kustomization.yaml`:

- **kube-prometheus-stack-crds** (wave 2) - Prometheus Operator CRDs
- **metrics-server** (wave 5) - Kubernetes Metrics Server
- **traefik** (wave 10) - Ingress controller
- **cert-manager** (wave 20) - TLS certificate management
- **kube-prometheus-stack** (wave 20) - Monitoring stack (Prometheus, Grafana, Alertmanager)
- **trust-manager** (wave 30) - CA certificate distribution
- **reflector** (wave 40) - Secret/ConfigMap replication across namespaces
- **cert-manager-resources** (wave 75) - ClusterIssuer and certificates
- **argocd-ingress** (wave 80) - Traefik IngressRoute for ArgoCD UI
- **argocd-config** (wave 85) - ArgoCD ConfigMap patches for custom health checks
- **minio** (wave 85) - S3-compatible object storage (namespace: storage)

### Workload Applications

Workload applications are defined in `workloads/kustomization.yaml`:

- **namespaces** (wave 100) - Namespace definitions (kafka, flink, operator, keycloak, storage)
- **keycloak** (wave 102) - Keycloak identity provider for SSO/OAuth
- **cfk-operator** (wave 105) - Confluent for Kubernetes operator
- **mds-keygen** (wave 106) - MDS token keypair generation
- **confluent-resources** (wave 110) - Confluent Platform (KRaft, Kafka, Schema Registry, MDS, etc.) — **manual sync**
- **ingresses** (wave 110) - Traefik IngressRoutes for all services
- **flink-kubernetes-operator** (wave 116) - Flink Kubernetes Operator
- **observability-resources** (wave 117) - PodMonitors and Grafana dashboards
- **cmf-operator-secrets** (wave 117) - CMF operator secret configuration
- **cmf-operator** (wave 118) - Confluent Manager for Apache Flink
- **flink-resources** (wave 119) - Core CMFRestClass + single `default` FlinkEnvironment + generic Flink SQL demo, with OAuth layered on via the `oauth` component — **manual sync** — see [Flink Resources README](../../workloads/flink-resources/README.md)
- **colors-and-shapes** (wave 120) - Two-tenant Flink demo (JAR + SQL), with Kubernetes RBAC and Keycloak OAuth layered on via the `rbac-oauth` component — **manual sync** — see [Colors and Shapes README](../../workloads/colors-and-shapes/README.md)

## Environment Access

### DNS Configuration

Add these entries to `/etc/hosts`:

```
127.0.0.1  alertmanager.flink-demo-rbac.confluentdemo.local
127.0.0.1  argocd.flink-demo-rbac.confluentdemo.local
127.0.0.1  cmf.flink-demo-rbac.confluentdemo.local
127.0.0.1  cmf-ui.flink-demo-rbac.confluentdemo.local
127.0.0.1  controlcenter.flink-demo-rbac.confluentdemo.local
127.0.0.1  grafana.flink-demo-rbac.confluentdemo.local
127.0.0.1  headlamp.flink-demo-rbac.confluentdemo.local
127.0.0.1  kafka.flink-demo-rbac.confluentdemo.local
127.0.0.1  kafka-0.flink-demo-rbac.confluentdemo.local
127.0.0.1  kafka-1.flink-demo-rbac.confluentdemo.local
127.0.0.1  kafka-2.flink-demo-rbac.confluentdemo.local
127.0.0.1  keycloak.flink-demo-rbac.confluentdemo.local
127.0.0.1  mds.flink-demo-rbac.confluentdemo.local
127.0.0.1  prometheus.flink-demo-rbac.confluentdemo.local
127.0.0.1  schema-registry.flink-demo-rbac.confluentdemo.local
127.0.0.1  s3.flink-demo-rbac.confluentdemo.local
127.0.0.1  s3-console.flink-demo-rbac.confluentdemo.local
```

> [!WARNING]
> If you experience ~5-second timeouts when accessing services, add IPv6 entries as well:
> ```
> ::1  alertmanager.flink-demo-rbac.confluentdemo.local
> ::1  argocd.flink-demo-rbac.confluentdemo.local
> ::1  cmf.flink-demo-rbac.confluentdemo.local
> ::1  cmf-ui.flink-demo-rbac.confluentdemo.local
> ::1  controlcenter.flink-demo-rbac.confluentdemo.local
> ::1  grafana.flink-demo-rbac.confluentdemo.local
> ::1  headlamp.flink-demo-rbac.confluentdemo.local
> ::1  kafka.flink-demo-rbac.confluentdemo.local
> ::1  kafka-0.flink-demo-rbac.confluentdemo.local
> ::1  kafka-1.flink-demo-rbac.confluentdemo.local
> ::1  kafka-2.flink-demo-rbac.confluentdemo.local
> ::1  keycloak.flink-demo-rbac.confluentdemo.local
> ::1  mds.flink-demo-rbac.confluentdemo.local
> ::1  prometheus.flink-demo-rbac.confluentdemo.local
> ::1  schema-registry.flink-demo-rbac.confluentdemo.local
> ::1  s3.flink-demo-rbac.confluentdemo.local
> ::1  s3-console.flink-demo-rbac.confluentdemo.local
> ```

### Services

**ArgoCD UI:**
- **URL**: https://argocd.flink-demo-rbac.confluentdemo.local
- **Username**: `admin`
- **Password**: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`

**Control Center:**
- **URL**: https://controlcenter.flink-demo-rbac.confluentdemo.local
- **Username**: `admin@osow.ski` (via Keycloak SSO)
- **Password**: `admin123`

**CMF UI (Flink environments, applications, artifacts):**
- **URL**: https://cmf.flink-demo-rbac.confluentdemo.local or https://cmf-ui.flink-demo-rbac.confluentdemo.local (both route to the same backend; browser SSO via Keycloak)
- **Username**: `admin@osow.ski` (redirected to Keycloak on first access)
- **Password**: `admin123`
- CMF's native SSO handles the browser login directly — no reverse proxy involved. Artifact
  upload/management lives in this UI (Control Center has no artifacts page).
- **Log in as `admin@osow.ski` by default.** Only `shapes`/`colors` group members have
  RBAC access to the `shapes-env`/`colors-env` FlinkEnvironments — everything else,
  including the `default` FlinkEnvironment (see
  [flink-resources README](../../workloads/flink-resources/README.md#who-can-write-to-the-default-environment-rbac-clusters)),
  is only writable by `admin`/`cmf`. Log in as a `shapes`/`colors` group user only when
  specifically working in those tenants' environments.

**Keycloak Admin Console:**
- **URL**: http://keycloak.flink-demo-rbac.confluentdemo.local:30080
- **Username**: `flink-admin`
- **Password**: `admin123`

**Grafana:**
- **URL**: http://grafana.flink-demo-rbac.confluentdemo.local
- **Username**: `admin`
- **Password**: `prom-operator`

**Prometheus:**
- **URL**: http://prometheus.flink-demo-rbac.confluentdemo.local

**Alertmanager:**
- **URL**: http://alertmanager.flink-demo-rbac.confluentdemo.local

**MDS (Metadata Service) for CLI Authentication:**

```bash
export CONFLUENT_PLATFORM_SSO=true

# Login via MDS ingress
confluent login --url http://mds.flink-demo-rbac.confluentdemo.local:80 --no-browser

# Follow device grant flow prompts
```

**CMF API:**

```bash
export CONFLUENT_CMF_URL=http://cmf.flink-demo-rbac.confluentdemo.local

# List Flink environments
confluent flink environment list

# List applications
confluent flink application list --environment shapes-env
```

**MinIO (S3-compatible storage):**
- **Console URL**: http://s3-console.flink-demo-rbac.confluentdemo.local
- **S3 API URL**: http://s3.flink-demo-rbac.confluentdemo.local
- **CMF Artifact Management**: enabled, backed by a dedicated `artifacts` bucket (`basePath: s3://artifacts/cmf`)

**Kafka Bootstrap (for direct client access):**
- Kafka is exposed via NodePort at `kafka.flink-demo-rbac.confluentdemo.local:31000`

**Headlamp Kubernetes Dashboard:**
- **URL**: https://headlamp.flink-demo-rbac.confluentdemo.local
- **Auth**: Token-based — generate a token from the chart's ServiceAccount:
  ```bash
  # List ServiceAccounts in the headlamp namespace to confirm the name
  kubectl -n headlamp get sa
  # Generate a token (replace 'headlamp' with the actual SA name if different)
  kubectl -n headlamp create token headlamp
  ```
  Paste the token into the Headlamp login screen. (Keycloak SSO is deferred to a future auth-proxy design — see [ADR-0009](../../adrs/0009-headlamp-dashboard-oidc-access.md).)

### Port-Forwarding (Fallback/Troubleshooting)

While services are accessible via IngressRoutes, port-forwarding can be used for direct access or troubleshooting:

**MDS (if ingress authentication fails):**

```bash
# Port-forward MDS
kubectl port-forward -n kafka svc/kafka 8090:8090

# In another terminal, login
export CONFLUENT_PLATFORM_SSO=true
confluent login --url http://localhost:8090 --no-browser
```

**CMF API (if ingress is unavailable):**

```bash
# Port-forward CMF
kubectl port-forward -n operator svc/cmf-service 8081:80

# Use local URL
export CONFLUENT_CMF_URL=http://localhost:8081/cmf
confluent flink environment list
```

## Cluster Specific Use Cases

### Kafka Resource Naming Conventions

This cluster enforces group-based RBAC for Kafka resources using prefixed naming patterns.

#### Resource Naming Patterns

**Shapes Group Resources:**
- Topics: `shapes-*` (e.g., `shapes-input`, `shapes-output`, `shapes-state`)
- Subjects: `shapes-*` (e.g., `shapes-value`, `shapes-key`)
- Consumer Groups: `shapes-*` (e.g., `shapes-consumer-1`)
- Transactional IDs: `shapes-*` (e.g., `shapes-tx-1`)
- Flink SQL Catalog: `shapes-catalog`
- Flink SQL Database: `shapes-database`

**Colors Group Resources:**
- Topics: `colors-*` (e.g., `colors-input`, `colors-output`, `colors-state`)
- Subjects: `colors-*` (e.g., `colors-value`, `colors-key`)
- Consumer Groups: `colors-*` (e.g., `colors-consumer-1`)
- Transactional IDs: `colors-*` (e.g., `colors-tx-1`)
- Flink SQL Catalog: `colors-catalog`
- Flink SQL Database: `colors-database`

#### RBAC Permissions

Each group has permissions on their group-specific resources:

**Kafka Resources** (`ResourceOwner` role on prefixed resources):
- **Topics:** Create, read, write, delete, and describe
- **Subjects:** Register, update, delete, and view schemas
- **Consumer Groups:** Create and manage consumer groups for Flink applications
- **Transactional IDs:** Use transactions for exactly-once processing

**Flink SQL Resources** (`DeveloperManage` role):
- **KafkaCatalog:** View and manage group-specific catalogs (shapes-catalog, colors-catalog)
- **KafkaDatabase:** View and manage group-specific databases (shapes-database, colors-database)

**Flink Resources** (`DeveloperManage` and `ClusterAdmin` roles):
- **FlinkEnvironment:** Manage group-specific environments
- **FlinkApplication:** Full control over applications in group environment

**Admin User:**
- `SystemAdmin` role on both Kafka cluster and CMF cluster
- Full access to all resources across all groups

**Cross-Group Access:**
- Groups CANNOT access each other's resources
- RBAC enforcement prevents `shapes` group from accessing `colors-*` resources and vice versa

#### Pre-created Topics

The following topics are pre-created via KafkaTopic resources in `workloads/confluent-resources/overlays/flink-demo-rbac/topics.yaml`:

**Shapes topics:**
- `shapes-input` - Input topic (3 partitions, 2-day retention)
- `shapes-output` - Output topic (3 partitions, 2-day retention)
- `shapes-state` - State/changelog topic (3 partitions, compacted)

**Colors topics:**
- `colors-input` - Input topic (3 partitions, 2-day retention)
- `colors-output` - Output topic (3 partitions, 2-day retention)
- `colors-state` - State/changelog topic (3 partitions, compacted)

Users can create additional topics following their group's naming pattern, subject to RBAC permissions.

### Schema Registry Authentication for Flink SQL Catalogs

Each Flink SQL catalog authenticates to Schema Registry with `OAUTHBEARER`, using its group's service account (`sa-shapes-flink` / `sa-colors-flink`). CMF obtains and refreshes tokens itself, so there is nothing to rotate and no sync required to keep a catalog working.

Credentials reach CMF through the declarative chain in `workloads/colors-and-shapes/components/rbac-oauth/flink-secrets.yaml`:

```
Kubernetes Secret -> FlinkSecret -> FlinkEnvironmentSecretMapping -> FlinkKafkaCatalog
```

Two credential pairs exist per environment, and they intentionally use different identities:

| Purpose | Identity | Mapping name |
|---|---|---|
| Schema Registry (catalog) | `sa-<group>-flink` | `sr-conn-secret-id-<group>` |
| Kafka (database) | `cmf` | `kafka-conn-secret-id-<group>` |

Kafka uses the `cmf` service account because CMF validates the database connection while registering a catalog, which needs broader Kafka permissions than the per-group accounts hold.

The `FlinkSecret`, its `FlinkEnvironmentSecretMapping`, and the `connectionSecretId`/`connectionSecretRef` that references them must all share one identical name — see [architecture.md](../../docs/architecture.md#intra-application-sync-waves-flink-sql-resources) for that rule and the rest of the Flink SQL CR constraints.

To rotate a credential, edit the backing Kubernetes Secret. CFK tracks its `resourceVersion` and re-syncs to CMF automatically.

## Troubleshooting

### Enabling CMF secret encryption requires a fresh CMF database

CMF's encryption mode is fixed when its metadata database is first initialized. Per the [CMF encryption docs](https://docs.confluent.io/platform/current/flink/installation/encryption.html), a database initialized with encryption disabled can **never** be switched to enabled (and vice versa), and the encryption key can **never** be rotated.

This matters because the `FlinkSecret` CRD syncs Kubernetes Secrets into CMF's database and requires `encryption.enabled: true`. If CMF already came up with encryption off, flipping the Helm value is not enough — CMF keeps the mode its database was initialized with.

To switch an existing cluster over, reset CMF's database:

CMF fails loudly rather than silently in this state — it crash-loops with:

```
java.lang.IllegalStateException: Cannot change the encryption mode. Previous
state was encryption.enabled=false, current configuration has
encryption.enabled=true. This operation is not allowed for data safety reasons.
```

```bash
# 1. Confirm the encryption key is exactly 16 or 32 bytes. CMF rejects any
#    other length and fails to start.
kubectl get secret cmf-encryption-key --namespace operator \
  --output jsonpath="{.data.key}" | base64 --decode | wc -c   # must print 16 or 32

# 2. Delete the PostgreSQL backing store. This discards all CMF metadata -
#    environments, applications, compute pools, catalogs, and statements. They
#    are all declared in Git, so ArgoCD recreates them.
#
#    NOTE: PostgreSQL is owned by the `cmf-operator-secrets` Application, not
#    `cmf-operator` (which deploys only the Helm chart).
kubectl delete deployment cmf-postgres --namespace operator
kubectl delete pvc cmf-postgres-pvc --namespace operator

# 3. Sync `cmf-operator-secrets` to recreate PostgreSQL. An explicit sync is
#    required: the app runs with selfHeal=false, so a refresh alone will NOT
#    recreate the deleted resources - it will just report them OutOfSync.
argocd app sync cmf-operator-secrets
#    ...or, without the ArgoCD CLI:
kubectl patch application cmf-operator-secrets --namespace argocd --type merge \
  --patch '{"operation":{"sync":{"syncStrategy":{"hook":{}}}}}'

# 4. CMF recovers on its own once PostgreSQL is reachable - no manual restart
#    needed. It crash-loops on connection-refused in the meantime and can take
#    a few minutes to settle.
kubectl get pods --namespace operator --watch

# 5. Confirm the encryption-mode error is gone from the running pod.
kubectl logs deployment/confluent-manager-for-apache-flink \
  --namespace operator | grep -c "Cannot change the encryption mode"   # expect 0
```

Note that the `DATABASE ENCRYPTION FOR SECRETS DISABLED` banner in the CMF docs is Helm `NOTES.txt` output, not pod logs — it is not visible under ArgoCD, so use the checks above instead.

On a local kind cluster it is usually faster to delete and recreate the whole cluster than to run this procedure.

### ArgoCD Applications Not Syncing

Check parent Application health:

```bash
kubectl get application infrastructure-apps --namespace argocd -o yaml
kubectl get application workloads-apps --namespace argocd -o yaml
```

Verify Application manifests exist:

```bash
ls -la ./clusters/flink-demo-rbac/infrastructure/
ls -la ./clusters/flink-demo-rbac/workloads/
```

### Pods Not Starting

Check pod status and events:

```bash
kubectl get pods --namespace <namespace> --output wide
kubectl describe pod <pod-name> --namespace <namespace>
```

Check resource availability:

```bash
kubectl top nodes
kubectl top pods --all-namespaces
```

### Ingress Not Accessible

Verify kind port mappings:

```bash
docker ps | grep flink-demo-rbac
```

Should show port mappings: `0.0.0.0:80->30080/tcp, 0.0.0.0:443->30443/tcp`

Check Traefik IngressRoutes:

```bash
kubectl get ingressroute --all-namespaces
```

### Certificate Issues

Check cert-manager resources:

```bash
kubectl get certificates --all-namespaces
kubectl get certificaterequests --all-namespaces
kubectl get clusterissuers
```

### CFK Components Not Deploying

Check operator logs:

```bash
kubectl logs --namespace operator deployment/confluent-operator --tail=100
```

Verify CRDs installed:

```bash
kubectl get crd | grep platform.confluent.io
```

### Validation Script

Run the comprehensive validation script:

```bash
./scripts/validate-cluster.sh flink-demo-rbac --verbose
```

## Cleanup

Remove the kind cluster:

```bash
kind delete cluster --name flink-demo-rbac
```

Stop the container runtime (if using Colima):

```bash
colima stop
```
