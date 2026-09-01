# flink-demo-rbac-mtls Cluster

Demo cluster for Confluent Platform with RBAC-enabled Apache Flink integration, showcasing multi-tenant GitOps deployment with Keycloak SSO, MDS-based authorization, and group-scoped Flink SQL environments.

## Overview

The `flink-demo-rbac-mtls` cluster demonstrates a complete Confluent Platform deployment with RBAC including:

- **Kafka Cluster**: KRaft-based Kafka with Schema Registry, Control Center, and MDS for authorization
- **Flink Integration**: Flink Kubernetes Operator with CMF, group-scoped catalogs and compute pools
- **Monitoring**: Prometheus, Grafana, and Alertmanager with pre-configured dashboards
- **Security**: Keycloak for SSO/OAuth, MDS for RBAC, cert-manager for TLS, Reflector for secret replication, and **mTLS** on the Kafka↔KRaft controller and inter-broker replication paths (see [mTLS](#mtls))
- **Networking**: Traefik ingress controller with local DNS resolution
- **Storage**: MinIO for S3-compatible object storage (Flink checkpoints and savepoints)

**Domain**: `*.flink-demo-rbac-mtls.confluentdemo.local`

## mTLS

This variant layers cert-manager-automated TLS + mutual TLS on top of the existing OIDC/RBAC model. OAuth/OIDC remains the authentication principal for service accounts and human SSO; mTLS is applied to machine-to-machine paths where there is no human identity.

**PKI (cluster-wide):** a self-signed root CA (`rbac-mtls-ca`) backs a CA `ClusterIssuer` (`rbac-mtls-ca-issuer`); cert-manager mints leaf certs and `trust-manager` distributes the CA (`rbac-mtls-ca-bundle`) to namespaces labeled `mtls-trust: enabled`. CFK converts the PEM secrets to PKCS12 internally.

**Current listener security posture:**

| Path | Security | Identity |
|---|---|---|
| KRaft controller listener (quorum) | TLS + mTLS, client certs **required** | cert CN=kafka → `User:kafka` superuser |
| Kafka `REPLICATION` listener (inter-broker, 9072) | TLS + mTLS, client certs **required** | cert CN=kafka → `User:kafka` superuser |
| Kafka `flink-sql-mtls` listener (`secure-sql` Flink SQL tenant, 9095) | TLS + mTLS, client certs **required** | cert CN=secure-sql-mtls → `User:secure-sql-mtls` (scoped, see [ADR-0011](../../adrs/0011-flink-sql-kafka-mtls-cert-manager.md)) |
| Kafka `INTERNAL` listener (SR/C3/CMF clients, 9071) | OAuth over plaintext | Keycloak service accounts |
| Kafka external NodePort (31000) | OAuth over plaintext | Keycloak service accounts |
| Schema Registry API | HTTP in-cluster (TLS at Traefik edge) | OAuth |

- Identity certs: `kraftcontroller-mtls` and `kafka-broker-mtls` (issued by `rbac-mtls-ca-issuer`); the CN maps to the RBAC superuser via `principalMappingRules`, so no extra role bindings are needed for quorum/replication traffic.
- Verify on a running cluster: controller request logs show `securityProtocol: SSL` and `principal User:kafka` (`tokenAuthenticated: false`) on the `CONTROLLER` listener; broker config shows `REPLICATION:SSL` in `listener.security.protocol.map` and `listener.name.replication.ssl.client.auth=required`; under-replicated partitions stay at 0.
- Planned next ([#275](https://github.com/osowski/confluent-platform-gitops/issues/275)): Schema Registry HTTPS + mTLS-to-Kafka; broader client mTLS migration is tracked in the Epic ([#271](https://github.com/osowski/confluent-platform-gitops/issues/271)).

### Certificate renewal — what to expect (safe, automatic)

Routine cert renewal is **not** the same as changing a listener's auth type, and it requires no operator action:

1. cert-manager renews each leaf cert in place at ~2/3 of its 90-day lifetime (same Secret name, new content).
2. CFK tracks every Secret referenced by the Kafka/KRaft CRs; on content change it starts an operator-controlled **rolling restart, one broker at a time**, gated by readiness/URP pre-checks between pods (observed live: `starting kafka roll workflow` → `cluster not rollable from roll pre checks` → waits until replicas are back in sync before the next pod).
3. Clients are unaffected; the new cert chains to the same CA distributed by trust-manager.

To force a renewal for demonstration, prefer **`cmctl renew kafka-broker-mtls -n kafka`** — it is a safe one-shot trigger. If `cmctl` is unavailable, you can instead temporarily patch the Certificate's `renewBefore` close to its `duration`, but **restore it immediately after the roll completes** (re-sync `confluent-resources`): while `renewBefore ≈ duration`, the renewed cert instantly re-qualifies for renewal, so cert-manager re-renews every few minutes and each renewal triggers another full broker roll.

> [!IMPORTANT]
> **Changing a listener's security protocol or auth type (plaintext↔TLS, OAuth↔mTLS) requires a clean redeploy, not an in-place roll.** Brokers/controllers cannot interoperate across a mixed-security window: a partially rolled cluster has peers speaking TLS to peers still serving plaintext (or vice versa), replication/quorum fails between them, and the URP gate halts the roll after the first pod. To (re)apply mTLS listener changes: delete the CFK CRs (`kafka`, `kraftcontroller`, `schemaregistry`, `controlcenter`, `kafkarestclass`) and their PVCs, then re-sync `confluent-resources` so the stack comes up mTLS-from-start. `confluent-resources` is a **manual-sync** ArgoCD application. (Routine cert renewal, above, is safe and automatic — do not tear down for renewals.)

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
kubectl apply -f clusters/flink-demo-rbac-mtls/bootstrap.yaml
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
- **headlamp** (wave 50) - Kubernetes dashboard
- **cert-manager-resources** (wave 75) - ClusterIssuer and certificates
- **infra-ingresses** (wave 80) - Traefik IngressRoutes for ArgoCD and Headlamp UIs
- **argocd-config** (wave 85) - ArgoCD ConfigMap patches for custom health checks
- **minio** (wave 85) - S3-compatible object storage (namespace: storage)

### Workload Applications

Workload applications are defined in `workloads/kustomization.yaml`:

- **namespaces** (wave 100) - Namespace definitions (kafka, flink, operator, keycloak, storage)
- **keycloak** (wave 102) - Keycloak identity provider for SSO/OAuth
- **cfk-operator** (wave 105) - Confluent for Kubernetes operator
- **mds-keygen** (wave 106) - MDS token keypair generation
- **flink-secure-sql-mtls-pki** (wave 108) - `secure-sql` tenant's mTLS client `Certificate`, synced early (and auto-sync, unlike the tenant's main Application below) so its Secret exists — Reflector-mirrored into `operator` — before `cmf-operator`'s own release; see [flink-secure-sql-mtls README](../../workloads/flink-secure-sql-mtls/README.md) and [ADR-0011](../../adrs/0011-flink-sql-kafka-mtls-cert-manager.md)
- **confluent-resources** (wave 110) - Confluent Platform (KRaft, Kafka, Schema Registry, MDS, etc.) — **manual sync**
- **workload-ingresses** (wave 110) - Traefik IngressRoutes for workload UIs
- **flink-kubernetes-operator** (wave 116) - Flink Kubernetes Operator
- **observability-resources** (wave 117) - PodMonitors and Grafana dashboards
- **cmf-operator-secrets** (wave 117) - CMF operator secret configuration
- **cmf-operator** (wave 118) - Confluent Manager for Apache Flink
- **flink-resources** (wave 119) - Core CMFRestClass + single `default` FlinkEnvironment + generic Flink SQL demo, with OAuth layered on via the `oauth` component — **manual sync** — see [Flink Resources README](../../workloads/flink-resources/README.md)
- **colors-and-shapes** (wave 120) - Two-tenant Flink demo (JAR + SQL), with Kubernetes RBAC and Keycloak OAuth layered on via the `rbac-oauth` component — **manual sync** — see [Colors and Shapes README](../../workloads/colors-and-shapes/README.md)
- **flink-secure-sql-mtls** (wave 121) - `secure-sql` tenant's Flink SQL statement, catalog/database/compute-pool chain, and credentials — **manual sync** — see [flink-secure-sql-mtls README](../../workloads/flink-secure-sql-mtls/README.md). Split across two Applications (this one plus `flink-secure-sql-mtls-pki` above); see that README for why.

## Environment Access

### DNS Configuration

Add these entries to `/etc/hosts`. If you're following this guide from a
remote VM with a public IP rather than your own machine, run
`./scripts/generate-hosts-entries.sh flink-demo-rbac-mtls` instead — it
detects that IP for you and points these same hostnames at it.

```
127.0.0.1  alertmanager.flink-demo-rbac-mtls.confluentdemo.local
127.0.0.1  argocd.flink-demo-rbac-mtls.confluentdemo.local
127.0.0.1  cmf.flink-demo-rbac-mtls.confluentdemo.local
127.0.0.1  cmf-ui.flink-demo-rbac-mtls.confluentdemo.local
127.0.0.1  controlcenter.flink-demo-rbac-mtls.confluentdemo.local
127.0.0.1  grafana.flink-demo-rbac-mtls.confluentdemo.local
127.0.0.1  headlamp.flink-demo-rbac-mtls.confluentdemo.local
127.0.0.1  kafka.flink-demo-rbac-mtls.confluentdemo.local
127.0.0.1  kafka-0.flink-demo-rbac-mtls.confluentdemo.local
127.0.0.1  kafka-1.flink-demo-rbac-mtls.confluentdemo.local
127.0.0.1  kafka-2.flink-demo-rbac-mtls.confluentdemo.local
127.0.0.1  keycloak.flink-demo-rbac-mtls.confluentdemo.local
127.0.0.1  mds.flink-demo-rbac-mtls.confluentdemo.local
127.0.0.1  prometheus.flink-demo-rbac-mtls.confluentdemo.local
127.0.0.1  schema-registry.flink-demo-rbac-mtls.confluentdemo.local
127.0.0.1  s3.flink-demo-rbac-mtls.confluentdemo.local
127.0.0.1  s3-console.flink-demo-rbac-mtls.confluentdemo.local
```

> [!WARNING]
> If you experience ~5-second timeouts when accessing services, add IPv6 entries as well:
> ```
> ::1  alertmanager.flink-demo-rbac-mtls.confluentdemo.local
> ::1  argocd.flink-demo-rbac-mtls.confluentdemo.local
> ::1  cmf.flink-demo-rbac-mtls.confluentdemo.local
> ::1  cmf-ui.flink-demo-rbac-mtls.confluentdemo.local
> ::1  controlcenter.flink-demo-rbac-mtls.confluentdemo.local
> ::1  grafana.flink-demo-rbac-mtls.confluentdemo.local
> ::1  headlamp.flink-demo-rbac-mtls.confluentdemo.local
> ::1  kafka.flink-demo-rbac-mtls.confluentdemo.local
> ::1  kafka-0.flink-demo-rbac-mtls.confluentdemo.local
> ::1  kafka-1.flink-demo-rbac-mtls.confluentdemo.local
> ::1  kafka-2.flink-demo-rbac-mtls.confluentdemo.local
> ::1  keycloak.flink-demo-rbac-mtls.confluentdemo.local
> ::1  mds.flink-demo-rbac-mtls.confluentdemo.local
> ::1  prometheus.flink-demo-rbac-mtls.confluentdemo.local
> ::1  schema-registry.flink-demo-rbac-mtls.confluentdemo.local
> ::1  s3.flink-demo-rbac-mtls.confluentdemo.local
> ::1  s3-console.flink-demo-rbac-mtls.confluentdemo.local
> ```

### Services

**ArgoCD UI:**
- **URL**: https://argocd.flink-demo-rbac-mtls.confluentdemo.local
- **Username**: `admin`
- **Password**: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`

**Control Center:**
- **URL**: https://controlcenter.flink-demo-rbac-mtls.confluentdemo.local
- **Username**: `admin@osow.ski` (via Keycloak SSO)
- **Password**: `admin123`

**CMF UI (Flink environments, applications, artifacts):**
- **URL**: https://cmf.flink-demo-rbac-mtls.confluentdemo.local or https://cmf-ui.flink-demo-rbac-mtls.confluentdemo.local (both route to the same backend; browser SSO via Keycloak)
- **Username**: `admin@osow.ski` (redirected to Keycloak on first access)
- **Password**: `admin123`
- CMF's native SSO handles the browser login directly — no reverse proxy involved. Artifact
  upload/management lives in this UI (Control Center has no artifacts page).

**Keycloak Admin Console:**
- **URL**: http://keycloak.flink-demo-rbac-mtls.confluentdemo.local:30080
- **Username**: `flink-admin`
- **Password**: `admin123`

**Grafana:**
- **URL**: http://grafana.flink-demo-rbac-mtls.confluentdemo.local
- **Username**: `admin`
- **Password**: `prom-operator`

**Prometheus:**
- **URL**: http://prometheus.flink-demo-rbac-mtls.confluentdemo.local

**Alertmanager:**
- **URL**: http://alertmanager.flink-demo-rbac-mtls.confluentdemo.local

**MDS (Metadata Service) for CLI Authentication:**

```bash
export CONFLUENT_PLATFORM_SSO=true

# Login via MDS ingress
confluent login --url http://mds.flink-demo-rbac-mtls.confluentdemo.local:80 --no-browser

# Follow device grant flow prompts
```

**CMF API:**

> [!WARNING]
> `http://cmf.flink-demo-rbac.confluentdemo.local` returns a bare 404 — Traefik has no
> route for this host on the `web` entrypoint, so the request never reaches CMF.

```bash
export CONFLUENT_CMF_URL=https://cmf.flink-demo-rbac-mtls.confluentdemo.local

# Extract the CA cert cert-manager generated for cmf-tls
kubectl get secret cmf-tls --namespace operator -o jsonpath='{.data.ca\.crt}' \
  | base64 --decode > /tmp/cmf-ca.crt
# Pass the CA explicitly since the CLI does not support `insecure-skip-verify` flags
export CONFLUENT_CMF_CERTIFICATE_AUTHORITY_PATH=/tmp/cmf-ca.crt

# List Flink environments
confluent flink environment list

# List applications
confluent flink application list --environment shapes-env
```

**MinIO (S3-compatible storage):**
- **Console URL**: http://s3-console.flink-demo-rbac-mtls.confluentdemo.local
- **S3 API URL**: http://s3.flink-demo-rbac-mtls.confluentdemo.local
- **CMF Artifact Management**: enabled, backed by a dedicated `artifacts` bucket (`basePath: s3://artifacts/cmf`)

**Kafka Bootstrap (for direct client access):**
- Kafka is exposed via NodePort at `kafka.flink-demo-rbac-mtls.confluentdemo.local:31000`

**Headlamp Kubernetes Dashboard:**
- **URL**: https://headlamp.flink-demo-rbac-mtls.confluentdemo.local
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
export CONFLUENT_CMF_URL=http://localhost:8081
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

The following topics are pre-created via KafkaTopic resources in `workloads/confluent-resources/overlays/flink-demo-rbac-mtls/topics.yaml`:

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

CMF fixes its encryption mode when its metadata database is first initialized and it cannot be changed afterward, so turning `encryption.enabled` on against a CMF that already came up without it makes CMF crash-loop. The reset procedure is documented once, in the [flink-demo-rbac README](../flink-demo-rbac/README.md#enabling-cmf-secret-encryption-requires-a-fresh-cmf-database), and applies unchanged here.

### ArgoCD Applications Not Syncing

Check parent Application health:

```bash
kubectl get application infrastructure-apps --namespace argocd -o yaml
kubectl get application workloads-apps --namespace argocd -o yaml
```

Verify Application manifests exist:

```bash
ls -la ./clusters/flink-demo-rbac-mtls/infrastructure/
ls -la ./clusters/flink-demo-rbac-mtls/workloads/
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
docker ps | grep flink-demo-rbac-mtls
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
./scripts/validate-cluster.sh flink-demo-rbac-mtls --verbose
```

## Cleanup

Remove the kind cluster:

```bash
kind delete cluster --name flink-demo-rbac-mtls
```

Stop the container runtime (if using Colima):

```bash
colima stop
```
