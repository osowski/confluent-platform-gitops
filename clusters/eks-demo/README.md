# eks-demo Cluster



## Overview

The `eks-demo` cluster provides:

- **Kafka Cluster**: 
- **Flink Integration**: 
- **Monitoring**: Prometheus, Grafana, and Alertmanager with pre-configured dashboards
- **Security**: 
- **Networking**: Traefik ingress controller with local DNS resolution

**Domain**: `*.eks-demo.platform.dspdemos.com`

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
kubectl apply -f clusters/eks-demo/bootstrap.yaml
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

<!-- Customize this section for applications that require manual sync in this cluster -->

Some applications require manual sync to ensure operators and namespaces are fully ready.

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

<!-- Add any additional manual sync steps specific to this cluster -->

## Applications

### Infrastructure Applications

Infrastructure applications are defined in `infrastructure/kustomization.yaml`:

<!-- Update this list to match the actual applications in this cluster -->

- **kube-prometheus-stack-crds** (wave 2) - Prometheus Operator CRDs
- **metrics-server** (wave 5) - Kubernetes Metrics Server
- **traefik** (wave 10) - Ingress controller
- **cert-manager** (wave 20) - TLS certificate management
- **kube-prometheus-stack** (wave 20) - Monitoring stack (Prometheus, Grafana, Alertmanager)
- **trust-manager** (wave 30) - CA certificate distribution
- **vault** (wave 40) - HashiCorp Vault (dev mode)
- **vault-config** (wave 50) - Vault transit engine configuration
- **cert-manager-resources** (wave 75) - ClusterIssuer and certificates
- **argocd-ingress** (wave 80) - Traefik IngressRoute for ArgoCD UI
- **argocd-config** (wave 85) - ArgoCD ConfigMap patches for custom health checks

### Workload Applications

Workload applications are defined in `workloads/kustomization.yaml`:

<!-- Update this list to match the actual applications in this cluster -->

- **namespaces** (wave 100) - Namespace definitions
- **cfk-operator** (wave 105) - Confluent for Kubernetes operator
- **confluent-resources** (wave 110) - Confluent Platform (KRaft, Kafka, Schema Registry, etc.)
- **controlcenter-ingress** (wave 115) - Traefik IngressRoute for Control Center UI
- **flink-kubernetes-operator** (wave 116) - Flink Kubernetes Operator
- **observability-resources** (wave 117) - PodMonitors and Grafana dashboards
- **cmf-operator** (wave 118) - Confluent Manager for Apache Flink
- **flink-resources** (wave 120) - Flink integration resources

## Environment Access

### DNS Configuration

Add these entries to `/etc/hosts`:

```
127.0.0.1  alertmanager.eks-demo.platform.dspdemos.com
127.0.0.1  argocd.eks-demo.platform.dspdemos.com
127.0.0.1  cmf.eks-demo.platform.dspdemos.com
127.0.0.1  controlcenter.eks-demo.platform.dspdemos.com
127.0.0.1  grafana.eks-demo.platform.dspdemos.com
127.0.0.1  kafka.eks-demo.platform.dspdemos.com
127.0.0.1  prometheus.eks-demo.platform.dspdemos.com
127.0.0.1  schemaregistry.eks-demo.platform.dspdemos.com
127.0.0.1  vault.eks-demo.platform.dspdemos.com
```

> [!WARNING]
> If you experience ~5-second timeouts when accessing services, add IPv6 entries as well:
> ```
> ::1  alertmanager.eks-demo.platform.dspdemos.com
> ::1  argocd.eks-demo.platform.dspdemos.com
> ::1  cmf.eks-demo.platform.dspdemos.com
> ::1  controlcenter.eks-demo.platform.dspdemos.com
> ::1  grafana.eks-demo.platform.dspdemos.com
> ::1  kafka.eks-demo.platform.dspdemos.com
> ::1  prometheus.eks-demo.platform.dspdemos.com
> ::1  schemaregistry.eks-demo.platform.dspdemos.com
> ::1  vault.eks-demo.platform.dspdemos.com
> ```

### Services

<!-- Customize URLs and credentials for this cluster's services -->

**ArgoCD UI:**
- **URL**: https://argocd.eks-demo.platform.dspdemos.com
- **Username**: `admin`
- **Password**: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`

**Control Center:**
- **URL**: https://controlcenter.eks-demo.platform.dspdemos.com

**Grafana:**
- **URL**: http://grafana.eks-demo.platform.dspdemos.com
- **Username**: `admin`
- **Password**: `prom-operator`

**Prometheus:**
- **URL**: http://prometheus.eks-demo.platform.dspdemos.com

**Alertmanager:**
- **URL**: http://alertmanager.eks-demo.platform.dspdemos.com

**Vault** (dev mode):
- **URL**: http://vault.eks-demo.platform.dspdemos.com
- **Token**: `root`
- **Warning**: Dev mode - data is not persisted across restarts

**CMF API:**
- **URL**: http://cmf.eks-demo.platform.dspdemos.com

<!-- Add any additional services or port-forwarding fallbacks specific to this cluster -->

## Cluster Specific Use Cases

<!--
Document anything unique to this cluster that doesn't fit the standard template.
Examples:
- RBAC naming conventions and permission model
- Pre-created topics, schemas, or Flink resources
- Special authentication flows (e.g., Keycloak SSO, MDS device-grant)
- Token lifecycle management
- Demo/sandbox environments (e.g., CP Flink SQL Sandbox)

Remove this comment block and replace with cluster-specific content.
If this cluster has no unique use cases, remove this section entirely.
-->

## Troubleshooting

### ArgoCD Applications Not Syncing

Check parent Application health:

```bash
kubectl get application infrastructure-apps --namespace argocd -o yaml
kubectl get application workloads-apps --namespace argocd -o yaml
```

Verify Application manifests exist:

```bash
ls -la ./clusters/eks-demo/infrastructure/
ls -la ./clusters/eks-demo/workloads/
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
docker ps | grep eks-demo
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
./scripts/validate-cluster.sh eks-demo --verbose
```

## Cleanup

Remove the kind cluster:

```bash
kind delete cluster --name eks-demo
```

Stop the container runtime (if using Colima):

```bash
colima stop
```
