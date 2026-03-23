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

## Creating Cluster-Specific Overlays

Most applications work with base configuration. Create overlays only when you need cluster-specific customization.

### Understanding Base + Overlay Pattern

- **Base values:** Shared configuration in `infrastructure/<app>/base/` or `workloads/<app>/base/`
- **Overlay values:** Cluster-specific overrides in `infrastructure/<app>/overlays/flink-demo-rbac/` or `workloads/<app>/overlays/flink-demo-rbac/`
- **Missing overlays:** Applications will use base values if overlay files don't exist (thanks to `ignoreMissingValueFiles: true`)

### When to Create Overlays

| Overlay Type | When Needed | Examples |
|--------------|-------------|----------|
| **Ingress Hostnames** | Required for UI access | argocd-ingress, vault-ingress, controlcenter-ingress |
| **Environment-Specific** | KIND vs cloud differences | traefik (DaemonSet+NodePort for KIND), metrics-server (insecure TLS) |
| **Resource Limits** | Production tuning | kube-prometheus-stack, cfk-operator |
| **Debug Settings** | Development clusters | cfk-operator debug mode |

### Required Overlays for Ingress Access

**ArgoCD Ingress** (if using ArgoCD UI):

```bash
mkdir -p infrastructure/argocd-ingress/overlays/flink-demo-rbac
cat > infrastructure/argocd-ingress/overlays/flink-demo-rbac/ingressroute-patch.yaml <<'EOF'
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-server
  namespace: argocd
spec:
  routes:
    - match: Host(\`argocd.flink-demo-rbac.confluentdemo.local\`)
      kind: Rule
      priority: 10
      services:
        - name: argocd-server
          port: 80
  tls:
    secretName: argocd-tls
EOF

cat > infrastructure/argocd-ingress/overlays/flink-demo-rbac/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

patches:
  - path: ingressroute-patch.yaml
EOF
```

**Vault Ingress** (if using Vault UI):

```bash
mkdir -p infrastructure/vault-ingress/overlays/flink-demo-rbac
cat > infrastructure/vault-ingress/overlays/flink-demo-rbac/ingressroute-patch.yaml <<'EOF'
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: vault-server
  namespace: vault
spec:
  routes:
    - match: Host(\`vault.flink-demo-rbac.confluentdemo.local\`)
      kind: Rule
      priority: 10
      services:
        - name: vault
          port: 8200
  tls:
    secretName: vault-tls
EOF

cat > infrastructure/vault-ingress/overlays/flink-demo-rbac/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

patches:
  - path: ingressroute-patch.yaml
EOF
```

**Control Center Ingress** (if using Confluent Control Center UI):

```bash
mkdir -p workloads/controlcenter-ingress/overlays/flink-demo-rbac
cat > workloads/controlcenter-ingress/overlays/flink-demo-rbac/ingressroute-patch.yaml <<'EOF'
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: controlcenter
  namespace: kafka
spec:
  routes:
    - match: Host(\`controlcenter.flink-demo-rbac.confluentdemo.local\`)
      kind: Rule
      priority: 10
      services:
        - name: controlcenter
          port: 9021
  tls:
    secretName: controlcenter-tls
EOF

cat > workloads/controlcenter-ingress/overlays/flink-demo-rbac/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

patches:
  - path: ingressroute-patch.yaml
EOF
```

### Optional Environment-Specific Overlays

**Traefik for KIND Clusters** (local development):

```bash
mkdir -p infrastructure/traefik/overlays/flink-demo-rbac
cat > infrastructure/traefik/overlays/flink-demo-rbac/values.yaml <<'EOF'
# KIND-specific configuration: DaemonSet + NodePort
deployment:
  kind: DaemonSet

service:
  type: NodePort

# Enable insecure TLS for self-signed certificates
additionalArguments:
  - "--serversTransport.insecureSkipVerify=true"
EOF
```

**Traefik for Cloud Clusters** (production):

```bash
mkdir -p infrastructure/traefik/overlays/flink-demo-rbac
cat > infrastructure/traefik/overlays/flink-demo-rbac/values.yaml <<'EOF'
# Cloud-specific configuration: Deployment + LoadBalancer
deployment:
  kind: Deployment
  replicas: 2

service:
  type: LoadBalancer
  annotations:
    # Add cloud provider annotations as needed
    # service.beta.kubernetes.io/aws-load-balancer-type: "nlb"

# Production TLS settings
additionalArguments:
  - "--entrypoints.websecure.http.tls=true"
EOF
```

**Metrics Server for KIND Clusters** (insecure TLS):

```bash
mkdir -p infrastructure/metrics-server/overlays/flink-demo-rbac
cat > infrastructure/metrics-server/overlays/flink-demo-rbac/values.yaml <<'EOF'
# KIND-specific: Allow insecure TLS for self-signed kubelet certificates
args:
  - --kubelet-insecure-tls
EOF
```

### Optional Production Tuning Overlays

**Kube-Prometheus-Stack** (resource limits, retention):

```bash
mkdir -p infrastructure/kube-prometheus-stack/overlays/flink-demo-rbac
cat > infrastructure/kube-prometheus-stack/overlays/flink-demo-rbac/values.yaml <<'EOF'
prometheus:
  prometheusSpec:
    retention: 30d
    resources:
      requests:
        cpu: 500m
        memory: 2Gi
      limits:
        cpu: 2000m
        memory: 8Gi

grafana:
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi
EOF
```

**CFK Operator** (debug mode for development):

```bash
mkdir -p workloads/cfk-operator/overlays/flink-demo-rbac
cat > workloads/cfk-operator/overlays/flink-demo-rbac/values.yaml <<'EOF'
debug: true

resources:
  limits:
    cpu: 500m
    memory: 512Mi
EOF
```

### Verifying Overlay Configuration

After creating overlays, verify the configuration:

```bash
# Check that Application manifests reference overlays correctly
grep -r "overlays/flink-demo-rbac" infrastructure/ workloads/

# Validate Kustomize builds (for Kustomize-based apps)
kustomize build infrastructure/argocd-ingress/overlays/flink-demo-rbac

# Validate Helm values (for Helm-based apps)
# Values are validated during ArgoCD sync
```

## Access

### Required /etc/hosts Entries

Add these entries to `/etc/hosts` for local DNS resolution:

```bash
sudo tee -a /etc/hosts << 'EOF'
127.0.0.1  argocd.flink-demo-rbac.confluentdemo.local
127.0.0.1  controlcenter.flink-demo-rbac.confluentdemo.local
127.0.0.1  cmf.flink-demo-rbac.confluentdemo.local
127.0.0.1  mds.flink-demo-rbac.confluentdemo.local
127.0.0.1  keycloak.flink-demo-rbac.confluentdemo.local
EOF
```

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

**Confluent Manager for Apache Flink (CMF) API:**
```bash
export CONFLUENT_CMF_URL=http://cmf.flink-demo-rbac.confluentdemo.local/cmf

# List Flink environments
confluent flink environment list

# List applications
confluent flink application list --environment shapes-env
```

**MDS (Metadata Service) for CLI Authentication:**
```bash
export CONFLUENT_PLATFORM_SSO=true

# Login via MDS ingress
confluent login --url http://mds.flink-demo-rbac.confluentdemo.local --no-browser

# Follow device grant flow prompts
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

### Confluent CLI Environment Variables

For convenience, set these environment variables:

```bash
export CONFLUENT_PLATFORM_SSO=true
export CONFLUENT_CMF_URL=http://cmf.flink-demo-rbac.confluentdemo.local/cmf

# Login once via MDS ingress
confluent login --url http://mds.flink-demo-rbac.confluentdemo.local --no-browser

# Then use Flink commands
confluent flink environment list
confluent flink application list --environment shapes-env
```

## Customization

This cluster was created using `scripts/new-cluster.sh`. Customize by:

1. Adding applications to `infrastructure/kustomization.yaml`
2. Adding applications to `workloads/kustomization.yaml`
3. Creating cluster-specific overlays in `infrastructure/` and `workloads/`

See [Cluster Onboarding](../../docs/cluster-onboarding.md) for detailed guidance.
