# Scripts

Operational scripts for managing confluent-platform-gitops clusters. Each section below
covers one script. Sections marked `(details TBD)` have a one-line summary only —
full usage docs will be filled in later.

## Table of Contents

- [clone-cluster.sh](#clone-clustersh)
- [generate-hosts-entries.sh](#generate-hosts-entriessh)
- [new-application.sh](#new-applicationsh)
- [new-cluster.sh](#new-clustersh)
- [prefetch-kind-images.sh](#prefetch-kind-imagessh)
- [prepare-release.sh](#prepare-releasesh)
- [release.sh](#releasesh)
- [setup-rbac-kubeconfigs.sh](#setup-rbac-kubeconfigssh)
- [update-repo-urls.sh](#update-repo-urlssh)
- [update-target-revision.sh](#update-target-revisionsh)
- [validate-cluster.sh](#validate-clustersh)

---

## clone-cluster.sh

Clone an existing cluster configuration with a new name.

```bash
./scripts/clone-cluster.sh <source-cluster> <new-cluster> [new-domain]
```

*(details TBD)*

---

## generate-hosts-entries.sh

Print a ready-to-paste `/etc/hosts` block for a cluster.

```bash
./scripts/generate-hosts-entries.sh <cluster-name> [ip-address]
```

*(details TBD)*

---

## new-application.sh

Scaffold a new application directory structure and ArgoCD Application manifest.

```bash
./scripts/new-application.sh <app-name> <type> <cluster>
# or interactively:
./scripts/new-application.sh
```

*(details TBD)*

---

## new-cluster.sh

Scaffold a new cluster directory structure.

```bash
./scripts/new-cluster.sh <cluster-name> <domain>
# or interactively:
./scripts/new-cluster.sh
```

*(details TBD)*

---

## prefetch-kind-images.sh

Pre-download every container image currently used by a kind cluster in this repo, then
sideload them into the kind nodes. Built for slow/unreliable wifi: discovery is free (no
image pulls), pulls skip anything already cached, failures don't abort the run, and the
whole thing is safe to re-run or resume.

### What it does

1. **Discover** — builds the image list from several live sources so it never goes stale:
   - Every image already running in the live cluster (`kubectl get pods -A`).
   - `kubectl kustomize` renders of the ArgoCD-managed apps that are declared for the
     cluster but not yet synced and are sourced from a kustomize path in this repo (as
     of 2026-09-01: `confluent-resources`, `flink-resources`, `colors-and-shapes`,
     `minio`), so images aren't missed just because ArgoCD hasn't created the pods yet.
   - ArgoCD's own bootstrap manifest, fetched directly from
     `raw.githubusercontent.com/argoproj/argo-cd`. This repo installs ArgoCD itself via
     a raw `kubectl apply` of that upstream manifest rather than a kustomize overlay
     (see the bootstrap docs), so it's invisible to the kustomize-render source above and
     only shows up in the live-pods source once ArgoCD is already running — meaning a
     from-scratch cluster (ArgoCD not installed yet) would otherwise miss these images
     entirely. Pinned to the version already running live when one is detected, else
     falls back to the `stable` ref the repo's bootstrap docs use.
   - `helm template` renders of the infra apps that are wired up via a remote Helm chart
     rather than a kustomize path (as of 2026-09-01: `cert-manager`, `trust-manager`,
     `traefik`, `headlamp`, `metrics-server`, `reflector`) — same blind spot as the
     ArgoCD bootstrap manifest, just for Helm-sourced infra instead of ArgoCD's own
     install. `kube-prometheus-stack` is the one exception: it's gated behind
     `--with-prometheus-stack` and off by default, since it's marked "not auto-sync
     while under development" in this repo and needs its own (larger) chart download.
   - The kind node's own image (resolved by local digest, not tag).
2. **Pull** — `docker pull` for each image not already cached locally, with 3 retries
   and backoff per image so a flaky connection doesn't kill the whole run. Images that
   are multi-arch manifests get flattened to the host's exact platform digest at this
   stage (see Known gotchas below) — this needs network, which is why it happens here
   and not at load time.
3. **Sideload** — `kind load docker-image` into every node of the target kind cluster.
   This is a local operation (no network), so it's safe to run later while offline as
   long as the pull step already ran once with connectivity.

### Usage

```bash
# 1. See what you're in for — cheap, no downloads (~seconds)
./scripts/prefetch-kind-images.sh --images-only

# 2. (optional) review/trim scripts/images.txt

# 3. Pull everything and sideload it — the long step, safe to Ctrl-C and re-run
./scripts/prefetch-kind-images.sh --skip-discover
```

Typical trip workflow — pull while you have decent wifi, load later with none:

```bash
./scripts/prefetch-kind-images.sh --pull-only
# ... later, possibly offline ...
./scripts/prefetch-kind-images.sh --load-only
```

### Flags

| Flag | Effect |
|---|---|
| `--images-only` | Discover and write `images.txt` only; skip pull and load. |
| `--pull-only` | Discover + pull; skip sideload. |
| `--load-only` | Sideload only, using the existing `images.txt`; skip discovery and pull. |
| `--skip-discover` | Reuse the existing `images.txt` instead of re-discovering. |
| `--with-prometheus-stack` | Also render `kube-prometheus-stack` (the one Helm-chart infra app that's off by default) during discovery. Requires `helm` and network. |
| `--cluster NAME` | kind cluster name (default: `flink-demo-rbac-mtls`). |
| `--repo PATH` | Path to the confluent-platform-gitops checkout to render manifests from (default: this repo's location on the author's machine — pass `--repo` explicitly if running from elsewhere). |

### Output files

Written next to the script wherever it's invoked from:
- `images.txt` — the discovered/edited image list (one image per line). Not tracked in
  git; regenerate any time with `--images-only` (or a fresh run without `--skip-discover`).
- `failed-images.txt` — images that failed to pull or load on the last run. Empty (or
  absent) on a clean run. Re-running with `--skip-discover` retries only what's left.

### Requirements

`docker`, `kind`, `kubectl` (with `kustomize` support built in), `yq` (v4, mikefarah),
`jq`, `curl`, `helm`. `helm` and `curl` are soft dependencies — if either is missing,
the script warns and just skips the sources that need it (the Helm-chart infra apps,
or the ArgoCD bootstrap manifest, respectively) instead of failing.

### Known gotchas this script works around

- **kind node image cached by digest, not tag**: `kindest/node` images are often present
  locally only as `kindest/node@sha256:...`, not under a plain version tag. The script
  resolves the node's actual local digest so it isn't re-pulled unnecessarily.
- **`kind load docker-image` failing with `content digest ... not found`**: happens when
  the local docker/containerd image store (e.g. Colima, Docker Desktop's containerd image
  store) keeps the full multi-arch manifest index for a pulled tag even though only the
  host's platform layers were downloaded — `kind`'s loader tries to import every platform
  in that index and fails on the ones that were never fetched. The script fixes this
  during the pull step by re-pointing each tag at its exact host-platform digest, so the
  later sideload step works even fully offline.

---

## prepare-release.sh

Pin `targetRevision` to a specific version in all ArgoCD Application manifests that
reference this repository, ahead of cutting a release.

```bash
./scripts/prepare-release.sh [--verify] <version>
```

*(details TBD)*

---

## release.sh

End-to-end release orchestrator: branch creation, changelog update, version pinning,
tagging, revert, merge, and push.

```bash
./scripts/release.sh
```

*(details TBD)*

---

## setup-rbac-kubeconfigs.sh

Generate ServiceAccount-based kubeconfig contexts for `flink-demo-rbac` cluster users,
for testing RBAC before OIDC is configured.

```bash
./scripts/setup-rbac-kubeconfigs.sh [cluster-name]
```

*(details TBD)*

---

## update-repo-urls.sh

Update repository URLs throughout the repo after forking.

```bash
./scripts/update-repo-urls.sh <new-repo-url> [--dry-run]
```

*(details TBD)*

---

## update-target-revision.sh

Update ArgoCD Application target revisions for a cluster (e.g. to point at a feature
branch for live-testing, or back to `HEAD`).

```bash
./scripts/update-target-revision.sh <cluster-name> <target-revision> [--dry-run]
```

*(details TBD — see also [Live-Testing an Unmerged Branch on a Cluster](../docs/bootstrap-procedure.md#live-testing-an-unmerged-branch-on-a-cluster).)*

---

## validate-cluster.sh

Comprehensive cluster validation suite.

```bash
./scripts/validate-cluster.sh <cluster-name> [--verbose]
```

*(details TBD)*
