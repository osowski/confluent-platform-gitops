# confluent-platform-gitops

[GitOps](https://opengitops.dev/) repository for [Confluent Platform](https://docs.confluent.io/platform/current/overview.html) deployments running on Kubernetes clusters managed by [Argo CD](https://argo-cd.readthedocs.io/en/stable/).

## Overview

This repository contains the declarative configuration for all applications and infrastructure components deployed to Kubernetes clusters running Confluent Platform. It implements the **App of Apps** pattern for managing Argo CD applications.

## Quicker Start

If you don't understand what any of this means and want the fastest, most handheld path to getting up and running, follow the [Getting Started for the Unitiated](docs/getting-started-for-the-uninitiated.md) guide.

## Quick Start

If you have experience with GitOps or want to understand how the inner workings of this architecture plays out, you can follow the steps below.

### Prerequisites

- Kubernetes cluster with Argo CD installed
  - https://argo-cd.readthedocs.io/en/stable/getting_started/#1-install-argo-cd
```
  kubectl create namespace argocd
  kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```
- `kubectl` configured with cluster access
- `helm` CLI installed

### Bootstrap a Cluster

1. Clone this repository:
   ```bash
   git clone https://github.com/osowski/confluent-platform-gitops.git
   cd confluent-platform-gitops
   git checkout <latest-tagged-version>
   ```

2. Deploy the bootstrap application:
   ```bash
   kubectl apply -f ./clusters/<cluster-name>/bootstrap.yaml
   ```

3. Watch Argo CD sync the applications:
   ```bash
   kubectl get applications -n argocd -w
   ```

### Access Argo CD UI

```bash
# Get cluster-specific hostname for Argo CD application
kubectl get ingressroute -n argocd -o yaml argocd-server | yq '.spec.routes[0].match'

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Navigate to `https://<cluster-specific-hostname>` and login with username `admin` and the password from above.

## Repository Structure

```
confluent-platform-gitops/
├── bootstrap/                      # Helm chart for bootstrapping Argo CD App of Apps
│   ├── Chart.yaml
│   ├── values.yaml                 # Default values
│   └── templates/
│       ├── argocd-projects.yaml    # Argo CD Project CRDs (infrastructure, workloads)
│       ├── infrastructure.yaml     # Infrastructure App of Apps
│       └── workloads.yaml          # Workloads App of Apps
├── infrastructure/                 # Platform infrastructure components
│   ├── argocd/                     # Argo CD self-management (Helm)
│   ├── argocd-config/              # Argo CD ConfigMap patches (custom health checks)
│   ├── argocd-ingress/             # Traefik IngressRoute for Argo CD UI
│   ├── cert-manager/               # TLS certificate management (Helm)
│   ├── cert-manager-resources/     # ClusterIssuer and Certificate resources
│   ├── kube-prometheus-stack/      # Monitoring stack (Helm)
│   ├── kube-prometheus-stack-crds/ # Prometheus Operator CRDs (Helm)
│   ├── traefik/                    # Ingress controller (Helm)
│   ├── trust-manager/              # cert-manager trust distribution (Helm)
│   ├── vault/                      # HashiCorp Vault secrets management (Helm)
│   ├── vault-config/               # Vault transit engine configuration
│   └── vault-ingress/              # Traefik IngressRoute for Vault UI
├── workloads/                      # User-facing applications and services
│   ├── cfk-operator/               # Confluent for Kubernetes operator (Helm)
│   ├── cmf-operator/               # Confluent Manager for Apache Flink (Helm)
│   ├── confluent-resources/        # Confluent Platform resources (Kustomize)
│   ├── controlcenter-ingress/      # Traefik IngressRoute for Control Center UI
│   ├── flink-kubernetes-operator/  # Flink Kubernetes Operator (Helm)
│   ├── flink-resources/            # Flink integration resources (Kustomize)
│   ├── namespaces/                 # Namespace definitions
│   └── observability-resources/    # PodMonitors and Grafana dashboards
├── clusters/                       # Cluster-specific application instances
│   └── flink-demo/
│       ├── bootstrap.yaml          # Bootstrap Application (sync-wave 0)
│       ├── kind-config.yaml        # Kind cluster configuration
│       ├── infrastructure/
│       │   ├── kustomization.yaml  # Lists all infrastructure apps
│       │   └── *.yaml              # Infrastructure Application manifests (12 apps)
│       └── workloads/
│           ├── kustomization.yaml  # Lists all workload apps
│           └── *.yaml              # Workload Application manifests (9 apps)
├── scripts/                        # Automation scripts
│   ├── prepare-release.sh          # Prepare changelog and version updates
│   └── release.sh                  # Create and push git tags for releases
├── docs/                           # Documentation
│   ├── *.md                        # All relevant project documentation
│   └── getting-started-for-the-uninitiated.md
└── adrs/                           # Architecture Decision Records
    ├── 0000-template.md
    ├── 0001-app-of-apps-pattern.md
    ├── 0002-cfk-component-sync-wave-ordering.md
    └── 0003-release-versioning-strategy.md
```

## How It Works

1. **Bootstrap**: The bootstrap Helm chart creates:
   - Argo CD Project definitions (infrastructure, workloads)
   - Parent Applications (infrastructure-apps, workloads-apps)

2. **Parent Applications**: These App of Apps watch the `clusters/<cluster-name>/` directories and automatically create child Applications.

3. **Child Applications**: Each child Application deploys actual workloads or infrastructure components using Kustomize overlays or Helm charts.

4. **GitOps Flow**: Changes pushed to this repository are automatically synced to the cluster by Argo CD.

## Documentation

- [Architecture](docs/architecture.md) - Detailed system design and GitOps flow
- [Adding Applications](docs/adding-applications.md) - How to add new applications (Kustomize and Helm overview)
- [Adding Helm Workloads](docs/adding-helm-workloads.md) - Comprehensive guide for Helm-based deployments
- [Bootstrap Procedure](docs/bootstrap-procedure.md) - Detailed bootstrap deployment steps
- [Cluster Onboarding](docs/cluster-onboarding.md) - How to onboard new clusters
- [Feature Roadmap](docs/roadmap.md) - Future roadmap for feature development and repository evolution.
- [Architecture Decision Records](adrs/) - Record of architectural decisions

## Current Clusters

- **flink-demo** - Demo cluster for Confluent Platform for Apache Flink (flink-demo.confluentdemo.local)

## Current Applications

### Infrastructure (Automated Sync)
- **kube-prometheus-stack-crds** (wave 2) - Prometheus Operator CRDs
- **traefik** (wave 10) - Ingress controller for external access
- **kube-prometheus-stack** (wave 20) - Monitoring stack (Prometheus, Grafana, Alertmanager)
- **cert-manager** (wave 20) - TLS certificate management
- **trust-manager** (wave 30) - cert-manager trust distribution for CA bundles
- **vault** (wave 40) - HashiCorp Vault secrets management (dev mode)
- **vault-ingress** (wave 45) - Traefik IngressRoute for Vault UI
- **vault-config** (wave 50) - Vault transit engine configuration
- **cert-manager-resources** (wave 75) - Self-signed ClusterIssuer and certificates
- **argocd-ingress** (wave 80) - Traefik IngressRoute for Argo CD UI
- **argocd-config** (wave 85) - Argo CD ConfigMap patches for custom health checks

### Workloads (Automated Sync)
- **namespaces** (wave 100) - Namespace definitions (kafka, flink, operator)
- **cfk-operator** (wave 105) - Confluent for Kubernetes (CFK) operator
- **controlcenter-ingress** (wave 115) - Traefik IngressRoute for Confluent Control Center UI
- **flink-kubernetes-operator** (wave 116) - Flink Kubernetes Operator for stream processing
- **observability-resources** (wave 117) - PodMonitors and Grafana dashboards
- **cmf-operator** (wave 118) - Confluent Manager for Apache Flink (CMF)

### Workloads (Manual Sync Required)
- **confluent-resources** (wave 110) - Confluent Platform resources (KRaft, Kafka, Schema Registry, Control Center, ksqlDB, Connect)
- **flink-resources** (wave 120) - Flink integration resources (CMFRestClass, FlinkEnvironment)

> **Note**: Applications marked as "Manual Sync Required" do not have automated sync policies. These must be manually synced via Argo CD UI or CLI to allow review of configuration changes before deployment.

## Security

- Secrets are managed externally (not committed to this repository)
- Argo CD Projects enforce RBAC boundaries:
  - `infrastructure` project: Can create cluster-scoped resources
  - `workloads` project: Namespace-scoped resources only

## Related Repositories

Migrated from [homelab-argocd](https://github.com/osowski/homelab-argocd) repository to focus specifically on Confluent Platform deployments.
