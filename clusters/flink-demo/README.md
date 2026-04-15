# flink-demo Cluster

Demo cluster for Confluent Platform with Apache Flink integration, showcasing GitOps-based deployment using ArgoCD, Confluent for Kubernetes (CFK), and Confluent Manager for Apache Flink (CMF).

## Overview

The `flink-demo` cluster demonstrates a complete Confluent Platform deployment including:

- **Kafka Cluster**: KRaft-based Kafka with Schema Registry, Control Center, ksqlDB, and Connect
- **Flink Integration**: Flink Kubernetes Operator with CMF for SQL-based stream processing and out-of-box support for [rjmfernandes/cp-flink-sql](https://github.com/rjmfernandes/cp-flink-sql) exercises
- **Monitoring**: Prometheus, Grafana, and Alertmanager with pre-configured dashboards
- **Security**: HashiCorp Vault for secrets management, cert-manager for TLS certificates
- **Networking**: Traefik ingress controller with local DNS resolution

**Domain**: `*.flink-demo.confluentdemo.local`

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
kubectl apply -f clusters/flink-demo/bootstrap.yaml
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

Check Confluent Platform pods:

```bash
kubectl get pods --namespace kafka
```

You should see:
- `controlcenter-0` - Control Center
- `kafka-0`, `kafka-1`, `kafka-2` - Kafka brokers
- `schemaregistry-0` - Schema Registry
- `connect-0` - Kafka Connect
- `ksqldb-0` - ksqlDB server
- `kraft-0`, `kraft-1`, `kraft-2` - KRaft controllers

Check Flink pods:

```bash
kubectl get pods --namespace flink
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

**Sync cp-flink-sql-sandbox (optional):**

To enable the CP Flink SQL demo environment:
1. Click on `cp-flink-sql-sandbox` Application
2. Click **Sync** → **Synchronize**
3. Wait for `Healthy` status (~3-5 minutes)

This deploys topics, schemas, and Flink catalog/compute pool for running Flink SQL queries. See [CP Flink SQL Sandbox](#cp-flink-sql-sandbox) below.

## Applications

### Infrastructure Applications

Infrastructure applications are defined in `infrastructure/kustomization.yaml`:

- **kube-prometheus-stack-crds** (wave 2) - Prometheus Operator CRDs
- **metrics-server** (wave 5) - Kubernetes Metrics Server
- **traefik** (wave 10) - Ingress controller
- **cert-manager** (wave 20) - TLS certificate management
- **kube-prometheus-stack** (wave 20) - Monitoring stack (Prometheus, Grafana, Alertmanager)
- **trust-manager** (wave 30) - CA certificate distribution
- **reflector** (wave 40) - Cross-namespace secret replication for minio-credentials
- **vault** (wave 40) - HashiCorp Vault (dev mode)
- **vault-ingress** (wave 45) - Traefik IngressRoute for Vault UI
- **vault-config** (wave 50) - Vault transit engine configuration
- **cert-manager-resources** (wave 75) - ClusterIssuer and certificates
- **argocd-ingress** (wave 80) - Traefik IngressRoute for ArgoCD UI
- **minio** (wave 85) - S3-compatible object storage for Flink checkpoints and savepoints
- **argocd-config** (wave 85) - ArgoCD ConfigMap patches for custom health checks

### Workload Applications

Workload applications are defined in `workloads/kustomization.yaml`:

- **namespaces** (wave 100) - Namespace definitions (kafka, flink, operator)
- **cfk-operator** (wave 105) - Confluent for Kubernetes operator
- **workload-ingresses** (wave 110) - Traefik IngressRoutes (CMF, Control Center, Schema Registry)
- **confluent-resources** (wave 110) - Confluent Platform (KRaft, Kafka, Schema Registry, etc.) — **manual sync**
- **cp-flink-sql-sandbox** (wave 115) - CP Flink SQL demo environment
- **flink-kubernetes-operator** (wave 116) - Flink Kubernetes Operator
- **observability-resources** (wave 117) - PodMonitors and Grafana dashboards
- **cmf-operator** (wave 118) - Confluent Manager for Apache Flink
- **flink-resources** (wave 120) - Flink integration resources — **manual sync**
- **flink-agents** (wave 121) - Flink Agents workflow demo (LLM-driven review analysis) — **manual sync** — see [Flink Agents README](../../workloads/flink-agents/README.md)
- **ollama** (wave 110) - In-cluster Ollama LLM backend — **disabled** (run Ollama natively on macOS instead; see [Flink Agents README](../../workloads/flink-agents/README.md))

## Environment Access

<!--
INTENTIONAL DUPLICATION: The /etc/hosts entries below are duplicated from
docs/getting-started-for-the-uninitiated.md for quick reference. This is
explicitly allowed as a one-off exception to avoid users jumping between files.
Changes should be kept in sync with the canonical source.
-->

### DNS Configuration

Add these entries to `/etc/hosts`:

```
127.0.0.1  alertmanager.flink-demo.confluentdemo.local
127.0.0.1  argocd.flink-demo.confluentdemo.local
127.0.0.1  cmf.flink-demo.confluentdemo.local
127.0.0.1  controlcenter.flink-demo.confluentdemo.local
127.0.0.1  grafana.flink-demo.confluentdemo.local
127.0.0.1  kafka.flink-demo.confluentdemo.local
127.0.0.1  prometheus.flink-demo.confluentdemo.local
127.0.0.1  s3.flink-demo.confluentdemo.local
127.0.0.1  s3-console.flink-demo.confluentdemo.local
127.0.0.1  schemaregistry.flink-demo.confluentdemo.local
127.0.0.1  vault.flink-demo.confluentdemo.local
```

> [!WARNING]
> If you experience ~5-second timeouts when accessing services, add IPv6 entries as well:
> ```
> ::1  alertmanager.flink-demo.confluentdemo.local
> ::1  argocd.flink-demo.confluentdemo.local
> ::1  cmf.flink-demo.confluentdemo.local
> ::1  controlcenter.flink-demo.confluentdemo.local
> ::1  grafana.flink-demo.confluentdemo.local
> ::1  kafka.flink-demo.confluentdemo.local
> ::1  prometheus.flink-demo.confluentdemo.local
> ::1  s3.flink-demo.confluentdemo.local
> ::1  s3-console.flink-demo.confluentdemo.local
> ::1  schemaregistry.flink-demo.confluentdemo.local
> ::1  vault.flink-demo.confluentdemo.local
> ```

### Services

**ArgoCD UI:**
- **URL**: https://argocd.flink-demo.confluentdemo.local
- **Username**: `admin`
- **Password**: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`

**Control Center:**
- **URL**: https://controlcenter.flink-demo.confluentdemo.local
- **Features**: Cluster monitoring, topic management, schema registry, Connect connectors, ksqlDB queries

**Grafana:**
- **URL**: http://grafana.flink-demo.confluentdemo.local
- **Username**: `admin`
- **Password**: `prom-operator`
- **Pre-configured dashboards**: Kafka Cluster Overview, Kafka Broker Metrics, Schema Registry Metrics, Flink Job Metrics, Kubernetes Cluster Metrics

**Prometheus:**
- **URL**: http://prometheus.flink-demo.confluentdemo.local

**Alertmanager:**
- **URL**: http://alertmanager.flink-demo.confluentdemo.local

**Vault** (dev mode):
- **URL**: http://vault.flink-demo.confluentdemo.local
- **Token**: `root`
- **Warning**: Dev mode - data is not persisted across restarts

**CMF API:**
- **URL**: http://cmf.flink-demo.confluentdemo.local
- **Documentation**: [CMF REST API](https://docs.confluent.io/platform/current/flink/index.html)

**MinIO:**
- **API URL**: http://s3.flink-demo.confluentdemo.local
- **Console URL**: http://s3-console.flink-demo.confluentdemo.local
- **Credentials**: Access Key `admin`, Secret Key `password`
- **Bucket**: `warehouse`
- **Purpose**: Backend storage for Flink state management (checkpoints, savepoints, HA)
- **Cyberduck**: Import the [S3_flink-demo.cyberduckprofile](./cyberduck/S3_flink-demo.cyberduckprofile) connection profile for GUI access

## Cluster Specific Use Cases

### CP Flink SQL Sandbox

The cluster includes an optional **cp-flink-sql-sandbox** application that provides a complete environment for running Flink SQL demos from the [cp-flink-sql](https://github.com/rjmfernandes/cp-flink-sql) repository.

**What's included:**
- **Topics**: `myevent` (source), `myaggregated` (sink)
- **Schemas**: Avro schemas registered in Schema Registry
- **Catalog**: Kafka catalog with automatic topic/schema discovery
- **Compute Pool**: Flink compute pool with S3 checkpoint/savepoint storage

**Getting started:**

After syncing the `cp-flink-sql-sandbox` Application, you can immediately proceed to the "Let's Play" section of the [cp-flink-sql repository](https://github.com/rjmfernandes/cp-flink-sql?tab=readme-ov-file#lets-play).

See **[cp-flink-sql-sandbox README](../../workloads/cp-flink-sql-sandbox/README.md)** for details.

## Troubleshooting

### ArgoCD Applications Not Syncing

Check parent Application health:

```bash
kubectl get application infrastructure-apps --namespace argocd -o yaml
kubectl get application workloads-apps --namespace argocd -o yaml
```

Verify Application manifests exist:

```bash
ls -la ./clusters/flink-demo/infrastructure/
ls -la ./clusters/flink-demo/workloads/
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
docker ps | grep flink-demo
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
./scripts/validate-cluster.sh flink-demo --verbose
```

## Cleanup

Remove the kind cluster:

```bash
kind delete cluster --name flink-demo
```

Stop the container runtime (if using Colima):

```bash
colima stop
```
