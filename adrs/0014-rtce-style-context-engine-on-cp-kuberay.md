# 14. RTCE-Style Context Engine on Confluent Platform + KubeRay

Date: 2026-10-29

## Status

Accepted

## Context

The [Agentic Device Trust Mesh](../workloads/device-trust-mesh/README.md) ([Epic #441](https://github.com/osowski/confluent-platform-gitops/issues/441)) runs AI agents that make bounded decisions about customer devices: enrol, deny, challenge, revoke. Each decision needs **trusted current context**: the device's latest fingerprint and trust status, the customer's other devices, and recent anomaly signals. CP Flink computes that context continuously into compacted topics (`device.context`, `customer.context`) and an append topic (`device.risk-signals`).

Agents should not consume or replay those topics themselves. It would make every agent stateful, slow its start-up, and couple agent logic to topic layouts. Confluent Cloud solves this with the [Real-Time Context Engine](https://docs.confluent.io/cloud/current/ai/real-time-context-engine/overview.html) (RTCE). RTCE keeps a materialized table per topic, refreshed within seconds, and serves millisecond point lookups and scans to agents over MCP ("lightning queries"). RTCE is a Confluent Cloud service, so this demo needs an equivalent that runs on Confluent Platform and KubeRay.

Two failure modes matter most for the demo:

- the context layer returning **wrong** data (stale, or offsets out of step with the data)
- the context layer being **slower** than reading the topics directly

## Decision

Build the context engine as one Ray Serve deployment, `context-mcp`, inside the `device-trust-mesh` `RayService`.

- **Kafka is the durable store.** Each `context-mcp` replica materializes the compacted context topics, plus a bounded window of `device.risk-signals`, into an **in-memory table**. It uses manual partition assignment from the earliest offset, not a consumer group. Records and their source offsets are applied under the same lock, so a reader never sees data and offsets disagree. A replica reports ready only after catching up to the end offsets it saw at startup. There is no external database.
- **FastMCP is the agent interface.** The official `mcp` Python SDK serves `get_device_context`, `get_customer_context`, `list_risk_signals` and `list_devices`, plus a REST mirror for debugging. **Agents read business data only through these tools.** They never subscribe to business-data topics.
- **Read-your-writes watermark.** The simulator stamps a per-device `device_seq`. Flink carries `context_seq = max(device_seq)` on `device.context` and stamps `requiredContextSeq` on every routed task. `get_device_context(min_seq)` waits up to `waitTimeoutMs` (2 s) for the replica to catch up, then returns `STALE`, which agents retry. Every response carries `as_of` (seq, materialized-at, source offsets), and agents copy it into their decision artifacts.
- **Scale reads by adding replicas.** Each replica holds a full copy. The table is bounded by `DEVICE_CAP`.

## Consequences

**Positive**

- Lookups are in-process and in-memory, so p99 point lookups stay well under the cost of consuming a topic (target < 20 ms end to end over MCP).
- State is always rebuildable from Kafka, which keeps the mesh's replay guarantee: no hidden state.
- The same tools serve agents, an external MCP client pointed at live device state, and the later UI.

**Negative**

- Every replica restart re-reads the compacted topics from the beginning. That takes seconds at demo scale (`DEVICE_CAP` ≤ 500). A production deployment would add persistent backing to the serving layer (a snapshot plus stored offsets) so restarts resume from the snapshot. Offsets are already kept alongside the data so that backing can be added without changing the design ([#458](https://github.com/osowski/confluent-platform-gitops/issues/458)).
- `device.risk-signals` uses a delete policy, so signals older than its 7-day retention are lost on rebuild. That's acceptable for recent-activity context.
- The table must fit in memory, which is fine at demo scale and is the main limit for larger caps.

**Neutral**

- Phase 1 agents call context tools from code rather than letting the LLM choose them, for latency and determinism. LLM-driven tool use remains possible through the same MCP interface.

## Related

- [ADR-0015](0015-a2a-over-kafka-agent-communication.md): A2A over Kafka for agent-to-agent communication.
- `docs-cloud/ai/real-time-context-engine/lightning-queries.rst` (local Confluent docs clone): RTCE lightning queries.
