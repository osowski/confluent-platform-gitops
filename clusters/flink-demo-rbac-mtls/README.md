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

The `confluent-resources` and `flink-resources` Applications require manual sync to ensure operators and namespaces are fully ready.

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

### Generate Data

The `flink-resources` Application includes two producer Deployments that write Avro-encoded sensor data to the group input topics. They are deployed with `replicas: 0` by default and must be scaled up to start producing:

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
- **flink-rbac** (wave 100) - Flink RBAC ServiceAccounts and RoleBindings
- **keycloak** (wave 102) - Keycloak identity provider for SSO/OAuth
- **cfk-operator** (wave 105) - Confluent for Kubernetes operator
- **mds-keygen** (wave 106) - MDS token keypair generation
- **confluent-resources** (wave 110) - Confluent Platform (KRaft, Kafka, Schema Registry, MDS, etc.) — **manual sync**
- **ingresses** (wave 110) - Traefik IngressRoutes for all services
- **flink-kubernetes-operator** (wave 116) - Flink Kubernetes Operator
- **observability-resources** (wave 117) - PodMonitors and Grafana dashboards
- **cmf-operator-secrets** (wave 117) - CMF operator secret configuration
- **cmf-operator** (wave 118) - Confluent Manager for Apache Flink
- **flink-resources** (wave 120) - Flink integration resources — **manual sync**

## Environment Access

### DNS Configuration

Add these entries to `/etc/hosts`:

```
127.0.0.1  alertmanager.flink-demo-rbac-mtls.confluentdemo.local
127.0.0.1  argocd.flink-demo-rbac-mtls.confluentdemo.local
127.0.0.1  cmf.flink-demo-rbac-mtls.confluentdemo.local
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

```bash
export CONFLUENT_CMF_URL=http://cmf.flink-demo-rbac-mtls.confluentdemo.local

# List Flink environments
confluent flink environment list

# List applications
confluent flink application list --environment shapes-env
```

**MinIO (S3-compatible storage):**
- **Console URL**: http://s3-console.flink-demo-rbac-mtls.confluentdemo.local
- **S3 API URL**: http://s3.flink-demo-rbac-mtls.confluentdemo.local

**Kafka Bootstrap (for direct client access):**
- Kafka is exposed via NodePort at `kafka.flink-demo-rbac-mtls.confluentdemo.local:31000`

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

### Schema Registry Token Lifecycle (STATIC_TOKEN)

CMF 2.2 does not support `OAUTHBEARER` as a `bearer.auth.credentials.source` in its
embedded Schema Registry client. As a workaround, the sql-init jobs obtain a fresh
OAuth token from Keycloak at runtime and embed it as a `STATIC_TOKEN` in each catalog's
`connectionConfig`.

#### How It Works

1. The `shapes-sql-init` and `colors-sql-init` jobs run as ArgoCD **PostSync hooks**
2. Each job obtains a fresh SR token from Keycloak using team-specific OAuth credentials
   (`sa-shapes-flink` / `sa-colors-flink`)
3. The token is embedded inline in the catalog's `connectionConfig` as `bearer.auth.credentials.source: STATIC_TOKEN`
4. If the catalog already exists, it is updated via PUT with the new token

#### Token Lifetime

- **Default Keycloak token lifetime:** 7 days (604800 seconds), configured in the
  `confluent` realm's client settings
- **Token refresh:** Automatic on every ArgoCD sync of the `flink-resources` application
- **Manual refresh:** Trigger an ArgoCD sync of `flink-resources` to regenerate tokens

#### When Tokens Expire

If a catalog's STATIC_TOKEN expires before the next sync:
- `SHOW TABLES` will continue to work (table listing uses Kafka metadata, not SR)
- `SELECT` queries will fail with "Permission denied to access the Schema Registry"
- **Fix:** Sync `flink-resources` in ArgoCD to refresh the token

#### Adjusting Token Lifetime

To change the token lifetime, update the Keycloak client session settings:
1. Open Keycloak Admin Console (`https://keycloak.flink-demo-rbac-mtls.confluentdemo.local`)
2. Navigate to: Confluent realm > Clients > `sa-shapes-flink` (or `sa-colors-flink`) > Settings
3. Adjust "Client Session Max" or "Access Token Lifespan" under Advanced Settings

#### Future Improvement

When CMF supports `OAUTHBEARER` as a `bearer.auth.credentials.source` in its SR client
(expected in a future CMF release), catalogs should be updated to use `connectionSecretId`
with CMF Secrets instead of inline STATIC_TOKEN. This would eliminate token expiration
concerns entirely. See `cmf-secret-configmaps.yaml` for details.

## Troubleshooting

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
