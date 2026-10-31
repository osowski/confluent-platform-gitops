# 15. A2A v1.0 over Kafka for Agent-to-Agent Communication

Date: 2026-10-29

## Status

Accepted

## Context

The [Agentic Device Trust Mesh](../workloads/device-trust-mesh/README.md) ([Epic #441](https://github.com/osowski/confluent-platform-gitops/issues/441)) has to show a prospective customer three things about agent-to-agent communication:

- it is **transparent**: every hand-off is visible
- it is **durable and replayable**
- it uses a **cross-vendor standard**, not a bespoke protocol

The [A2A protocol](https://a2a-protocol.org/latest/specification/) (v1.0) defines the standard shapes: `AgentCard`, `Message`, `Task`, `TaskStatusUpdateEvent` and `TaskArtifactUpdateEvent`, plus JSON-RPC methods such as `SendMessage`. Its standard transports, though, are point-to-point (JSON-RPC, gRPC, HTTP+JSON). Point-to-point hand-offs are private, tightly coupled and hard to replay.

Two references put A2A on Kafka:

- [Google's Way Back Home Level 5 codelab](https://codelabs.developers.google.com/way-back-home-level-5/instructions): A2A messages over Kafka, with a request topic, a reply topic, and `correlation_id` / `reply_topic` headers.
- [Why Google's Agent2Agent Protocol Needs Apache Kafka](https://www.confluent.io/blog/google-agent2agent-protocol-needs-kafka/): agents act as Kafka producers and consumers under A2A, and MCP stays separate for tools and context.

Alternatives considered:

1. **Custom Avro task/decision schemas.** Typed, Flink-friendly and readable in Control Center, but proprietary to the mesh.
2. **An MCP-mediated coordination layer** (`coordination-mcp`), where agents never hold a Kafka client and call `receive`/`publish` tools instead. Rejected for three reasons:
   - it adds an extra hop to every hand-off
   - it makes the server stateful, a single point every message passes through
   - neither reference does it
3. **A2A over Kafka.** Chosen.

## Decision

- **Two planes.**
  - **Agent plane:** `agent.tasks.*`, `agent.task-events`, `agent.cards` and `agent.llm-interactions`. Agents use Kafka clients directly here, through the shared `AgentBus` wrapper.
  - **Business-data plane:** `device.events`, `device.context`, `customer.context` and `device.risk-signals`. Agents read this only through `context-mcp` ([ADR-0014](0014-rtce-style-context-engine-on-cp-kuberay.md)). `AgentBus` enforces a consume allow-list.
  - **Side effects:** agents write `device.policy-commands` and `audit.log` but never consume them.
- **The mesh's Kafka binding for A2A.** A2A defines none, so the mesh does:
  - Each agent's endpoint is its request topic, `agent.tasks.<agent>`, consumed under group `dtm.<agent>.live`.
  - A request is a JSON-RPC 2.0 `SendMessage` object and is non-blocking.
  - Responses (`Task`, status and artifact events) go to the topic named in the `a2a-reply-topic` header. That is the shared `agent.task-events` in Phase 1.
  - `contextId` is the mesh correlation id.
  - A follow-up `SendMessage` with an existing `taskId` resumes a task. The enrolment task waits in `TASK_STATE_AUTH_REQUIRED` during a step-up challenge.
  - Agent Cards live on the compacted `agent.cards` topic, keyed by agent: published when an agent is enabled, tombstoned when it is disabled.
  - Records are keyed by `device_id`.
- **The envelope travels inside A2A's extension points.** Messages declare `extensions: ["urn:device-trust-mesh:envelope:v1"]`, and the envelope fields live under that key in `metadata`. They include `causationId`, `agentId`, `configVersion`, `deviceSeq`, `requiredContextSeq` and `mode`. `messageId` and `taskId` are deterministic so replays reproduce them. Agents derive them as UUIDv5. Flink statements derive a UUID-shaped SHA-1 fingerprint (`DTM_ID`, defined in the use-case README) that hashes no namespace. Kafka headers mirror the routing fields.
- **Schemas.** A2A topics register JSON Schemas derived from the pinned A2A v1.0 schema, with `parts[].data` narrowed per topic to the typed payload. Business and derived topics use Avro.
- **Human-readable views.** Long-running Flink statements flatten the A2A JSON into Avro `*_human_readable` topics (`agent.tasks_human_readable`, `agent.decisions_human_readable`, `agent.task-status_human_readable`, `agent.cards_human_readable`). Control Center and ad-hoc Flink SQL can then read them directly, e.g. `SELECT envelope.device_id, outcome FROM agent.decisions_human_readable`.
- **Libraries.** `a2a-sdk` provides the types and validation. The codelab's `a2a-python-kafka` transport is a proof of concept and is not used.

## Consequences

**Positive**

- Every hand-off is a Kafka message: visible in Control Center, durable, auditable and replayable from any offset.
- The cross-vendor standard opens a path to outside agents. A later A2A HTTP gateway can map external `SendMessage` calls onto `agent.tasks.*` and serve cards from `agent.cards` ([#456](https://github.com/osowski/confluent-platform-gitops/issues/456)).
- Many consumers can read the same events: Compliance, the Flink views and the later UI all read `agent.task-events` without any agent knowing they exist.

**Negative**

- The A2A JSON nests the business fields (`params.message.parts[].data`). Readability depends on the `*_human_readable` views, which are four more Flink statements on the shared pool.
- The Kafka binding is the mesh's own convention, not part of the A2A spec. It is documented in the use-case README.
- The CMF Flink catalog cannot map the A2A JSON Schema's tuple arrays (`prefixItems`), so the A2A schemas are registered under `<topic>-a2a` subjects the catalog never reads. Flink reads and writes those topics as `raw` bytes, with typed computed columns declared by the `dtm-ddl-*` statements ([#449](https://github.com/osowski/confluent-platform-gitops/issues/449)).

**Neutral**

- On the anonymous `flink-demo` cluster, plane separation is enforced by convention plus `AgentBus`, not by broker ACLs. A secured cluster can enforce it with ACLs.
