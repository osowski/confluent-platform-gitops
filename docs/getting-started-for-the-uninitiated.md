# Getting Started for the Completely Uninitiated

If you know what Kubernetes is but have no idea what ArgoCD, GitOps, or anything else in this repository means — this guide is for you. It covers the shortest path from a fresh macOS environment to a running cluster with everything deployed. The reference cluster for this guide is [`flink-demo`](../clusters/flink-demo/README.md), using the domain `*.flink-demo.confluentdemo.local`.

## Prerequisites

1. Install required tools via Homebrew:

```bash
brew install colima \
    kind \
    kubectl \
    kubectx \
    yq
```

2. Add the following entries to `/etc/hosts` (all pointing to `127.0.0.1`):

```
127.0.0.1  argocd.flink-demo.confluentdemo.local
127.0.0.1  controlcenter.flink-demo.confluentdemo.local
127.0.0.1  grafana.flink-demo.confluentdemo.local
127.0.0.1  prometheus.flink-demo.confluentdemo.local
127.0.0.1  alertmanager.flink-demo.confluentdemo.local
```

## Checkout the Latest Release

3. List available release tags and checkout the latest one:

```bash
git tag --sort=-v:refname
git checkout <latest-tag>   # e.g., git checkout v0.2.0
```

Checking out a release tag ensures you are working from a known-good snapshot where all `targetRevision` values are pinned to that version. If you stay on `main`, the deployment will track `HEAD` and may include in-progress changes. See [Release Process](release-process.md) for details.

## Cluster Setup

4. Start Colima (provides the Docker runtime that kind uses):

```bash
colima start --arch arm64 --memory 16 --cpu 8 --disk 256
```

5. Create the kind cluster:

```bash
kind create cluster --config ./clusters/flink-demo/kind-config.yaml --name flink-demo
```

6. Select the flink-demo Kubernetes context:

```bash
kubectx kind-flink-demo
```

## ArgoCD Installation

7. Create the ArgoCD namespace:

```bash
kubectl create namespace argocd
```

8. Install ArgoCD:

```bash
kubectl apply --namespace argocd --server-side --force-conflicts --filename https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

9. Wait for all ArgoCD pods to be ready:

```bash
kubectl wait pods --namespace argocd --all --for=condition=Ready --timeout=300s
```

## Bootstrap

10. Apply the cluster bootstrap:

```bash
kubectl apply --filename ./clusters/flink-demo/bootstrap.yaml
```

ArgoCD will create the `infrastructure` and `workloads` parent Applications, which in turn deploy all configured components automatically.

## Access ArgoCD

11. Retrieve the initial admin password:

```bash
kubectl get secret --namespace argocd argocd-initial-admin-secret --output jsonpath='{.data.password}' | base64 -d | pbcopy
```

12. Open ArgoCD in your browser:

- URL: [`https://argocd.flink-demo.confluentdemo.local`](https://argocd.flink-demo.confluentdemo.local)
    - **NOTE:** Ensure that this is using `https` as we are using a self-signed cert for ArgoCD ingress.
- Username: `admin`
- Password: paste from clipboard (copied in the previous step)

You should see the `bootstrap`, `infrastructure`, and `workloads` Applications syncing.

## Deploy Confluent and Flink Workloads

The `confluent-resources` and `flink-resources` Applications are not configured for automatic sync, as they depend on the operators and namespaces being fully ready first. Trigger them manually once the `workloads` Application is healthy.

13. In the ArgoCD UI, click on the `confluent-resources` Application, then click **Sync** → **Synchronize**. Wait for it to reach a `Healthy` status before proceeding.

14. Click on the `flink-resources` Application, then click **Sync** → **Synchronize**. Wait for it to reach a `Healthy` status.

## Access Control Center

15. Open Confluent Control Center in your browser:

- URL: [`https://controlcenter.flink-demo.confluentdemo.local`](https://controlcenter.flink-demo.confluentdemo.local)

---

> **Note on flag style:** All `kubectl` commands in this guide use long-form flags (e.g. `--namespace`, `--filename`, `--output`) for clarity. In day-to-day use, most practitioners use the equivalent short-form flags (e.g. `-n`, `-f`, `-o`).
