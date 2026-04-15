# Flink Agents — Deployment & Performance Guide

This workload deploys both the [Flink Agents Workflow agent quickstart](https://nightlies.apache.org/flink/flink-agents-docs-release-0.2/docs/get-started/quickstart/workflow_agent/) and the [Flink Agents ReAct agent quickstart](https://nightlies.apache.org/flink/flink-agents-docs-release-0.2/docs/get-started/quickstart/react_agent/) as a CMF-managed `FlinkApplication` on the `flink-demo` cluster, using Ollama as the local LLM backend.

---

## Agent Source

The agents source is maintained in a fork, located at https://github.com/osowski/flink-agents/tree/k8s-main. The images, built with the `scripts/build-image.sh` script, are hosted under [quay.io/osowski/flink-agents-demo](https://quay.io/repository/osowski/flink-agents-demo).

Source modifications enable parameterization the upstream examples don't require: `OLLAMA_ENDPOINT` (can't assume `localhost` in Kubernetes) and `OLLAMA_MODEL` (runtime-configurable without rebuilding). Both are set as env vars on the `FlinkApplication` podTemplate.

---

## Architecture

```
flink-agents-workflow (flink ns)        flink-agents-react (flink ns)
  └─ ReviewAnalysisAgent                  └─ ReActAgent
       └─ OLLAMA_ENDPOINT ──────────────────────────────► Ollama (ollama ns / macOS host)
       └─ OLLAMA_MODEL                                        └─ qwen3:8b (or configured model)
```

Both FlinkApplications share the same image and Ollama configuration. `OLLAMA_ENDPOINT` controls where inference requests are sent — defaulting to the in-cluster Ollama service, overridden per cluster overlay for native macOS. Only one agent should be running at a time to avoid Ollama resource contention.

---

## Running the Agent

**1. Sync in ArgoCD:**

The `flink-agents` Application manages two FlinkApplications (`flink-agents-workflow` and `flink-agents-react`). **Only sync one at a time** — running both concurrently will contend for the same Ollama instance and degrade inference throughput for both.

In the ArgoCD UI, click `flink-agents` → **Sync**, then select only the resource you want to run:
- `FlinkApplication/flink-agents-workflow` — Workflow agent quickstart
- `FlinkApplication/flink-agents-react` — ReAct agent quickstart

The `wait-for-ollama` initContainer will block until Ollama is reachable before the Flink job starts. To stop a running agent, set `spec.job.state: suspended` in the overlay patch or delete the FlinkApplication resource in ArgoCD before syncing the other.

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

> [!WARNING]
> **The performance constraint on macOS**
>
> When running on Kind (Docker Desktop), Ollama runs inside a Linux VM. **Apple Silicon's GPU and Neural Engine are not accessible from inside the VM.** Inference is CPU-only regardless of the host hardware. This caps throughput significantly.

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
brew services run ollama # starts on :11434, uses Metal automatically on Apple Silicon
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

Kind pods reach the macOS host via the DNS name `host.docker.internal` (provided by Docker Desktop). Include the `ollama-host-mode` Kustomize component in the cluster overlay:

```yaml
# workloads/flink-agents/overlays/flink-demo/kustomization.yaml
components:
  - ../../components/ollama-host-mode
```

This component patches both the `wait-for-ollama` initContainer and `flink-main-container` `OLLAMA_ENDPOINT` values to `http://host.docker.internal:11434`. To revert to in-cluster Ollama, remove the `components:` entry.

After syncing, verify the initContainer can reach the host:

```bash
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -n flink -- \
  curl -sf http://host.docker.internal:11434
# Expected: "Ollama is running"
```

---

## Model Selection and Flink Agent Impact

The model name must be kept in sync across **two separate locations**. These are owned by different ArgoCD Applications (`ollama` and `flink-agents`) in different namespaces — Kustomize has no mechanism to share a value across separate Applications, so this is an intentional convention rather than a technical enforcement:

| Location | File | Key |
|---|---|---|
| What Ollama pulls | `workloads/ollama/base/model-config.yaml` (ConfigMap `data.models`) | `qwen3:8b` |
| What the agent requests | `workloads/flink-agents/base/flink-application.yaml` (env var) | `OLLAMA_MODEL: qwen3:8b` |

If the model names do not match, Ollama will attempt to pull the requested model on-demand (slow) or fail if there is no internet access.

> **Per-cluster overrides:** To change the model for a specific cluster, patch **both** the `ollama-model-config` ConfigMap in `workloads/ollama/overlays/<cluster>/` and the `OLLAMA_MODEL` env var in `workloads/flink-agents/overlays/<cluster>/`. Always update both together.

### Changing the model

1. Patch the `ollama-model-config` ConfigMap in the Ollama cluster overlay:
   ```yaml
   # workloads/ollama/overlays/flink-demo/kustomization.yaml
   patches:
     - target:
         kind: ConfigMap
         name: ollama-model-config
       patch: |-
         - op: replace
           path: /data/models
           value: |
             qwen3:1.7b
   ```
2. Patch `OLLAMA_MODEL` in the flink-agents cluster overlay:
   ```yaml
   # workloads/flink-agents/overlays/flink-demo/kustomization.yaml
   patches:
     - target:
         kind: FlinkApplication
         name: flink-agents-workflow
       patch: |-
         - op: replace
           path: /spec/podTemplate/spec/containers/0/env/1/value
           value: qwen3:1.7b
   ```
3. Sync the `ollama` ArgoCD Application first to pull the new model, then sync `flink-agents`.

### Model tradeoffs

| Model | Size (q4) | Inference speed (CPU) | JSON reliability | Recommended for |
|---|---|---|---|---|
| `qwen3:1.7b` | ~1.5 GB | Fast | Good | CPU-only, high-throughput demos |
| `qwen3:4b` | ~2.5 GB | Moderate | Very good | Balanced CPU performance |
| `qwen3:8b` | ~5 GB | Slow on CPU | Excellent | Native GPU, quality-first |

> The agent prompt instructs the model to return strict JSON with `id`, `score`, and `reasons` fields. Smaller models occasionally produce malformed JSON, causing the agent to throw `IllegalStateException` on parse failure. If this occurs, either switch to a larger model or add retry logic in `ReviewAnalysisAgent.processChatResponse`.
