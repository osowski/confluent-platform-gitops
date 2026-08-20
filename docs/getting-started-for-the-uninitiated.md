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

2. Add the following entries to `/etc/hosts` (all pointing to `127.0.0.1`). If
   you're following this guide from a remote VM with a public IP rather than
   your own machine, run `./scripts/generate-hosts-entries.sh flink-demo`
   instead — it detects that IP for you and points these same hostnames at
   it:

```
127.0.0.1  alertmanager.flink-demo.confluentdemo.local
127.0.0.1  argocd.flink-demo.confluentdemo.local
127.0.0.1  cmf.flink-demo.confluentdemo.local
127.0.0.1  controlcenter.flink-demo.confluentdemo.local
127.0.0.1  grafana.flink-demo.confluentdemo.local
127.0.0.1  headlamp.flink-demo.confluentdemo.local
127.0.0.1  kafka.flink-demo.confluentdemo.local
127.0.0.1  prometheus.flink-demo.confluentdemo.local
127.0.0.1  s3.flink-demo.confluentdemo.local
127.0.0.1  s3-console.flink-demo.confluentdemo.local
127.0.0.1  schema-registry.flink-demo.confluentdemo.local
127.0.0.1  vault.flink-demo.confluentdemo.local
```

> [!WARNING]
> If you experience ~5-second timeouts when accessing services, you may need to add IPv6 entries as well. Some HTTP clients (including the Confluent CLI) prefer IPv6 and will timeout trying `::1` before falling back to IPv4. Add these additional entries to `/etc/hosts` if needed:
> ```
> ::1  alertmanager.flink-demo.confluentdemo.local
> ::1  argocd.flink-demo.confluentdemo.local
> ::1  cmf.flink-demo.confluentdemo.local
> ::1  controlcenter.flink-demo.confluentdemo.local
> ::1  grafana.flink-demo.confluentdemo.local
> ::1  headlamp.flink-demo.confluentdemo.local
> ::1  kafka.flink-demo.confluentdemo.local
> ::1  prometheus.flink-demo.confluentdemo.local
> ::1  s3.flink-demo.confluentdemo.local
> ::1  s3-console.flink-demo.confluentdemo.local
> ::1  schema-registry.flink-demo.confluentdemo.local
> ::1  vault.flink-demo.confluentdemo.local
> ```

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

Then raise the Colima VM's inotify limits. The default `fs.inotify.max_user_instances` of `128` is **not enough** for a multi-node kind cluster running Confluent Platform, and exhausting it breaks the cluster in confusing ways:

```bash
colima ssh -- sudo sh -c 'cat > /etc/sysctl.d/99-inotify-k8s.conf <<EOF
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 1048576
EOF
sysctl -p /etc/sysctl.d/99-inotify-k8s.conf'
```

To make this survive a Colima VM *recreation* (`colima delete`), also add a provision block to `~/.colima/default/colima.yaml`, replacing the default `provision: null`:

```yaml
provision:
  - mode: system
    script: |
      cat > /etc/sysctl.d/99-inotify-k8s.conf <<'SYSCTL'
      fs.inotify.max_user_instances = 1024
      fs.inotify.max_user_watches = 1048576
      SYSCTL
      sysctl -p /etc/sysctl.d/99-inotify-k8s.conf
```

Verify the limit is in effect before creating the cluster:

```bash
colima ssh -- cat /proc/sys/fs/inotify/max_user_instances   # expect 1024
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

The `confluent-resources`, `flink-resources`, and `colors-and-shapes` Applications are not configured for automatic sync, as they depend on the operators and namespaces being fully ready first. Trigger them manually once the `workloads` Application is healthy.

13. In the ArgoCD UI, click on the `confluent-resources` Application, then click **Sync** → **Synchronize**. Wait for it to reach a `Healthy` status before proceeding.

14. Click on the `flink-resources` Application, then click **Sync** → **Synchronize**. Wait for it to reach a `Healthy` status.

15. Click on the `colors-and-shapes` Application, then click **Sync** → **Synchronize**. Wait for it to reach a `Healthy` status.

## Access Control Center

16. Open Confluent Control Center in your browser:

- URL: [`https://controlcenter.flink-demo.confluentdemo.local`](https://controlcenter.flink-demo.confluentdemo.local)

---

> **Note on flag style:** All `kubectl` commands in this guide use long-form flags (e.g. `--namespace`, `--filename`, `--output`) for clarity. In day-to-day use, most practitioners use the equivalent short-form flags (e.g. `-n`, `-f`, `-o`).
