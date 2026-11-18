# 25. A Fluent Bit Sidecar for the Ray Agents' Logs

Date: 2026-11-18

## Status

Accepted.

## Context

The Device Trust Mesh agents run as Ray Serve replicas on the `mesh` workers of the `device-trust-mesh` RayService. Operators need to see what each agent is doing, task by task, with ordinary tools: `kubectl logs` and the Ray dashboard. The agents now log a per-task trail on their `dtm` loggers (osowski/flink-sandbox `device-trust-mesh/dtm/mesh/trail.py`); this decision is about getting it to both places.

How Ray 2.59.0 handles a replica's logs (`ray-2.59.0` source):

- Serve's `logging_config` configures only the `ray.serve` logger and stops it propagating (`python/ray/serve/_private/logging_utils.py:339-360`). App code reaches the replica log in `/tmp/ray/session_latest/logs/serve/` only through that logger, and the dashboard's replica view shows that file (`doc/source/serve/monitoring.md:36, 217-226`).
- Ray core writes every worker process's stdout and stderr to `worker-*.out` and `.err` files unless `RAY_LOG_TO_STDERR=1` (`python/ray/_private/node.py:1100-1111`). So `RAY_SERVE_LOG_TO_STDERR`, which is on by default (`serve/_private/constants.py:389`), writes to a file, not the container's output.
- With `RAY_LOG_TO_STDERR=1`, Ray stops writing log files, which breaks features that read them. Ray's KubeRay guide marks it "not recommended" and points to a Fluent Bit sidecar instead (`doc/source/cluster/kubernetes/user-guides/persist-kuberay-custom-resource-logs.md:23-84, 271-283`).
- Serve deletes `task_id`, `job_id` and two internal attributes from every replica log record, after writing Ray's own task id into `task_id` (`serve/_private/constants.py:415-420`, `logging_utils.py:110-123`). Its JSON formatter writes any other `extra` attribute, keeping a dict as a nested object (`python/ray/_common/formatters.py:15-27, 82`).

## Decision

- **Each mesh worker runs a Fluent Bit sidecar** (`cr.fluentbit.io/fluent/fluent-bit:5.1.5`).
  - It shares `/tmp/ray` with the `ray-worker` container through the `ray-logs` `emptyDir`, mounted read-only in the sidecar.
  - It tails `serve/replica_*.log` and prints each line to its stdout as JSON (`kubectl logs -c fluent-bit`). The config is the `device-trust-mesh-fluent-bit` ConfigMap.
  - Its position DB is on its own `fluent-bit-state` `emptyDir`, so a sidecar restart doesn't replay lines.
- **Every Serve application sets `logging_config: {encoding: JSON, log_level: INFO}`**, so each replica log line is one JSON object.
- **The agents hand their `dtm` records to `ray.serve`**, and every trail field goes in a nested `dtm` object, so `task_id` survives.
- **The head has no sidecar.** On eks-demo it advertises 0 CPU and runs no agent replica.

## Alternatives Considered

- **`RAY_LOG_TO_STDERR=1` on the Ray pods.** It puts everything in `kubectl logs` with no extra container. Rejected: Ray stops writing its log files, so the dashboard's log views lose the raylet, GCS and worker logs, and `kubectl logs` mixes in every Ray component's output.
- **A replica log handler that writes to `/proc/1/fd/1`,** the container's stdout. Rejected as an undocumented mechanism that could change or break.
- **Trail fields at the top level of the JSON line.** Rejected: Serve deletes `task_id`, and future Serve fields could collide with others.

## Consequences

- **A new external image**, and one more container on each mesh worker: 50m CPU, 64 Mi, with requests equal to limits so the pod keeps its Guaranteed QoS.
- **Both views show the same lines.** `kubectl logs -c fluent-bit` shows the trail, and the Ray dashboard keeps every log file.
- **Logs live in the pod.** They are lost when a worker pod is replaced. Shipping them to Loki or another store becomes a Fluent Bit output change.
- **The Serve controller's logs** (replica lifecycle) are on the head and stay dashboard-only.
- **Ray's replica log path is a contract.** If a Ray upgrade moves `serve/replica_*.log` or changes the attribute filter, the sidecar config and the flink-sandbox tests that pin the filter must change with it.
