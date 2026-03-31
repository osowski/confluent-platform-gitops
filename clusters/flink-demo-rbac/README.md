# flink-demo-rbac Cluster

## Overview

- **Cluster Name:** flink-demo-rbac
- **Domain:** confluentdemo.local
- **Bootstrap:** `bootstrap.yaml`

## Quick Start

### Prerequisites

- Kubernetes cluster with ArgoCD installed
- `kubectl` configured with cluster access

### Deploy Bootstrap

```bash
kubectl apply -f clusters/flink-demo-rbac/bootstrap.yaml
```

### Verify Deployment

```bash
# Check bootstrap application
kubectl get application bootstrap -n argocd

# Check parent applications
kubectl get applications -n argocd

# Watch sync progress
kubectl get applications -n argocd -w
```

## Applications

This cluster includes all infrastructure and workload applications from the reference `flink-demo` cluster.
Remove any applications you don't need by deleting the files and removing them from the kustomization.yaml files.

### Infrastructure Applications

Infrastructure applications are defined in `infrastructure/kustomization.yaml`:

- **argocd-config** (wave 85) - ArgoCD ConfigMap patches for custom health checks
- **argocd-ingress** (wave 80) - Traefik IngressRoute for ArgoCD UI
- **cert-manager** (wave 20) - TLS certificate management
- **cert-manager-resources** (wave 75) - ClusterIssuer and certificates
- **kube-prometheus-stack-crds** (wave 2) - Prometheus Operator CRDs
- **kube-prometheus-stack** (wave 20) - Monitoring stack (Prometheus, Grafana, Alertmanager)
- **metrics-server** (wave 5) - Kubernetes Metrics Server
- **traefik** (wave 10) - Ingress controller
- **trust-manager** (wave 30) - CA certificate distribution
- **vault** (wave 40) - HashiCorp Vault (dev mode)
- **vault-ingress** (wave 45) - Traefik IngressRoute for Vault UI
- **vault-config** (wave 50) - Vault transit engine configuration

### Workload Applications

Workload applications are defined in `workloads/kustomization.yaml`:

- **namespaces** (wave 100) - Namespace definitions (kafka, flink, operator)
- **cfk-operator** (wave 105) - Confluent for Kubernetes operator
- **confluent-resources** (wave 110) - Confluent Platform (KRaft, Kafka, Schema Registry, etc.)
- **controlcenter-ingress** (wave 115) - Traefik IngressRoute for Control Center UI
- **flink-kubernetes-operator** (wave 116) - Flink Kubernetes Operator
- **observability-resources** (wave 117) - PodMonitors and Grafana dashboards
- **cmf-operator** (wave 118) - Confluent Manager for Apache Flink
- **flink-resources** (wave 120) - Flink integration resources

## Access

### Required /etc/hosts Entries

Add these entries to `/etc/hosts` for local DNS resolution:

```bash
sudo tee -a /etc/hosts << 'EOF'
127.0.0.1  alertmanager.flink-demo-rbac.confluentdemo.local
127.0.0.1  argocd.flink-demo-rbac.confluentdemo.local
127.0.0.1  controlcenter.flink-demo-rbac.confluentdemo.local
127.0.0.1  cmf.flink-demo-rbac.confluentdemo.local
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
::1        alertmanager.flink-demo-rbac.confluentdemo.local
::1        argocd.flink-demo-rbac.confluentdemo.local
::1        controlcenter.flink-demo-rbac.confluentdemo.local
::1        cmf.flink-demo-rbac.confluentdemo.local
::1        grafana.flink-demo-rbac.confluentdemo.local
::1        headlamp.flink-demo-rbac.confluentdemo.local
::1        kafka.flink-demo-rbac.confluentdemo.local
::1        kafka-0.flink-demo-rbac.confluentdemo.local
::1        kafka-1.flink-demo-rbac.confluentdemo.local
::1        kafka-2.flink-demo-rbac.confluentdemo.local
::1        keycloak.flink-demo-rbac.confluentdemo.local
::1        mds.flink-demo-rbac.confluentdemo.local
::1        prometheus.flink-demo-rbac.confluentdemo.local
::1        schema-registry.flink-demo-rbac.confluentdemo.local
::1        s3.flink-demo-rbac.confluentdemo.local
::1        s3-console.flink-demo-rbac.confluentdemo.local
> ```


### Services via IngressRoute

All services are exposed through Traefik IngressRoutes (preferred method):

**ArgoCD UI:**
```bash
# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Access at: https://argocd.flink-demo-rbac.confluentdemo.local
# Username: admin
```

**Control Center UI:**
```bash
# Access at: https://controlcenter.flink-demo-rbac.confluentdemo.local
# Username: admin@osow.ski (via Keycloak SSO)
# Password: admin123
```

**Keycloak Admin Console:**
```bash
# Access at: http://keycloak.flink-demo-rbac.confluentdemo.local:30080
# Username: flink-admin
# Password: admin123
```

**MDS (Metadata Service) for CLI Authentication:**
```bash
export CONFLUENT_PLATFORM_SSO=true

# Login via MDS ingress
confluent login --url http://mds.flink-demo-rbac.confluentdemo.local:80 --no-browser

# Follow device grant flow prompts
```

> [!WARNING]
> You must currently replace `http` with `https` and remove the port `:8080` from the auto-generated link when pasting into your browser.
> This will be corrected in a future update.

**Confluent Manager for Apache Flink (CMF) API:**
```bash
export CONFLUENT_CMF_URL=http://cmf.flink-demo-rbac.confluentdemo.local

# List Flink environments
confluent flink environment list

# List applications
confluent flink application list --environment shapes-env
```

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

**Kafka Bootstrap (for direct client access):**
```bash
# Kafka is also exposed via NodePort at 31000
# Bootstrap: kafka.flink-demo-rbac.confluentdemo.local:31000
```

## Kafka Resource Naming Conventions

This cluster enforces group-based RBAC for Kafka resources using prefixed naming patterns.

### Resource Naming Patterns

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

### RBAC Permissions

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

### Pre-created Topics

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

## Schema Registry Token Lifecycle (STATIC_TOKEN)

CMF 2.2 does not support `OAUTHBEARER` as a `bearer.auth.credentials.source` in its
embedded Schema Registry client. As a workaround, the sql-init jobs obtain a fresh
OAuth token from Keycloak at runtime and embed it as a `STATIC_TOKEN` in each catalog's
`connectionConfig`.

### How It Works

1. The `shapes-sql-init` and `colors-sql-init` jobs run as ArgoCD **PostSync hooks**
2. Each job obtains a fresh SR token from Keycloak using team-specific OAuth credentials
   (`sa-shapes-flink` / `sa-colors-flink`)
3. The token is embedded inline in the catalog's `connectionConfig` as `bearer.auth.credentials.source: STATIC_TOKEN`
4. If the catalog already exists, it is updated via PUT with the new token

### Token Lifetime

- **Default Keycloak token lifetime:** 7 days (604800 seconds), configured in the
  `confluent` realm's client settings
- **Token refresh:** Automatic on every ArgoCD sync of the `flink-resources` application
- **Manual refresh:** Trigger an ArgoCD sync of `flink-resources` to regenerate tokens

### When Tokens Expire

If a catalog's STATIC_TOKEN expires before the next sync:
- `SHOW TABLES` will continue to work (table listing uses Kafka metadata, not SR)
- `SELECT` queries will fail with "Permission denied to access the Schema Registry"
- **Fix:** Sync `flink-resources` in ArgoCD to refresh the token

### Adjusting Token Lifetime

To change the token lifetime, update the Keycloak client session settings:
1. Open Keycloak Admin Console (`https://keycloak.flink-demo-rbac.confluentdemo.local`)
2. Navigate to: Confluent realm > Clients > `sa-shapes-flink` (or `sa-colors-flink`) > Settings
3. Adjust "Client Session Max" or "Access Token Lifespan" under Advanced Settings

### Future Improvement

When CMF supports `OAUTHBEARER` as a `bearer.auth.credentials.source` in its SR client
(expected in a future CMF release), catalogs should be updated to use `connectionSecretId`
with CMF Secrets instead of inline STATIC_TOKEN. This would eliminate token expiration
concerns entirely. See `cmf-secret-configmaps.yaml` for details.

## Customization

This cluster was created using `scripts/new-cluster.sh`. Customize by:

1. Adding applications to `infrastructure/kustomization.yaml`
2. Adding applications to `workloads/kustomization.yaml`
3. Creating cluster-specific overlays in `infrastructure/` and `workloads/`

See [Cluster Onboarding](../../docs/cluster-onboarding.md) for detailed guidance.
