# Flink Agents — Deployment & Performance Guide

This workload deploys the [Flink Agents workflow agent quickstart](https://nightlies.apache.org/flink/flink-agents-docs-release-0.2/docs/get-started/quickstart/workflow_agent/) as a CMF-managed `FlinkApplication` on the `flink-demo` cluster, using Ollama as the local LLM backend.

---

## Architecture

```
FlinkApplication (flink ns)
  └─ ReviewAnalysisAgent
       └─ OLLAMA_ENDPOINT ──► Ollama service (ollama ns)
                                  └─ qwen3:8b (or configured model)
```

The `OLLAMA_ENDPOINT` env var on the Flink pod controls where inference requests are sent. By default it points to the in-cluster Ollama service. For native macOS Ollama, it is overridden in the cluster overlay.

---

## Running the Agent

**1. Sync in ArgoCD:**

In the ArgoCD UI, click `flink-agents` → **Sync** → **Synchronize**. The `wait-for-ollama` initContainer will block until Ollama is reachable before the Flink job starts.

**2. Tail Flink agent output:**

```bash
kubectl logs -n flink -l component=taskmanager,app=flink-agents-workflow -f
```

This streams the TaskManager output, including agent actions, LLM responses, and `OutputEvent` results from the workflow DAG.

**3. Tail Ollama logs:**

```bash
tail -f /opt/homebrew/var/log/ollama.log
```

Shows incoming inference requests, model load times, and token generation as the agent calls Ollama.

---

## Option 1: In-Cluster Ollama (default)

Ollama runs as a Kubernetes Deployment in the `ollama` namespace, managed by ArgoCD at sync-wave 110 (before flink-agents at 121).

**Endpoint (default):** `http://ollama.ollama.svc.cluster.local:11434`

### The performance constraint on macOS

When running on Kind (Docker Desktop), Ollama runs inside a Linux VM. **Apple Silicon's GPU and Neural Engine are not accessible from inside the VM.** Inference is CPU-only regardless of the host hardware. This caps throughput significantly.

### Performance knobs (in-cluster)

| Setting | Where | Recommended value | Notes |
|---|---|---|---|
| CPU limits | `workloads/ollama/overlays/<cluster>/` | `8` | Match available cores on the node |
| `OLLAMA_NUM_THREADS` | Ollama Deployment env | `8` | Set to the number of physical CPU cores allocated |
| `OLLAMA_NUM_PARALLEL` | Ollama Deployment env | `1` | Keep at 1 for CPU-only; parallelism degrades CPU throughput |
| Model | `ollama-model-config` ConfigMap | `qwen3:1.7b` | Smaller model = dramatically faster on CPU (see Model section) |
| `requestTimeout` | `CustomTypesAndResources.java` | `300` | Allow 5 min per request for slow CPU inference |
| `NUM_ASYNC_THREADS` | `WorkflowSingleAgentExample.java` | `1` | Match Ollama's effective parallelism (1 for CPU-only) |

To add `OLLAMA_NUM_THREADS` and `OLLAMA_NUM_PARALLEL` to the running deployment, patch the Ollama Deployment in the overlay:

```yaml
# workloads/ollama/overlays/flink-demo/kustomization.yaml
patches:
  - target:
      kind: Deployment
      name: ollama
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/env/-
        value:
          name: OLLAMA_NUM_THREADS
          value: "8"
      - op: add
        path: /spec/template/spec/containers/0/env/-
        value:
          name: OLLAMA_NUM_PARALLEL
          value: "1"
```

---

## Option 2: Ollama on the Native macOS Host

Running Ollama natively on macOS gives access to Apple Silicon's GPU via Metal. This is the recommended approach for demo performance — expect 10–50x faster inference compared to CPU-only in-cluster.

### Install and start

```bash
brew install ollama
ollama serve          # starts on :11434, uses Metal automatically on Apple Silicon
ollama pull qwen3:8b  # or whichever model is configured (see Model section)
```

### Performance knobs (native macOS)

| Setting | How to set | Notes |
|---|---|---|
| `OLLAMA_NUM_PARALLEL` | `launchctl setenv OLLAMA_NUM_PARALLEL 2` or env before `ollama serve` | GPU handles concurrency well; start at 2 |
| `OLLAMA_FLASH_ATTENTION` | `OLLAMA_FLASH_ATTENTION=1 ollama serve` | Enables Flash Attention — significant speedup on Apple Silicon |
| Model | `ollama pull <model>` | Larger models are viable with GPU; see Model section |
| `NUM_ASYNC_THREADS` | `WorkflowSingleAgentExample.java` | Can increase to 2 when `OLLAMA_NUM_PARALLEL=2` |
| `requestTimeout` | `CustomTypesAndResources.java` | Can reduce to 60s with GPU-accelerated inference |

### Pointing Flink at the native host

Kind pods reach the macOS host via the DNS name `host.docker.internal` (provided by Docker Desktop). Override `OLLAMA_ENDPOINT` in the `flink-demo` overlay:

```yaml
# workloads/flink-agents/overlays/flink-demo/kustomization.yaml
patches:
  - target:
      kind: FlinkApplication
      name: flink-agents-workflow
      namespace: flink
    patch: |-
      - op: replace
        path: /spec/image
        value: quay.io/osowski/flink-agents-demo:<sha>
      - op: replace
        path: /spec/podTemplate/spec/initContainers/0/env/0/value
        value: http://host.docker.internal:11434
      - op: replace
        path: /spec/podTemplate/spec/containers/0/env/0/value
        value: http://host.docker.internal:11434
```

> **Note:** Both the `wait-for-ollama` initContainer and the `flink-main-container` carry the `OLLAMA_ENDPOINT` env var and must both be updated. The base manifest sets the default in-cluster endpoint; the overlay patches override it.

After syncing, verify the initContainer can reach the host:

```bash
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -n flink -- \
  curl -sf http://host.docker.internal:11434
# Expected: "Ollama is running"
```

---

## Model Selection and Flink Agent Impact

The model name is specified in **two places that must stay in sync**:

| Location | File | Value |
|---|---|---|
| What Ollama pulls | `workloads/ollama/base/ollama-model-config.yaml` (ConfigMap) | `qwen3:8b` |
| What the agent requests | `ReviewAnalysisAgent.java` `@ChatModelSetup` | `.addInitialArgument("model", "qwen3:8b")` |

If the model names do not match, Ollama will attempt to pull the requested model on-demand (slow) or fail if there is no internet access.

### Changing the model

1. Update the `ollama-model-config` ConfigMap in the Ollama overlay to pull the new model.
2. Update `ReviewAnalysisAgent.java` to request the same model name, then rebuild and push the image:
   ```bash
   # in osowski/flink-agents, branch k8s-main
   # edit: .addInitialArgument("model", "qwen3:1.7b")
   bash scripts/build-image.sh
   ```
3. Update the image SHA tag in `workloads/flink-agents/overlays/flink-demo/kustomization.yaml`.

### Model tradeoffs

| Model | Size (q4) | Inference speed (CPU) | JSON reliability | Recommended for |
|---|---|---|---|---|
| `qwen3:1.7b` | ~1.5 GB | Fast | Good | CPU-only, high-throughput demos |
| `qwen3:4b` | ~2.5 GB | Moderate | Very good | Balanced CPU performance |
| `qwen3:8b` | ~5 GB | Slow on CPU | Excellent | Native GPU, quality-first |

> The agent prompt instructs the model to return strict JSON with `id`, `score`, and `reasons` fields. Smaller models occasionally produce malformed JSON, causing the agent to throw `IllegalStateException` on parse failure. If this occurs, either switch to a larger model or add retry logic in `ReviewAnalysisAgent.processChatResponse`.
