# flink-demo Cluster

Demo cluster for Confluent Platform with Apache Flink integration, showcasing GitOps-based deployment using ArgoCD, Confluent for Kubernetes (CFK), and Confluent Manager for Apache Flink (CMF).

## Overview

The `flink-demo` cluster demonstrates a complete Confluent Platform deployment including:

- **Kafka Cluster**: KRaft-based Kafka with Schema Registry, Control Center, ksqlDB, and Connect
- **Flink Integration**: Flink Kubernetes Operator with CMF for SQL-based stream processing
- **Monitoring**: Prometheus, Grafana, and Alertmanager with pre-configured dashboards
- **Security**: HashiCorp Vault for secrets management, cert-manager for TLS certificates
- **Networking**: Traefik ingress controller with local DNS resolution

**Domain**: `*.flink-demo.confluentdemo.local`

## Prerequisites

### Required Tools

Install via Homebrew (macOS):

```bash
brew install \
    colima \
    kind \
    kubectl \
    kubectx \
    yq
```

**Tool descriptions:**
- `colima` - Container runtime for macOS (provides Docker environment for kind)
- `kind` - Kubernetes in Docker (creates local Kubernetes cluster)
- `kubectl` - Kubernetes CLI for cluster management
- `kubectx` - Context switcher for kubectl (simplifies multi-cluster workflows)
- `yq` - YAML processor (used by validation scripts)

### DNS Configuration

Add the following entries to `/etc/hosts` (all pointing to `127.0.0.1`):

```
127.0.0.1  argocd.flink-demo.confluentdemo.local
127.0.0.1  vault.flink-demo.confluentdemo.local
127.0.0.1  controlcenter.flink-demo.confluentdemo.local
127.0.0.1  grafana.flink-demo.confluentdemo.local
127.0.0.1  prometheus.flink-demo.confluentdemo.local
127.0.0.1  alertmanager.flink-demo.confluentdemo.local
127.0.0.1  cmf.flink-demo.confluentdemo.local
127.0.0.1  s3proxy.flink-demo.confluentdemo.local
```

**To edit /etc/hosts:**

```bash
sudo vim /etc/hosts
# or
sudo nano /etc/hosts
```

## Quick Start

### 1. Checkout a Release

**Important**: Check out a tagged release for stable deployment. Staying on `main` tracks HEAD with in-progress changes.

```bash
# List available releases
git tag --sort=-v:refname

# Checkout latest stable release
git checkout <latest-tag>   # e.g., git checkout v0.4.0
```

See [Release Process](../../docs/release-process.md) for versioning details.

### 2. Start Container Runtime

Start Colima with sufficient resources for the demo cluster:

```bash
colima start --arch arm64 --memory 16 --cpu 8 --disk 256
```

**Resource allocation notes:**
- Memory: 16GB recommended for full stack (minimum 12GB)
- CPU: 8 cores recommended (minimum 6)
- Disk: 256GB allocated to container storage

**For Intel/AMD systems**, use:
```bash
colima start --arch x86_64 --memory 16 --cpu 8 --disk 256
```

### 3. Create Kubernetes Cluster

Create the kind cluster using the provided configuration:

```bash
kind create cluster --config ./clusters/flink-demo/kind-config.yaml --name flink-demo
```

The [kind-config.yaml](./kind-config.yaml) configures:
- Extra port mappings for ingress (80/443 → 30080/30443)
- Node labels for workload placement
- Resource quotas and pod security

### 4. Set Kubernetes Context

Select the flink-demo cluster context:

```bash
kubectx kind-flink-demo
```

Verify context:
```bash
kubectl config current-context
# Should output: kind-flink-demo
```

### 5. Install ArgoCD

Create the ArgoCD namespace:

```bash
kubectl create namespace argocd
```

Install ArgoCD using the official upstream manifest:

```bash
kubectl apply --namespace argocd --server-side --force-conflicts \
  --filename https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Wait for ArgoCD pods to be ready:

```bash
kubectl wait pods --namespace argocd --all --for=condition=Ready --timeout=300s
```

### 6. Bootstrap the Cluster

Apply the cluster bootstrap manifest:

```bash
kubectl apply --filename ./clusters/flink-demo/bootstrap.yaml
```

**What happens next:**
1. ArgoCD creates `infrastructure` and `workloads` parent Applications
2. Parent Applications discover all Application manifests in `clusters/flink-demo/`
3. Child Applications deploy infrastructure components (sync waves 1-99)
4. Child Applications deploy workload components (sync waves 100+)

**Deployment order** (via sync waves):
- Wave 2: Prometheus Operator CRDs
- Wave 5: Metrics Server
- Wave 10: Traefik ingress controller
- Wave 20: Prometheus, cert-manager
- Wave 30: Trust Manager
- Wave 40: Vault
- Wave 50: Vault configuration
- Wave 75: Certificate resources
- Wave 80: ArgoCD ingress
- Wave 85: ArgoCD config
- Wave 100: Namespaces
- Wave 105: CFK operator
- Wave 106: S3proxy
- Wave 110: CMF ingress
- Wave 115: Control Center ingress
- Wave 116: Flink Kubernetes Operator
- Wave 117: Observability resources
- Wave 118: CMF operator
- Wave 120: Flink resources

### 7. Access ArgoCD UI

Retrieve the initial admin password:

```bash
kubectl get secret --namespace argocd argocd-initial-admin-secret \
  --output jsonpath='{.data.password}' | base64 -d | pbcopy
```

**Alternative without clipboard:**
```bash
kubectl get secret --namespace argocd argocd-initial-admin-secret \
  --output jsonpath='{.data.password}' | base64 -d
```

Open ArgoCD in your browser:

- **URL**: https://argocd.flink-demo.confluentdemo.local
- **Username**: `admin`
- **Password**: paste from clipboard

**Note**: ArgoCD uses a self-signed certificate. Accept the security warning in your browser.

You should see the `bootstrap`, `infrastructure-apps`, and `workloads-apps` Applications syncing.

### 8. Deploy Confluent and Flink Resources

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

### 9. Verify Deployment

Check all Applications are healthy:

```bash
kubectl get applications --namespace argocd
```

All should show `Synced` and `Healthy`.

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

## Access Applications

### Control Center

Web UI for managing Confluent Platform:

- **URL**: https://controlcenter.flink-demo.confluentdemo.local
- **Features**: Cluster monitoring, topic management, schema registry, Connect connectors, ksqlDB queries

### Grafana

Metrics dashboards for monitoring:

- **URL**: http://grafana.flink-demo.confluentdemo.local
- **Username**: `admin`
- **Password**: `prom-operator`

**Pre-configured dashboards:**
- Kafka Cluster Overview
- Kafka Broker Metrics
- Schema Registry Metrics
- Flink Job Metrics
- Kubernetes Cluster Metrics

### Prometheus

Raw metrics and query interface:

- **URL**: http://prometheus.flink-demo.confluentdemo.local
- **Features**: PromQL queries, target health, alerting rules

### Alertmanager

Alert management and routing:

- **URL**: http://alertmanager.flink-demo.confluentdemo.local
- **Features**: Active alerts, silences, notification routing

### Vault

Secrets management (dev mode):

- **URL**: http://vault.flink-demo.confluentdemo.local
- **Token**: `root`
- **Warning**: Dev mode - data is not persisted across restarts

### CMF API

Confluent Manager for Apache Flink REST API:

- **URL**: http://cmf.flink-demo.confluentdemo.local
- **Features**: Flink SQL statement execution, catalog/database/compute pool management
- **Documentation**: [CMF REST API](https://docs.confluent.io/platform/current/flink/index.html)

### S3proxy

S3-compatible object storage for Flink checkpoints and savepoints:

- **URL**: http://s3proxy.flink-demo.confluentdemo.local
- **Credentials**: Access Key `admin`, Secret Key `password`
- **Bucket**: `warehouse`
- **Purpose**: Backend storage for Flink state management

## CP Flink SQL Sandbox

The cluster includes an optional **cp-flink-sql-sandbox** application that provides a complete environment for running Flink SQL demos.

**What's included:**
- **Topics**: `myevent` (source), `myaggregated` (sink)
- **Schemas**: Avro schemas registered in Schema Registry
- **Catalog**: Kafka catalog with automatic topic/schema discovery
- **Compute Pool**: Flink compute pool with S3 checkpoint/savepoint storage

**Getting started:**

After syncing the `cp-flink-sql-sandbox` Application, you can immediately proceed to the "Let's Play" section of the [cp-flink-sql repository](https://github.com/rjmfernandes/cp-flink-sql?tab=readme-ov-file#lets-play).

**Important differences from the upstream repo:**
- Use Ingress endpoints instead of port-forwarding
- CMF API: `http://cmf.flink-demo.confluentdemo.local`
- S3proxy: `http://s3proxy.flink-demo.confluentdemo.local`

See [cp-flink-sql-sandbox README](../../workloads/cp-flink-sql-sandbox/base/README.md) for details.

## Cluster Configuration

### Infrastructure Components

| Component | Chart Version | Namespace | Sync Wave | Auto-Sync |
|-----------|---------------|-----------|-----------|-----------|
| kube-prometheus-stack-crds | 66.3.1 | kube-prometheus-stack | 2 | Yes |
| metrics-server | 3.12.2 | kube-system | 5 | Yes |
| traefik | 33.2.0 | traefik | 10 | Yes |
| kube-prometheus-stack | 66.3.1 | kube-prometheus-stack | 20 | Yes |
| cert-manager | 1.16.2 | cert-manager | 20 | Yes |
| trust-manager | 0.13.0 | cert-manager | 30 | Yes |
| vault | 0.31.0 | vault | 40 | Yes |
| vault-config | - | vault | 50 | Yes |
| cert-manager-resources | - | cert-manager | 75 | Yes |
| argocd-ingress | - | argocd | 80 | Yes |
| argocd-config | - | argocd | 85 | Yes |

### Workload Components

| Component | Chart Version | Namespace | Sync Wave | Auto-Sync |
|-----------|---------------|-----------|-----------|-----------|
| namespaces | - | - | 100 | Yes |
| cfk-operator | 0.1351.59 | operator | 105 | Yes |
| s3proxy | - | flink | 106 | Yes |
| cmf-ingress | - | operator | 110 | Yes |
| confluent-resources | - | kafka | 110 | **No** |
| controlcenter-ingress | - | kafka | 115 | Yes |
| cp-flink-sql-sandbox | - | flink | 115 | Yes |
| flink-kubernetes-operator | 1.130.2 | operator | 116 | Yes |
| observability-resources | - | - | 117 | Yes |
| cmf-operator | 2.2.0 | operator | 118 | Yes |
| flink-resources | - | flink | 120 | **No** |

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

Verify /etc/hosts entries:

```bash
grep flink-demo /etc/hosts
```

### Certificate Issues

Check cert-manager resources:

```bash
kubectl get certificates --all-namespaces
kubectl get certificaterequests --all-namespaces
kubectl get clusterissuers
```

Describe failing certificate:

```bash
kubectl describe certificate <cert-name> --namespace <namespace>
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

Check resource status:

```bash
kubectl get kafka,kraft,schemaregistry,controlcenter --namespace kafka
```

### Validation Script

Run the comprehensive validation script:

```bash
./scripts/validate-cluster.sh flink-demo --verbose
```

This checks:
- YAML syntax
- Kustomize builds
- Helm templates
- Sync wave ordering
- AppProject permissions
- Common misconfigurations

## Cleanup

### Delete Cluster

Remove the kind cluster:

```bash
kind delete cluster --name flink-demo
```

### Stop Colima

Stop the container runtime:

```bash
colima stop
```

## Next Steps

- **Add Applications**: See [Adding Applications](../../docs/adding-applications.md)
- **Customize Infrastructure**: See [Adoption Guide](../../docs/adoption-guide.md)
- **Fork Repository**: See [Fork Customization Guide](../../docs/adoption-guide.md#path-5-fork-customization-guide)
- **Understand Architecture**: See [Architecture](../../docs/architecture.md)
- **Run Flink SQL Demos**: See [cp-flink-sql-sandbox README](../../workloads/cp-flink-sql-sandbox/base/README.md)

## Related Documentation

- [Getting Started for the Uninitiated](../../docs/getting-started-for-the-uninitiated.md) - Step-by-step setup guide
- [Bootstrap Procedure](../../docs/bootstrap-procedure.md) - Detailed bootstrap process
- [Cluster Onboarding](../../docs/cluster-onboarding.md) - Onboarding new clusters
- [Architecture](../../docs/architecture.md) - System design and data flow
- [Confluent Platform](../../docs/confluent-platform.md) - CFK deployment details
- [Release Process](../../docs/release-process.md) - Versioning and releases
