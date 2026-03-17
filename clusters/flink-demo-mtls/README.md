# flink-demo-mtls Cluster

Demo cluster for Confluent Platform with Apache Flink integration and **comprehensive mTLS authentication**, showcasing GitOps-based deployment using ArgoCD, Confluent for Kubernetes (CFK), and Confluent Manager for Apache Flink (CMF).

## Overview

The `flink-demo-mtls` cluster demonstrates a complete Confluent Platform deployment including:

- **Kafka Cluster**: KRaft-based Kafka with Schema Registry, Control Center, ksqlDB, and Connect
- **Flink Integration**: Flink Kubernetes Operator with CMF for SQL-based stream processing and out-of-box support for [rjmfernandes/cp-flink-sql](https://github.com/rjmfernandes/cp-flink-sql) exercises.
- **Monitoring**: Prometheus, Grafana, and Alertmanager with pre-configured dashboards
- **Security**: HashiCorp Vault for secrets management, cert-manager for TLS certificates, **mTLS authentication for CMF and Flink components**
- **Networking**: Traefik ingress controller with local DNS resolution

**Domain**: `*.flink-demo-mtls.confluentdemo.local`

> [!NOTE]
> **mTLS Security Focus**: This cluster variant demonstrates production-grade mTLS authentication patterns. For a simpler setup without mTLS, see the [`flink-demo`](../flink-demo/README.md) cluster.

## Getting Started

> [!TIP]
> **New to this repository?** Start with the [Getting Started for the Uninitiated](../../docs/getting-started-for-the-uninitiated.md) guide for complete step-by-step setup instructions including:
> - Prerequisites and tool installation
> - DNS configuration (`/etc/hosts` setup with IPv6 timeout workaround)
> - Cluster creation and ArgoCD installation
> - Bootstrap and initial deployment
> - Accessing ArgoCD UI

The sections below provide cluster-specific reference information and advanced configuration.

## Deploy Confluent and Flink Resources

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

## Verify Deployment

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

- **URL**: https://controlcenter.flink-demo-mtls.confluentdemo.local
- **Features**: Cluster monitoring, topic management, schema registry, Connect connectors, ksqlDB queries

### Grafana

Metrics dashboards for monitoring:

- **URL**: http://grafana.flink-demo-mtls.confluentdemo.local
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

- **URL**: http://prometheus.flink-demo-mtls.confluentdemo.local
- **Features**: PromQL queries, target health, alerting rules

### Alertmanager

Alert management and routing:

- **URL**: http://alertmanager.flink-demo-mtls.confluentdemo.local
- **Features**: Active alerts, silences, notification routing

### Vault

Secrets management (dev mode):

- **URL**: http://vault.flink-demo-mtls.confluentdemo.local
- **Token**: `root`
- **Warning**: Dev mode - data is not persisted across restarts

### CMF API

Confluent Manager for Apache Flink REST API:

- **URL**: https://cmf.flink-demo-mtls.confluentdemo.local
- **Authentication**: mTLS (client certificate required)
- **Features**: Flink SQL statement execution, catalog/database/compute pool management
- **Documentation**: [CMF REST API](https://docs.confluent.io/platform/current/flink/index.html)

> [!NOTE]
> **mTLS Authentication**: This cluster uses mTLS for CMF API access. Client certificates are automatically configured for internal components. See [mTLS Configuration](#mtls-configuration) for details.

### S3proxy

S3-compatible object storage for Flink checkpoints and savepoints:

- **URL**: http://s3proxy.flink-demo-mtls.confluentdemo.local
- **Credentials**: Access Key `admin`, Secret Key `password`
- **Bucket**: `warehouse`
- **Purpose**: Backend storage for Flink state management

**Cyberduck Connection Profile:**

To connect via Cyberduck GUI, download and import the S3 connection profile. Double-click the file or manually install it to your Cyberduck Profiles directory.

## CP Flink SQL Sandbox

The cluster includes an optional **cp-flink-sql-sandbox** application that provides a complete environment for running Flink SQL demos from the [https://github.com/rjmfernandes/cp-flink-sql](https://github.com/rjmfernandes/cp-flink-sql) repository.

**What's included:**
- **Topics**: `myevent` (source), `myaggregated` (sink)
- **Schemas**: Avro schemas registered in Schema Registry
- **Catalog**: Kafka catalog with automatic topic/schema discovery
- **Compute Pool**: Flink compute pool with S3 checkpoint/savepoint storage

**Getting started:**

After syncing the `cp-flink-sql-sandbox` Application, you can immediately proceed to the "Let's Play" section of the [cp-flink-sql repository](https://github.com/rjmfernandes/cp-flink-sql?tab=readme-ov-file#lets-play).

See **[cp-flink-sql-sandbox README](../../workloads/cp-flink-sql-sandbox/README.md)** for details.

## mTLS Configuration

This cluster variant demonstrates comprehensive mTLS (mutual TLS) authentication for Confluent Flink components, showcasing production-grade security patterns for GitOps deployments.

> **For Operators**: See [MTLS_IMPLEMENTATION.md](./MTLS_IMPLEMENTATION.md) for detailed deployment procedures, testing, troubleshooting, and rollback instructions.

### What is mTLS?

Mutual TLS (mTLS) provides bidirectional authentication where both the client and server verify each other's identities using X.509 certificates. This ensures:

- **Authentication**: Both parties prove their identity
- **Encryption**: Communication is encrypted end-to-end
- **Integrity**: Messages cannot be tampered with in transit

### Current Implementation (Phase 2)

**Implemented Components:**
- ✅ CMF service mTLS (HTTPS with client certificate verification)
- ✅ Confluent Flink CLI mTLS (CLI commands use client certificates)
- ✅ CFK operator mTLS (CFK authenticates to CMF using certificates)
- ✅ ArgoCD hook jobs mTLS (initialization jobs use client certificates)

**Certificate Infrastructure:**

| Certificate | Namespace | Validity | Purpose |
|-------------|-----------|----------|---------|
| Root CA | `cert-manager` | 10 years | Self-signed CA for signing all certificates |
| CMF Server Cert | `operator` | 90 days | Server certificate for CMF HTTPS endpoint |
| CMF Client Cert | `flink` | 90 days | Client certificate for Flink CLI and CFK |

All certificates auto-renew 30 days before expiry via cert-manager.

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│ cert-manager namespace                                   │
├─────────────────────────────────────────────────────────┤
│ - CA Certificate (cmf-root-ca)                          │
│ - CA Secret (cmf-root-ca) ← ClusterIssuer references    │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│ ClusterIssuer (cluster-scoped)                          │
├─────────────────────────────────────────────────────────┤
│ name: cmf-ca-issuer                                     │
│ secretName: cmf-root-ca (in cert-manager namespace)     │
└─────────────────────────────────────────────────────────┘
         ↓                                  ↓
┌──────────────────────┐         ┌──────────────────────┐
│ operator namespace   │         │ flink namespace      │
│ - Server Certificate │         │ - Client Certificate │
│ - Secret: cmf-server │         │ - Secret: cmf-client │
│ - Label: cmf-mtls    │         │ - Label: cmf-mtls    │
└──────────────────────┘         └──────────────────────┘
         ↓                                  ↓
┌──────────────────────┐         ┌──────────────────────┐
│ ConfigMap:           │         │ ConfigMap:           │
│   cmf-ca-bundle      │         │   cmf-ca-bundle      │
│ (via trust-manager)  │         │ (via trust-manager)  │
└──────────────────────┘         └──────────────────────┘
         ↓                                  ↓
┌──────────────────────┐         ┌──────────────────────┐
│ CMF Service          │         │ Flink CLI / CFK      │
│ - HTTPS:443          │ ←mTLS→  │ - Client auth        │
│ - Server cert mount  │         │ - Client cert mount  │
└──────────────────────┘         └──────────────────────┘
```

### How It Works

**1. Certificate Infrastructure (flink-resources overlay)**

The `workloads/flink-resources/overlays/flink-demo-mtls` overlay creates cluster-wide certificate infrastructure:

- **ClusterIssuer**: Signs certificates across namespaces (no secret syncing needed)
- **Root CA**: Self-signed CA in `cert-manager` namespace
- **Server Certificate**: For CMF service TLS termination
- **Client Certificate**: For Flink CLI and CFK authentication
- **Trust Bundle**: Distributes CA certificate to labeled namespaces via trust-manager

**2. CMF Service Configuration (cmf-operator overlay)**

The `workloads/cmf-operator/overlays/flink-demo-mtls` overlay configures CMF to require client certificates:

```yaml
cmf:
  authentication:
    type: mtls
mountedVolumes:
  volumes:
    - name: cmf-server-tls
      secret:
        secretName: cmf-server-tls
```

**3. Hook Job Patches (cp-flink-sql-sandbox overlay)**

The `workloads/cp-flink-sql-sandbox/overlays/flink-demo-mtls` overlay patches hook jobs using strategic merge:

- Changes endpoint from HTTP:80 to HTTPS:443
- Adds `wait-for-certificates` initContainer
- Mounts client certificates and CA bundle
- Updates `confluent flink` commands with `--cacert`, `--cert`, `--key` flags

**4. Trust Distribution**

trust-manager automatically distributes the CA certificate as ConfigMaps to namespaces labeled with `cmf-mtls: enabled`:

```bash
kubectl get namespace operator -o jsonpath='{.metadata.labels.cmf-mtls}'
# Output: enabled
```

### Design Decisions

**Why ClusterIssuer?**
- Eliminates need for secret syncing tools (Reflector, kubed)
- Simpler architecture (one issuer vs multiple)
- More GitOps-friendly (cluster-scoped resources)
- Certificates signed across namespaces without replication

**Why separate certificate infrastructure?**
- Certificates are cluster-wide, not workload-specific
- Multiple workloads can consume same certificates
- Clearer separation of concerns (infrastructure vs workload)
- Easier to extend to other Flink workloads

**Why strategic merge patches?**
- Base resources remain cluster-agnostic (HTTP, no auth)
- Overlays add mTLS without modifying base
- Other clusters (flink-demo) use base without mTLS
- Clean separation enables testing both variants

### Verifying mTLS

Quick verification after deployment:

```bash
# 1. Verify certificates are ready
kubectl get certificates -A | grep cmf
# All should show "True" in READY column

# 2. Verify trust bundles exist
kubectl get configmap cmf-ca-bundle -n operator
kubectl get configmap cmf-ca-bundle -n flink

# 3. Verify hook jobs completed successfully
kubectl get jobs -n flink
# Both cmf-catalog-database-init and cmf-compute-pool-init should show "1/1" completions

# 4. Check hook job logs for successful mTLS authentication
kubectl logs -n flink -l job-name=cmf-catalog-database-init | grep -i "created\|success"

# 5. Test mTLS connection to CMF
kubectl run -n flink test-mtls \
  --image=curlimages/curl --rm -it -- \
  curl -v \
    --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    https://cmf-service.operator.svc.cluster.local:443/health
```

### Future Enhancements (Planned)

- **Phase 3**: Kafka broker mTLS (inter-broker and client authentication) - [Issue #73](https://github.com/osowski/confluent-platform-gitops/issues/73)
- **Phase 4**: Schema Registry mTLS - [Issue #74](https://github.com/osowski/confluent-platform-gitops/issues/74)
- **Phase 5**: Complete component mTLS (Control Center, Connect, ksqlDB) - [Issue #75](https://github.com/osowski/confluent-platform-gitops/issues/75)

See [Issue #71](https://github.com/osowski/confluent-platform-gitops/issues/71) for overall implementation roadmap.

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
ls -la ./clusters/flink-demo-mtls/infrastructure/
ls -la ./clusters/flink-demo-mtls/workloads/
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
docker ps | grep flink-demo-mtls
```

Should show port mappings: `0.0.0.0:80->30080/tcp, 0.0.0.0:443->30443/tcp`

Check Traefik IngressRoutes:

```bash
kubectl get ingressroute --all-namespaces
```

Verify /etc/hosts entries:

```bash
grep flink-demo-mtls /etc/hosts
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

Check cert-manager logs:

```bash
kubectl logs -n cert-manager -l app=cert-manager --tail=100
```

### mTLS Connection Issues

Check CMF service is using HTTPS:

```bash
kubectl get svc cmf-service -n operator -o yaml
```

Verify client certificates exist:

```bash
kubectl get secret cmf-client-tls -n flink
kubectl get secret cmf-server-tls -n operator
```

Check CMF logs for TLS errors:

```bash
kubectl logs -n operator -l app.kubernetes.io/name=confluent-manager-for-apache-flink --tail=100
```

Test certificate chain:

```bash
# Verify client certificate
kubectl get secret cmf-client-tls -n flink -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout

# Verify server certificate
kubectl get secret cmf-server-tls -n operator -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout
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
./scripts/validate-cluster.sh flink-demo-mtls --verbose
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
kind delete cluster --name flink-demo-mtls
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
- **Run Flink SQL Demos**: See [cp-flink-sql-sandbox README](../../workloads/cp-flink-sql-sandbox/README.md)
- **Extend mTLS**: See [Issue #71](https://github.com/osowski/confluent-platform-gitops/issues/71) for future mTLS phases

## Related Documentation

- [Getting Started for the Uninitiated](../../docs/getting-started-for-the-uninitiated.md) - Step-by-step setup guide
- [Bootstrap Procedure](../../docs/bootstrap-procedure.md) - Detailed bootstrap process
- [Cluster Onboarding](../../docs/cluster-onboarding.md) - Onboarding new clusters
- [Architecture](../../docs/architecture.md) - System design and data flow
- [Confluent Platform](../../docs/confluent-platform.md) - CFK deployment details
- [Release Process](../../docs/release-process.md) - Versioning and releases
