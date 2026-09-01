#!/usr/bin/env bash
#
# prefetch-kind-images.sh
#
# Pre-download every container image currently used by the confluent-platform-gitops
# "flink-demo-rbac-mtls" kind cluster, then sideload them into the kind nodes.
# Built for slow hotel wifi: discovery is free (no image pulls), pulls skip anything
# already cached locally, failures don't abort the run, and the whole thing is
# safe to re-run/resume.
#
# Image discovery has two sources, both queried live so the list never goes stale:
#   1. Every image already running in the live cluster (kubectl get pods -A).
#   2. `kubectl kustomize` renders of the ArgoCD-managed apps that are declared for
#      this cluster but not yet synced (confluent-resources, flink-resources,
#      colors-and-shapes as of 2026-09-01) — so images aren't missed just because
#      ArgoCD hasn't created the pods yet.
#   3. (optional, --with-prometheus-stack) a `helm template` render of the
#      kube-prometheus-stack app, since that one's a remote Helm chart that isn't
#      wired into #2. Off by default: it's marked "NOT auto-sync while under
#      development" in the repo and needs its own (small) chart download.
#
# Usage:
#   ./prefetch-kind-images.sh [--images-only|--pull-only|--load-only] \
#       [--skip-discover] [--with-prometheus-stack] \
#       [--cluster NAME] [--repo PATH]
#
# Typical flow on hotel wifi:
#   1. ./prefetch-kind-images.sh --images-only     # cheap, see what you're in for
#   2. review/trim images.txt if you want
#   3. ./prefetch-kind-images.sh --skip-discover    # pull + sideload, resumable

set -uo pipefail

CLUSTER="flink-demo-rbac-mtls"
REPO="/Users/osowski/git/confluent/confluent-platform-gitops"
WITH_PROM_STACK=0
DO_DISCOVER=1
DO_PULL=1
DO_LOAD=1

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_FILE="$WORKDIR/images.txt"
FAILED_FILE="$WORKDIR/failed-images.txt"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --images-only) DO_PULL=0; DO_LOAD=0 ;;
    --pull-only) DO_LOAD=0 ;;
    --load-only) DO_DISCOVER=0; DO_PULL=0 ;;
    --skip-discover) DO_DISCOVER=0 ;;
    --with-prometheus-stack) WITH_PROM_STACK=1 ;;
    --cluster) CLUSTER="$2"; shift ;;
    --repo) REPO="$2"; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

KCTX="kind-${CLUSTER}"
log() { echo "[$(date +%H:%M:%S)] $*"; }

for bin in docker kind kubectl yq jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing required tool: $bin" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# 1. Discover images
# ---------------------------------------------------------------------------
if [[ "$DO_DISCOVER" -eq 1 ]]; then
  log "Discovering images for kind cluster '$CLUSTER'..."
  RENDER_DIR="$(mktemp -d)"
  trap 'rm -rf "$RENDER_DIR"' EXIT

  # --- Source 1: live pods (covers everything already synced/running) ---
  LIVE_JSON="$RENDER_DIR/live.json"
  if command kubectl --context "$KCTX" get pods -A -o json > "$LIVE_JSON" 2>"$RENDER_DIR/live.err"; then
    jq -r '.items[]
      | (.spec.containers // [])[].image,
        (.spec.initContainers // [])[].image,
        (.spec.ephemeralContainers // [])[].image' "$LIVE_JSON" | sort -u > "$RENDER_DIR/from-live.txt"
    log "  live cluster: $(wc -l < "$RENDER_DIR/from-live.txt" | tr -d ' ') image refs"
  else
    log "  WARNING: couldn't query live cluster (context '$KCTX' not reachable) — $(cat "$RENDER_DIR/live.err")"
    : > "$RENDER_DIR/from-live.txt"
  fi

  # --- Source 2: kustomize renders of not-yet-synced workload apps ---
  # These paths mirror clusters/$CLUSTER/workloads/kustomization.yaml as of 2026-09-01.
  # If that file changes (apps added/removed), update this list to match.
  RENDER_PATHS=(
    "workloads/confluent-resources/overlays/${CLUSTER}"
    "workloads/flink-resources/overlays/${CLUSTER}"
    "workloads/colors-and-shapes/overlays/${CLUSTER}"
  )
  : > "$RENDER_DIR/from-kustomize.txt"
  for p in "${RENDER_PATHS[@]}"; do
    full="$REPO/$p"
    if [[ -d "$full" ]]; then
      if command kubectl kustomize "$full" >> "$RENDER_DIR/all-render.yaml" 2>"$RENDER_DIR/kustomize.err"; then
        echo "---" >> "$RENDER_DIR/all-render.yaml"
      else
        log "  WARNING: kustomize render failed for $p — $(cat "$RENDER_DIR/kustomize.err")"
      fi
    else
      log "  WARNING: overlay path not found, skipping: $p"
    fi
  done
  if [[ -s "$RENDER_DIR/all-render.yaml" ]]; then
    # Walk every map node anywhere in the tree that has an "image" key and pull
    # out its value (a plain string for containers/FlinkApplication/etc, or an
    # object like CFK's {application, init} for Kafka/SchemaRegistry/ControlCenter/...).
    yq eval-all -o=json '[.. | select(tag=="!!map") | select(has("image")) | .image]' "$RENDER_DIR/all-render.yaml" \
      | jq -r 'flatten | .[] | if type=="object" then (.[]) else . end | select(type=="string")' \
      | sort -u > "$RENDER_DIR/from-kustomize.txt"
  fi
  log "  kustomize renders: $(wc -l < "$RENDER_DIR/from-kustomize.txt" | tr -d ' ') image refs"

  # --- Source 3 (optional): helm render of kube-prometheus-stack ---
  : > "$RENDER_DIR/from-helm.txt"
  if [[ "$WITH_PROM_STACK" -eq 1 ]]; then
    if command -v helm >/dev/null 2>&1; then
      log "  rendering kube-prometheus-stack via helm (needs network for the chart)..."
      if helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>"$RENDER_DIR/helm.err" \
        && helm repo update prometheus-community >/dev/null 2>>"$RENDER_DIR/helm.err"; then
        VALUE_ARGS=()
        for vf in "$REPO/infrastructure/kube-prometheus-stack/base/values.yaml" \
                  "$REPO/infrastructure/kube-prometheus-stack/overlays/${CLUSTER}/values.yaml"; do
          [[ -f "$vf" ]] && VALUE_ARGS+=(-f "$vf")
        done
        if helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack \
            --version 81.6.1 "${VALUE_ARGS[@]}" > "$RENDER_DIR/prom-render.yaml" 2>"$RENDER_DIR/helm-template.err"; then
          yq eval-all -o=json '[.. | select(tag=="!!map") | select(has("image")) | .image]' "$RENDER_DIR/prom-render.yaml" \
            | jq -r 'flatten | .[] | if type=="object" then (.[]) else . end | select(type=="string")' \
            | sort -u > "$RENDER_DIR/from-helm.txt"
          log "  kube-prometheus-stack: $(wc -l < "$RENDER_DIR/from-helm.txt" | tr -d ' ') image refs"
        else
          log "  WARNING: helm template failed for kube-prometheus-stack — $(cat "$RENDER_DIR/helm-template.err")"
        fi
      else
        log "  WARNING: couldn't add/update the prometheus-community helm repo (no network?) — $(cat "$RENDER_DIR/helm.err")"
      fi
    else
      log "  WARNING: --with-prometheus-stack requested but helm isn't installed; skipping"
    fi
  fi

  # --- Source 4: the kind node image itself (useful if you ever need to recreate the cluster) ---
  # kind's node images are usually cached locally by digest only (no local tag), so resolve
  # to the digest reference — otherwise the "already cached" check below misses it and
  # `docker pull` re-downloads a >1GB image that's already sitting on disk.
  NODE_CID="$(docker ps --filter "name=${CLUSTER}-control-plane" --format '{{.ID}}' | head -1)"
  NODE_IMAGE=""
  if [[ -n "$NODE_CID" ]]; then
    NODE_IMAGE_ID="$(docker inspect "$NODE_CID" --format '{{.Image}}' 2>/dev/null)"
    NODE_IMAGE="$(docker inspect "$NODE_IMAGE_ID" --format '{{index .RepoDigests 0}}' 2>/dev/null)"
    [[ -z "$NODE_IMAGE" ]] && NODE_IMAGE="$(docker ps --filter "name=${CLUSTER}-control-plane" --format '{{.Image}}' | head -1)"
  fi

  # --- Merge, normalize, dedupe ---
  {
    cat "$RENDER_DIR/from-live.txt" "$RENDER_DIR/from-kustomize.txt" "$RENDER_DIR/from-helm.txt"
    [[ -n "$NODE_IMAGE" ]] && echo "$NODE_IMAGE"
  } | sed 's#^docker\.io/##' | sort -u > "$IMAGES_FILE"

  log "Wrote $(wc -l < "$IMAGES_FILE" | tr -d ' ') unique images to $IMAGES_FILE"
else
  [[ -f "$IMAGES_FILE" ]] || { echo "No $IMAGES_FILE found; run without --skip-discover first." >&2; exit 1; }
  log "Using existing $IMAGES_FILE ($(wc -l < "$IMAGES_FILE" | tr -d ' ') images)"
fi

if [[ "$DO_PULL" -eq 0 && "$DO_LOAD" -eq 0 ]]; then
  log "Discovery-only run complete. Review/edit $IMAGES_FILE, then re-run with --skip-discover."
  exit 0
fi

IMAGES=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" ]] && IMAGES+=("$line")
done < "$IMAGES_FILE"
TOTAL=${#IMAGES[@]}
: > "$FAILED_FILE"

# `kind load docker-image` shells out to `ctr images import --all-platforms`, which
# chokes ("content digest ... not found") on any image whose local copy is still a
# multi-arch manifest list/index — the common case when the local docker/containerd
# image store (Docker Desktop's containerd image store, Colima, etc.) keeps the full
# index around even though only the host's platform layers were actually downloaded.
# Fix it once, here, while we still have network: re-point the tag at the exact
# single-platform manifest digest. That way `--load-only` later (possibly offline,
# at the venue with no wifi) never needs to touch the network.
flatten_multiarch() {
  local img="$1" raw media_type digest
  raw="$(docker buildx imagetools inspect "$img" --raw 2>/dev/null)" || return 0
  media_type="$(echo "$raw" | jq -r '.mediaType // empty' 2>/dev/null)"
  case "$media_type" in
    application/vnd.oci.image.index.v1+json|application/vnd.docker.distribution.manifest.list.v2+json) ;;
    *) return 0 ;; # already a single-platform manifest (or inspect gave us nothing usable) — nothing to do
  esac
  digest="$(echo "$raw" | jq -r --arg os "$HOST_OS" --arg arch "$HOST_ARCH" \
    '.manifests[]? | select(.platform.os == $os and .platform.architecture == $arch) | .digest' | head -1)"
  [[ -z "$digest" || "$digest" == "null" ]] && return 0
  local repo="${img%%[:@]*}"
  docker pull "${repo}@${digest}" >/dev/null 2>&1 && docker tag "${repo}@${digest}" "$img" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 2. Pull (skips anything already cached locally, retries on flaky wifi)
# ---------------------------------------------------------------------------
if [[ "$DO_PULL" -eq 1 ]]; then
  HOST_OS="linux"
  HOST_ARCH="$(docker version --format '{{.Server.Arch}}' 2>/dev/null || echo amd64)"
  log "Pulling $TOTAL images for $HOST_OS/$HOST_ARCH (already-cached ones are skipped)..."
  i=0
  for img in "${IMAGES[@]}"; do
    i=$((i + 1))
    if docker image inspect "$img" >/dev/null 2>&1; then
      log "[$i/$TOTAL] already have $img"
      flatten_multiarch "$img"
      continue
    fi
    log "[$i/$TOTAL] pulling $img"
    ok=0
    for attempt in 1 2 3; do
      if docker pull "$img"; then
        ok=1
        break
      fi
      log "  attempt $attempt failed for $img, retrying in $((attempt * 5))s..."
      sleep $((attempt * 5))
    done
    if [[ "$ok" -eq 0 ]]; then
      log "  GIVING UP on $img after 3 attempts"
      echo "$img" >> "$FAILED_FILE"
      continue
    fi
    flatten_multiarch "$img"
  done
fi

# ---------------------------------------------------------------------------
# 3. Sideload into every kind node (local op, no network — safe to always run)
# ---------------------------------------------------------------------------
if [[ "$DO_LOAD" -eq 1 ]]; then
  log "Sideloading images into kind cluster '$CLUSTER'..."
  i=0
  for img in "${IMAGES[@]}"; do
    i=$((i + 1))
    grep -qxF "$img" "$FAILED_FILE" 2>/dev/null && { log "[$i/$TOTAL] skipping $img (failed to pull)"; continue; }
    if ! docker image inspect "$img" >/dev/null 2>&1; then
      log "[$i/$TOTAL] skipping $img (not present locally)"
      continue
    fi
    log "[$i/$TOTAL] loading $img"
    kind load docker-image "$img" --name "$CLUSTER" || echo "$img" >> "$FAILED_FILE"
  done
fi

if [[ -s "$FAILED_FILE" ]]; then
  log "Done, but $(wc -l < "$FAILED_FILE" | tr -d ' ') image(s) failed — see $FAILED_FILE. Re-run with --skip-discover to retry just what's left."
  exit 1
fi
log "Done. All images pulled and sideloaded into '$CLUSTER'."
