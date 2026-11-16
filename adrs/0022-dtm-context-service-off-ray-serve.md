# 22. Device Trust Mesh Context Service Runs Off Ray Serve

Date: 2026-11-16

## Status

Accepted. Amends [ADR-0014](0014-rtce-style-context-engine-on-cp-kuberay.md): on eks-demo the context layer runs outside Ray Serve, and its REST routes are a production interface, not a debugging mirror.

## Context

[ADR-0014](0014-rtce-style-context-engine-on-cp-kuberay.md) put the context engine, `context-mcp`, inside the agents' `RayService`. On eks-demo ([#556](https://github.com/osowski/confluent-platform-gitops/issues/556), [#557](https://github.com/osowski/confluent-platform-gitops/issues/557)) that coupling costs four things:

- **Shared rollout.** A new image rebuilds the whole RayCluster, so a context change restarts every agent and an agent change reloads every context table.
- **Shared principal.** The agents and the context service authenticated as one Keycloak client, `sa-dtm-ray`, which could read `device.context`, `customer.context` and `device.risk-signals`. So "agents see business data only through the context service" held by convention, not by authorization. An earlier architecture review flagged this as finding F4.
- **A Ray dependency for a service that doesn't need Ray.** The context code is a FastAPI app that materializes Kafka topics. Hosting it on Serve ties it to KubeRay and to the Ray image.
- **No reach for other runtimes.** Agents of another runtime would call a Serve route.

The same review recommended hosting the context service on Ray Serve, in its own RayService or a separate Serve application set. This ADR supersedes that call for the context layer.

## Decision

On eks-demo, run the context service as a plain Kubernetes Deployment, `device-trust-mesh-context`, in the [`context-service`](../workloads/device-trust-mesh/components/context-service/) component of `workloads/device-trust-mesh`.

- **The same app under uvicorn.** The container runs `python -m dtm.mesh.context`, which builds the same FastAPI app as the Serve entry point and serves it with uvicorn. Ray isn't imported. The source and image are in [osowski/flink-sandbox `device-trust-mesh/`](https://github.com/osowski/flink-sandbox/tree/main/device-trust-mesh) ([osowski/flink-sandbox#76](https://github.com/osowski/flink-sandbox/issues/76)); the image is `quay.io/osowski/device-trust-mesh-context`, built at the same release as the other three.
- **Its own Service and probes.** Service `device-trust-mesh-context` on port 8080, sync wave 75 (before the RayService at 80, because agents wait for context at start). `/healthz` is the startup and readiness probe, and `/livez` the liveness probe.
- **Its own principal.** Keycloak client `sa-dtm-context`, group `dtm-context`, with read only on the three context topics, their Schema Registry subjects and the `dtm.context-mcp.` consumer groups. The three topics and their subjects are removed from `dtm-ray`, so agents lose direct read access to business data. F4 is closed on eks-demo.
- **REST is a production interface.** The UI and the session-reset job call the `/v1` routes, so they are more than a debugging mirror of the MCP tools. The MCP tools and the `/v1` routes keep their paths and shapes.
- **CPU autoscaling.** A HorizontalPodAutoscaler holds 2 to 4 replicas at 70% CPU, a PodDisruptionBudget keeps one replica available, and the rollout never removes a ready replica before its replacement is ready.
- **Cutover in one change.** The Serve application, the agents' `context.mcpUrl`, the UI and reset URLs, the RBAC and the image pins move together. No live migration: agents read `context.mcpUrl` when they start, and a teardown and rebuild is acceptable for this demo.
- **eks-demo only.** The flink-demo overlay keeps the Serve application. Device Trust Mesh is moving to eks-demo alone, so flink-demo isn't reworked.

## Alternatives Considered

| | Alternative | Why not |
|---|---|---|
| A | **The context service in its own RayService.** Keeps Serve's request-based autoscaling. | A second Ray head (1 CPU, 2 Gi) just to host one HTTP app, and KubeRay stays a dependency of the context layer. |
| C | **A separate Serve application and worker group in the agents' RayService.** The smallest change. | The context service still shares the agents' RayCluster, so an image bump rebuilds both, and the shared-rollout problem remains. |

## Consequences

**Positive**

- The context service and the agents roll independently. Restarting one doesn't fail tasks on the other, and each has its own pods, probes and metrics.
- Authorization enforces the data boundary: `sa-dtm-ray` can't read the context topics, and nothing else shares `sa-dtm-context`.
- Runtimes other than Ray reach the context service the same way, over MCP on a stable Service.
- The context layer doesn't depend on KubeRay.

**Negative / constraints**

- **No request-based autoscaling.** Ray Serve scaled by ongoing requests. The HorizontalPodAutoscaler scales on CPU, because no KEDA or Prometheus adapter is installed.
- **One more image** to build and pin, in the same release as the others, with a public Quay repository and a direct `fastapi` dependency.
- **One more Keycloak client and secret** (`sa-dtm-context`), created through Terraform's `dtm_clients` list and applied before the Argo CD sync.
- **Same restart cost as before.** Each replica still replays the compacted topics on start ([#458](https://github.com/osowski/confluent-platform-gitops/issues/458)).
- **flink-demo differs** until it is removed: it still hosts the context layer on Ray Serve under the shared principal.
