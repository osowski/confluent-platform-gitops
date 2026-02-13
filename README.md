# homelab-argocd

GitOps repository for Confluent Platform deployments running on Kubernetes clusters managed by Argo CD.

## Overview

This repository contains the declarative configuration for all applications and infrastructure components deployed to Kubernetes clusters running Confluent Platform. It implements the **App of Apps** pattern for managing Argo CD applications.

## Repository Structure

```
homelab-argocd/
├── bootstrap/                      # Helm chart for bootstrapping Argo CD App of Apps
│   ├── Chart.yaml
│   ├── values.yaml                 # Default values
│   └── templates/
│       ├── argocd-projects.yaml    # Argo CD Project CRDs (infrastructure, workloads)
│       ├── infrastructure.yaml     # Infrastructure App of Apps
│       └── workloads.yaml          # Workloads App of Apps
├── argocd-projects/                # Standalone Project CRD definitions (reference)
│   ├── infrastructure-project.yaml
│   └── workloads-project.yaml
├── infrastructure/                 # Platform infrastructure components
│   ├── argocd-config/              # Argo CD ConfigMap patches (custom health checks)
│   ├── argocd-ingress/             # Traefik IngressRoute for Argo CD UI
│   ├── cert-manager/               # TLS certificate management (Helm)
│   ├── cert-manager-resources/     # ClusterIssuer and Certificate resources
│   ├── kube-prometheus-stack/      # Monitoring stack (Helm)
│   ├── kube-prometheus-stack-crds/ # Prometheus Operator CRDs (Helm)
│   └── traefik/                    # Ingress controller (Helm)
├── workloads/                      # User-facing applications and services
│   ├── cmf-operator/               # Confluent Manager for Apache Flink (Helm)
│   ├── confluent-operator/         # Confluent for Kubernetes operator (Helm)
│   ├── confluent-resources/        # Confluent Platform resources (Kustomize)
│   ├── controlcenter-ingress/      # Traefik IngressRoute for Control Center UI
│   ├── flink-kubernetes-operator/  # Flink Kubernetes Operator (Helm)
│   ├── flink-resources/            # Flink integration resources (Kustomize)
├── clusters/                       # Cluster-specific application instances
│   ├── flink-demo/
│   │   ├── bootstrap.yaml          # Bootstrap Application (sync-wave 0)
│   │   ├── infrastructure/
│   │   │   ├── kustomization.yaml  # Lists all infrastructure apps
│   │   │   └── *.yaml              # Infrastructure Application manifests
│   │   └── workloads/
│   │       ├── kustomization.yaml  # Lists all workload apps
│   │       └── *.yaml              # Workload Application manifests
└── docs/                           # Documentation
    ├── architecture.md
    ├── adding-applications.md
    ├── adding-helm-workloads.md
    ├── argocd-self-management.md
    ├── bootstrap-procedure.md
    ├── changelog.md
    ├── cluster-onboarding.md
    ├── code_review_checklist.md
    ├── confluent-flink.md
    ├── confluent-platform.md
    └── project_spec.md
```

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
- [Architecture Decision Records](adrs/) - Record of architectural decisions

## Current Clusters

- **flink-demo** - Initial demo cluster for Confluent Platform for Apache Flink (flink-demo.confluentdemo.local)

## Current Applications

### Infrastructure (Automated Sync)
- **kube-prometheus-stack-crds** (wave 2) - Prometheus Operator CRDs
- **traefik** (wave 10) - Ingress controller for external access
- **longhorn** (wave 15) - Distributed block storage for persistent volumes (portcullis only)
- **kube-prometheus-stack** (wave 20) - Monitoring stack (Prometheus, Grafana, Alertmanager)
- **cert-manager** (wave 20) - TLS certificate management
- **cert-manager-resources** (wave 75) - Self-signed ClusterIssuer and certificates
- **argocd-ingress** (wave 80) - Traefik IngressRoute for Argo CD UI
- **argocd-config** (wave 85) - Argo CD ConfigMap patches for custom health checks

### Workloads (Automated Sync)
- **confluent-operator** (wave 105) - Confluent for Kubernetes (CFK) operator
- **controlcenter-ingress** (wave 115) - Traefik IngressRoute for Confluent Control Center UI
- **flink-kubernetes-operator** (wave 116) - Flink Kubernetes Operator for stream processing
- **cmf-operator** (wave 118) - Confluent Manager for Apache Flink (CMF)
- **http-echo** (wave 105) - Validation service

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

Originally created in [homelab-argocd](https://github.com/osowski/homelab-argocd) and ported to this repository, as of the `v0.1.0` version of that repository. All future GitOps-specific updates will be made to this repository directly.

Prior peer repositories:
- [homelab-docs](https://github.com/osowski/homelab-docs) - Shared homelab documentation, architecture overview, and cross-cutting ADRs
- [homelab-ansible](https://github.com/osowski/homelab-ansible) - Infrastructure provisioning and cluster lifecycle management
