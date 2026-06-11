# 7. In-Cluster Image Registry via Pinned ClusterIP and PostSync Node Configuration

Date: 2026-06-11

## Status

Accepted

## Context

The cp-flink-workshop Lab 5 (End-to-End CI Pipeline) builds container images in-cluster with kaniko (in a Tekton pod) and deploys them as `FlinkApplication` resources on the `flink-demo` kind cluster. The kind nodes must pull those images, fully offline, with no external registry dependency ([#281](https://github.com/osowski/confluent-platform-gitops/issues/281)).

Two problems make this non-trivial on kind:

1. **Addressing**: kind nodes cannot resolve cluster DNS, so a registry Service name like `registry.registry.svc` works from pods (kaniko push) but not from node containerd (image pull). A single address must work identically from both sides, or image refs pushed by CI would not match refs pulled by the kubelet.
2. **Insecure-registry configuration**: the kind node image's containerd (v2.2.0) ships without `config_path` set, so there is no `/etc/containerd/certs.d` directory to drop per-registry `hosts.toml` files into, and registering a plain-HTTP registry would otherwise require editing `config.toml` and restarting containerd on every node.

Alternatives considered:

1. **External registry on the host (e.g., `kind` + local Docker registry container)**: the documented kind pattern, but it adds a host-level dependency outside GitOps, breaks the "self-contained cluster" property, and still requires the same containerd configuration.
2. **`NodePort` Service + `localhost:<port>` refs**: works for node pulls but kaniko inside a pod would push to a different address than the kubelet pulls from, splitting the image ref.
3. **DaemonSet to write node configuration**: guarantees one pod per node including new nodes, but leaves perpetually sleeping privileged pods running on a demo platform.
4. **Baking containerd config into a custom node image**: removes the runtime step but forks the kind node image and couples the platform to image rebuilds.

## Decision

Provide the registry as platform infrastructure on `flink-demo`, in three parts:

1. **Pinned ClusterIP**: deploy `registry:2` with a Service at the fixed ClusterIP `10.96.0.50:5000` (inside kind's default `10.96.0.0/16` service CIDR). This one address is reachable identically from pods (ClusterIP routing) and from node containerd (kube-proxy DNAT), so a single image ref (`10.96.0.50:5000/<image>`) is valid for both push and pull.
2. **containerd `config_path` at create time**: `clusters/flink-demo/kind-config.yaml` sets `containerdConfigPatches` to point containerd at `/etc/containerd/certs.d`. Set at cluster creation, it is inert until files exist there and means no containerd restart is ever needed later.
3. **PostSync-hook Job for per-node `hosts.toml`** (`infrastructure/registry-hosts`): an ArgoCD PostSync hook with required podAntiAffinity on `kubernetes.io/hostname`, `completions`/`parallelism` pinned to the cluster node count, and tolerations for the control-plane writes the `hosts.toml` marking the registry insecure on every node. `BeforeHookCreation` re-runs it on each sync; nothing stays running in steady state. A `registry-hosts-config` ConfigMap supplies the registry address to the Job **and** serves as the app's non-hook resource — an ArgoCD app containing only hook resources is trivially Synced and its automated sync (and therefore the hook) never fires.

## Consequences

**Positive:**

- The cluster is self-contained: CI labs build, push, and run images with no external network dependency.
- No containerd restarts, no host-level setup, no perpetually running privileged pods.
- The pattern is reusable by any kind-based cluster in this repo (the base manifests are kind-generic; only the node count is per-cluster).

**Negative / constraints:**

- The pinned IP couples the manifests to kind's default service CIDR; non-kind clusters (e.g., eks-demo) must not adopt this app as-is.
- `completions`/`parallelism` in the per-cluster overlay must be kept in sync manually with the node topology in `kind-config.yaml`.
- The `registry-hosts` Job runs privileged with a writable `hostPath` — acceptable only for local kind demo platforms, documented as such.
- The registry is plain HTTP (insecure) — acceptable only inside the cluster boundary of a local demo.
- Changes take effect only on a freshly created cluster (the `config_path` patch applies at create time).
