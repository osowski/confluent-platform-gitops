# Agentic Device Trust Mesh

An agent mesh that manages **trusted customer devices** (browsers, phones, tablets) at a large financial institution, running on Confluent Platform, CP Flink and KubeRay on the `flink-demo` cluster. Agents enrol, deny, challenge and revoke devices. Every hand-off between them is an [A2A](https://a2a-protocol.org/latest/specification/) message on Kafka, so the whole conversation is visible in Control Center and queryable from Flink SQL.

Work is tracked in [Epic #441](https://github.com/osowski/confluent-platform-gitops/issues/441). Agent, simulator and `context-mcp` source lives in [osowski/flink-sandbox `device-trust-mesh/`](https://github.com/osowski/flink-sandbox/tree/main/device-trust-mesh).

> [!NOTE]
> This workload is scaffolding. The topics, schemas, Flink tables, the device and customer context statements, runtime ConfigMaps and the Flink environment, catalog, database and shared compute pool deploy today. The remaining Flink statements, `RayService` and simulator arrive in the Epic's follow-up stories. Measured results are marked *to be recorded*.

---

## The Pattern

| Layer | Role | Implemented by |
|---|---|---|
| **Durable coordination** | Every request, hand-off, task state change, decision, LLM exchange, side effect and audit record is a Kafka event. Agent-to-agent traffic uses **A2A v1.0 over Kafka**. Agents never call each other directly. | Confluent Platform (CFK) |
| **Trusted current context** | Device activity becomes always-current per-device and per-customer state, plus anomaly signals. | CP Flink SQL via CMF on a shared compute pool |
| **Bounded reasoning and action** | Each agent has a narrow job and a closed set of outputs, and reads business data **only** through RTCE-style MCP context tools. | Ray Serve agents on KubeRay (`RayService`) |

Context is produced by Flink, materialized for millisecond lookup, consumed by agents, and agent outcomes flow back into context. *Enterprise* here means **high-scale, low-touch**: growing the mesh is an Agent Card, a topic subscription and config, not new wiring.

### Two Planes

| Plane | Topics | How agents touch it |
|---|---|---|
| **Agent plane** (the meta-layer of agentic activity) | `agent.tasks.*`, `agent.task-events`, `agent.cards`, `agent.llm-interactions` | Kafka clients, directly, through the shared `AgentBus` wrapper |
| **Business-data plane** | `device.events`, `device.context`, `customer.context`, `device.risk-signals` | Never consumed. Read only through the `context-mcp` FastMCP tools |
| **Business side effects / records** | `device.policy-commands`, `audit.log` | Produce only |

The split follows Google's [Way Back Home Level 5 codelab](https://codelabs.developers.google.com/way-back-home-level-5/instructions) and Confluent's [Why Google's Agent2Agent Protocol Needs Apache Kafka](https://www.confluent.io/blog/google-agent2agent-protocol-needs-kafka/): A2A over Kafka for agents, with MCP kept separate for context. See [ADR-0015](../../adrs/0015-a2a-over-kafka-agent-communication.md).

---

## Architecture

```
                 ┌──────────────────────────── Kafka (CFK, flink-demo) ─────────────────────────────┐
                 │  BUSINESS-DATA PLANE                         AGENT PLANE (A2A v1.0 over Kafka)   │
 Device sim ──►  │  device.events ──► Flink SQL ──► device.context   (compact)                      │
   ▲             │                     │            customer.context (compact)                      │
   │             │                     │            device.risk-signals                             │
   │             │                     └──────────────────────────────► agent.tasks.risk (SendMessage)│
   │             │                                                     agent.tasks.enrolment         │
   │             │                                                     agent.tasks.step-up           │
   │             │                                                     agent.tasks.revocation        │
   │             │                                                     agent.task-events (reply)     │
   │             │                                                     agent.cards (compact)         │
   │             │                                                     agent.llm-interactions        │
   │             │  device.policy-commands ◄── agents (produce only)                                  │
   │             │  audit.log             ◄── compliance (produce only)                               │
   │             │  *_human_readable      ◄── Flink views over agent plane (Avro, for C3 + SQL)       │
   │             └───────────────────────────────────────────────────────────────────────────────────┘
   │                       │ context topics                         ▲ │  agent plane (Kafka clients)
   │        ┌──────────────▼──────── RayService: device-trust-mesh ─┼─▼──────────────────────────┐
   │        │ context-mcp (N replicas)                    agents (A2A servers + clients)        │
   │        │   materializer → in-memory table  ◄─ MCP ──  risk · enrolment · step-up ·          │
   │        │   FastMCP context tools                      compliance · revocation (disabled)    │
   │        └───────────────────────────────────────────────────────────────────────────────────┘
   └──────── device.policy-commands  (Flink also folds them back into device.context)

 Hand-off: Agent A ──produce A2A SendMessage──► agent.tasks.<B> ──consume (B's group)──► Agent B
           Agent B ──produce Task / status / artifact events──► agent.task-events ──► requester, Compliance, Flink views
 Business data: Agent ──MCP tool call──► context-mcp   (agents never consume business topics)
```

| Component | Runtime | Notes |
|---|---|---|
| Device simulator | `Deployment` `device-simulator` (`replicas: 0` by default) | Produces `device.events` for a pool bounded by `DEVICE_CAP`; consumes `device.policy-commands` and `simulator.control`. |
| Flink statements | `FlinkStatement` CRs on `dtm-shared-pool` | Context, risk signals, the A2A task router, human-readable views. |
| `context-mcp` | Ray Serve deployment | Materializer + FastMCP context tools. Scale reads by adding replicas. |
| Agents | Ray Serve deployments | Risk, Enrolment, Step-up, Compliance, Revocation (disabled). |
| KubeRay operator | [`kuberay-operator`](../kuberay-operator/) Application (wave 117, opt-in) | Provides `ray.io/RayService`. |
| LLM | Native macOS Ollama (default) or in-cluster Ollama | Same pattern as [Flink Agents](../flink-agents/README.md). |

---

## A2A over Kafka

A2A v1.0 defines JSON-RPC, gRPC and HTTP+JSON transports but no Kafka binding, so the mesh defines one.

| A2A concept | Kafka mapping |
|---|---|
| Server endpoint | Request topic `agent.tasks.<agent>`, consumed under group `dtm.<agent>.live` |
| `SendMessage` | JSON-RPC 2.0 request object as the record value; non-blocking |
| Responses | `Task`, `TaskStatusUpdateEvent` and `TaskArtifactUpdateEvent` on the topic in the `a2a-reply-topic` header, which is the shared `agent.task-events` |
| Correlation | `contextId` = mesh correlation id, mirrored in the `a2a-correlation-id` header |
| Task continuation | A follow-up `SendMessage` carrying an existing `taskId` |
| Discovery | `AgentCard` per agent on compacted `agent.cards` (key = agent name): published when the agent is enabled, tombstoned when disabled |
| Record key | `device_id` (per-device ordering); agent name on `agent.cards` |
| Wire format | Plain JSON (UTF-8), **no** Schema Registry wire prefix. Producers validate against the topic's `<topic>-a2a` subject before producing |

### Record Shapes

Field names are protojson camelCase and enums are strings (`ROLE_USER`, `TASK_STATE_COMPLETED`). Optional members are omitted, never `null`.

| Topic | Record value |
|---|---|
| `agent.tasks.<agent>` | `{"jsonrpc":"2.0","id":<messageId>,"method":"SendMessage","params":{"message":{…}}}`. The `message` carries `messageId`, `contextId`, `role`, `extensions: ["urn:device-trust-mesh:envelope:v1"]`, `metadata` with the envelope, `parts`, and optionally `taskId` and `referenceTaskIds` |
| `agent.task-events` | `{"jsonrpc":"2.0","id":<request id>,"result":{…}}`, where `result` holds exactly one of `task`, `statusUpdate` or `artifactUpdate`, each with the envelope in its own `metadata` |
| `agent.cards` | An A2A `AgentCard`. `supportedInterfaces[0]` is `{"url":"kafka://kafka.kafka.svc.cluster.local:9071/agent.tasks.<name>","protocolBinding":"urn:device-trust-mesh:kafka:v1","protocolVersion":"1.0"}`, and `capabilities.extensions` lists the envelope URI |

**Part order is part of the binding.** On every request message and every artifact, `parts[0]` is the typed `data` part (`"mediaType":"application/json"`) and `parts[1]` is a `text` summary. The JSON Schemas pin the order with `prefixItems`, and the Flink tables and views read the parts by position.

### Payloads

`parts[0].data` per topic and artifact name. Required fields are **bold**.

| Payload | Carried on | Fields |
|---|---|---|
| `AssessEnrolmentRequest` | `agent.tasks.risk` | **deviceId**, **customerId**, **requiredContextSeq**, **fingerprintSummary** |
| `DecideEnrolmentRequest` | `agent.tasks.enrolment` | **taskType** (`DECIDE_ENROLMENT` / `REMOVE_TRUST` / `RESOLVE_CHALLENGE`), **deviceId**, customerId, riskAssessment {score, rationale, signalIds[], llmInteractionId}, enrolmentTaskId, challengeResult (`PASSED` / `FAILED`) |
| `StepUpRequest` | `agent.tasks.step-up` | **enrolmentTaskId**, **reason**, signalIds[] |
| `RevocationRequest` | `agent.tasks.revocation` | **deviceId**, **reason** |
| `risk-assessment` | `agent.task-events` artifact | **score** (0–100), **rationale**, **signalIds[]**, **asOf** {contextSeq, materializedAt (epoch millis), sourceOffsets [{topic, partition, offset}]} |
| `enrolment-decision` | `agent.task-events` artifact | **outcome** (`GRANTED` / `DENIED` / `CHALLENGED` / `READ_ONLY` / `REMOVED`), **policyAction** (`ALLOW` / `BLOCK` / `READ_ONLY` / `CHALLENGE`), **rationale**, riskScore, guardrails[], asOf |
| `step-up-challenge` | `agent.task-events` artifact | **method** (`MFA_PUSH` / `BIOMETRIC` / `OTP`), **enrolmentTaskId** |
| `audit-record` | `agent.task-events` artifact | **auditId**, **subjectTaskId** |

The `agent.task-events` schema selects the artifact payload by `artifact.name`.

### Envelope

The mesh envelope rides inside A2A's own extension points. Messages declare `extensions: ["urn:device-trust-mesh:envelope:v1"]`, and the envelope lives under that key in `metadata` on `Message`, `Task` and the update events. Each message carries one typed `data` part plus a `text` part with a readable summary.

| Field | Meaning |
|---|---|
| `messageId` | Deterministic for agent outputs: UUIDv5 of `(agent_id, causation_id, config_version, output_index)` |
| `contextId` | Correlation id minted by the simulator per device request |
| `taskId` | Deterministic: UUIDv5 of `(agent_id, first input messageId)` |
| `referenceTaskIds` | Task(s) that caused this one |
| `causationId` | `messageId` of the message that caused this one |
| `agentId` / `agentVersion` | `flink:<statement>` or `agent:<name>`; image tag or statement name |
| `configVersion` | Hash of the effective agent config and prompts |
| `eventTime` | Producer-assigned epoch millis |
| `deviceId`, `customerId`, `deviceSeq`, `requiredContextSeq` | Filtering and the context watermark |
| `mode`, `replayRunId` | `LIVE` / `REPLAY` |

The envelope's `messageId` and `correlationId` equal the record's A2A `messageId` and `contextId` where those exist, so every envelope is self-contained; status and artifact events have no A2A `messageId` of their own. Kafka headers mirror `a2a-correlation-id`, `a2a-message-id`, `a2a-reply-topic`, `dtm-agent-id` and `dtm-mode`. Business-plane Avro records carry the same envelope as a typed `envelope` field, so device events, context, the A2A conversation and the audit trail all join on the correlation id.

Ids that a Flink statement derives are a `DTM_ID`: the SHA-1 of the statement name and the record's identifying inputs joined with `|`, laid out as a UUID (`h[1..8]-h[9..12]-5h[14..16]-8h[18..20]-h[21..32]`). The `5` and `8` give it the UUIDv5 shape, but it is not an RFC 9562 UUIDv5, because no namespace is hashed. A `DTM_ID` is a fingerprint. The same inputs always give the same id, so consumers dedupe and cross-reference on it: a risk assessment's `signalIds[]` match `signal_id` in `device.risk-signals`. Nothing can be decoded from the id, and the meaning is in the record's own fields. Each statement's inputs are listed with that statement in this README and in `base/flink-statements.yaml`.

### Task Lifecycle

Each agent owns one A2A `Task` per request:

`TASK_STATE_SUBMITTED` → `TASK_STATE_WORKING` → artifact (`risk-assessment`, `enrolment-decision`, `step-up-challenge`, `audit-record`) → `TASK_STATE_COMPLETED`.

A guardrail denial ends in `TASK_STATE_REJECTED`. While a step-up challenge is outstanding, the enrolment task waits in `TASK_STATE_AUTH_REQUIRED`. The challenge result resumes it by `taskId`.

---

## Context Engine (RTCE Parallel)

Confluent Cloud's Real-Time Context Engine keeps a materialized table per topic and serves millisecond lookups to agents over MCP. `context-mcp` is the Confluent Platform + KubeRay equivalent. See [ADR-0014](../../adrs/0014-rtce-style-context-engine-on-cp-kuberay.md).

- **Materializer.** Each replica loads `device.context`, `customer.context` and the last 50 `device.risk-signals` per device into memory. It uses manual partition assignment from the earliest offset, with offsets held alongside the data. A replica reports ready only after catching up.
- **Kafka is the durable store.** The compacted context topics keep the latest value per key indefinitely. A restart re-reads them, which takes seconds at demo scale.
- **Tools** (FastMCP, streamable HTTP, at `device-trust-mesh-serve-svc:8000/context-mcp/mcp`):

  | Tool | Returns |
  |---|---|
  | `get_device_context(device_id, min_seq?)` | Device context + `as_of` |
  | `get_customer_context(customer_id)` | Customer context incl. device list |
  | `list_risk_signals(device_id, limit?)` | Recent risk signals |
  | `list_devices(customer_id?, trust_status?)` | Scan (bounded by `DEVICE_CAP`) |

- **Watermark.** `min_seq` waits up to 2 s for the replica to reach the device's `requiredContextSeq`, then returns `STALE`, which agents retry. Agents copy `as_of` into their decision artifacts.

> [!NOTE]
> **Production.** A production deployment would add persistent backing to the serving layer: a snapshot plus stored offsets, so a restart resumes from the snapshot instead of re-reading every topic. See [#458](https://github.com/osowski/confluent-platform-gitops/issues/458).

---

## Topic and Schema Catalogue

Kubernetes object names can't contain `_`, so each `KafkaTopic` uses a DNS-safe `metadata.name` and puts the real topic in `spec.name`. All topics have 3 replicas.

| Topic (`spec.name`) | `metadata.name` | Plane | Format | Partitions | Cleanup / retention |
|---|---|---|---|---|---|
| `device.events` | `device-events` | business | Avro | 6 | delete, 7d |
| `device.context` | `device-context` | business | Avro | 6 | compact |
| `customer.context` | `customer-context` | business | Avro | 6 | compact |
| `device.risk-signals` | `device-risk-signals` | business | Avro | 6 | delete, 7d |
| `device.policy-commands` | `device-policy-commands` | side effect | Avro | 6 | delete, 7d |
| `audit.log` | `audit-log` | record | Avro | 6 | delete, retained indefinitely |
| `agent.tasks.risk` | `agent-tasks-risk` | agent | A2A JSON | 6 | delete, 7d |
| `agent.tasks.enrolment` | `agent-tasks-enrolment` | agent | A2A JSON | 6 | delete, 7d |
| `agent.tasks.step-up` | `agent-tasks-step-up` | agent | A2A JSON | 6 | delete, 7d |
| `agent.tasks.revocation` | `agent-tasks-revocation` | agent | A2A JSON | 6 | delete, 7d |
| `agent.task-events` | `agent-task-events` | agent | A2A JSON | 6 | delete, 7d |
| `agent.cards` | `agent-cards` | agent | A2A JSON | 1 | compact |
| `agent.llm-interactions` | `agent-llm-interactions` | agent | Avro | 6 | delete, 7d |
| `agent.tasks_human_readable` | `agent-tasks-human-readable` | derived | Avro | 6 | delete, 7d |
| `agent.decisions_human_readable` | `agent-decisions-human-readable` | derived | Avro | 6 | delete, 7d |
| `agent.task-status_human_readable` | `agent-task-status-human-readable` | derived | Avro | 6 | delete, 7d |
| `agent.cards_human_readable` | `agent-cards-human-readable` | derived | Avro | 1 | compact |
| `simulator.control` | `simulator-control` | control | Avro | 1 | delete, 1d |

### Schemas

Every subject is a CFK `Schema` CR (wave 35) in [`base/schemas.yaml`](base/schemas.yaml), backed by a generated ConfigMap. 21 subjects in all, `BACKWARD` compatibility:

| Topics | Subjects | Format | Producer wire format |
|---|---|---|---|
| All business and derived topics | `<topic>-value` | Avro, namespace `io.confluent.dtm` | Schema Registry (Avro serializer) |
| `device.context`, `customer.context`, `agent.cards_human_readable` | also `<topic>-key`: a record holding `device_id` / `customer_id` / `agent` | Avro | Schema Registry |
| `agent.tasks.*`, `agent.task-events`, `agent.cards` | `<topic>-a2a` | JSON Schema draft 2020-12 | Plain JSON |

- **Avro.** Every value schema starts with the shared `envelope` record, and enums cover the closed sets (`EventType`, `PolicyAction`, `TrustStatus`, `SignalType`, `Severity`, `Mode`, …). Fields written by Flink are nullable. Key fields live only in the `-key` subject, so inferred column names never collide.
- **A2A.** Schemas are derived from the pinned A2A v1.0.1 JSON Schema bundle. Each is narrowed to the mesh binding: the JSON-RPC wrapper, envelope metadata required, `parts` pinned to `[data, text]`, and `data` typed per topic or per artifact name. The snake_case aliases are dropped because the mesh emits camelCase only.
- **Why `-a2a` and not `-value`.** The Flink catalog only infers tables from `<topic>-value`, and CMF can't map JSON Schema tuple arrays (`prefixItems`). A `-value` subject would make the catalog fail to load the table at all. Under `-a2a` the A2A tables infer as `raw` instead (see [Tables](#tables)).

Schemas are generated, never hand-edited:

| Path | Contents |
|---|---|
| `schemas/upstream/a2a-v1.0.1.json` | Unmodified bundle from `https://a2a-protocol.org/v1.0.1/spec/a2a.json`. The generator checks its SHA-256 |
| `schemas/src/avro/*.avsc` | Avro sources. `envelope.avsc` is inlined wherever a field has type `io.confluent.dtm.Envelope` |
| `schemas/src/a2a/*.json` | The envelope and payload JSON Schemas used to narrow A2A |
| `base/schemas/{avro,a2a}/*` | Generated output, committed, consumed by `configMapGenerator` |

```bash
python3 -I scripts/generate-dtm-schemas.py           # regenerate base/schemas/
python3 -I scripts/generate-dtm-schemas.py --check   # exit 1 and list drifted files
python3 -I -m unittest discover -s scripts/tests -v  # generator tests
```

---

## Flink

The object chain mirrors [Colors and Shapes](../colors-and-shapes/README.md): `dtm-env` → `dtm-catalog` → `dtm-database` → `dtm-shared-pool` → `FlinkStatement`s, in namespace `device-trust-mesh`. `spec.statement` is immutable once running, so SQL changes ship as new versioned statements (`-v2`).

### Shared Compute Pool

Every statement runs on **`dtm-shared-pool` (`type: SHARED`)**: one long-lived Flink session cluster, sized at JM 1 GiB plus one 3 GiB TaskManager with 8 slots. That replaces one dedicated cluster per statement. Shared pools fit many low-throughput queries, and they keep statement state across stop/resume on CMF ≥ 2.4.2 (this repo runs 2.4.4).

- `spec.type` can't be changed after creation.
- Pool updates are blocked while any statement on the pool is `PENDING`, `RUNNING`, `STOPPED` or `FAILING`.
- If one statement starves the others, move it to its own `DEDICATED` pool with a new versioned statement.

### Tables

`dtm-catalog` infers one table per topic from its Schema Registry subjects. The `dtm-ddl-*` statements (wave 65, in [`base/flink-ddl.yaml`](base/flink-ddl.yaml)) each run one `ALTER TABLE … ADD` and finish `COMPLETED`.

| Table | Structure | Key / changelog | Added by `dtm-ddl-*` |
|---|---|---|---|
| `device.events` | Inferred Avro | raw `key`, append | `kafka_partition`, `kafka_offset` (metadata), `proc_time AS PROCTIME()` |
| `device.policy-commands`, `device.risk-signals`, `audit.log`, `agent.llm-interactions`, `simulator.control`, `agent.tasks_human_readable`, `agent.decisions_human_readable`, `agent.task-status_human_readable` | Inferred Avro | raw `key`, append | — |
| `device.context`, `customer.context`, `agent.cards_human_readable` | Inferred Avro with a typed key | PK `device_id` / `customer_id` / `agent`, upsert | — |
| `agent.tasks.{risk,enrolment,step-up,revocation}` | `raw` `key` / `val` + computed columns | raw `key`, append | `headers MAP<STRING, BYTES> METADATA`, task columns, `proc_time` |
| `agent.task-events` | `raw` + computed columns | raw `key`, append | event columns, `proc_time` |
| `agent.cards` | `raw` + computed columns | PK `key`, upsert (compacted) | card columns |

Computed columns are `JSON_VALUE` / `JSON_QUERY` over `CAST(val AS STRING)`. `env_event_time`, `env_device_seq` and `env_required_context_seq` are `BIGINT` via `TRY_CAST(JSON_VALUE(…) AS BIGINT)`, so text that is not a plain number (an ISO timestamp, or a float that `JSON_VALUE` renders as `1.79332393777E12`) becomes `NULL` instead of failing the job (the views drop a record with a `NULL` `env_event_time` and pass a `NULL` sequence through); `*_json` and `reference_task_ids` hold JSON text; everything else is `STRING`:

- **Task tables:** `rpc_id`, `rpc_method`, `message_id`, `context_id`, `task_id`, `role`, `reference_task_ids`, `data_json` (`parts[0].data`), `summary` (`parts[1].text`), and the 13 envelope fields as `env_message_id` … `env_replay_run_id`.
- **`agent.task-events`:** `rpc_id`, `kind` (`task` / `statusUpdate` / `artifactUpdate`), `task_id`, `context_id`, `state`, `status_time` (ISO-8601 string), `status_text`, `artifact_id`, `artifact_name`, `artifact_data_json`, `artifact_text`, and the 13 `env_*` columns. Each is coalesced across the three result shapes.
- **`agent.cards`:** `card_name`, `card_version`, `card_description`, `skills_json` (skill names), `interface_url`, `protocol_binding`.

A DDL statement runs once and its CR is immutable. Re-creating it against a table that already has the columns fails, so table changes ship as a new `-v2` DDL CR that alters only the delta. If a `dtm-ddl-*` CR is deleted, Argo CD re-creates it and it fails; the recovery (drop the CR's columns, then re-sync) is in the [`base/flink-ddl.yaml`](base/flink-ddl.yaml) header.

### Statements

| Statement | Input → Output | Logic | Story |
|---|---|---|---|
| `dtm-device-context` | `device.events` ∪ `device.policy-commands` → `device.context` | Latest fingerprint, last geo, `context_seq` (max `device_seq`), `trust_status` | [#447](https://github.com/osowski/confluent-platform-gitops/issues/447) |
| `dtm-customer-context` | same → `customer.context` | Device count, trusted device count (latest action `ALLOW`), known countries, distinct non-`ALLOW` command count | [#447](https://github.com/osowski/confluent-platform-gitops/issues/447) |
| `dtm-risk-signals` | `device.events` → `device.risk-signals` | `COMPROMISED_OS`, `OUTDATED_OS`, `NEW_DEVICE_ESTABLISHED_ACCOUNT`, `IMPOSSIBLE_TRAVEL` | [#448](https://github.com/osowski/confluent-platform-gitops/issues/448) |
| `dtm-a2a-task-router` | `device.events` → `agent.tasks.risk`, `agent.tasks.enrolment` | The bank's A2A client: builds `SendMessage` requests | [#449](https://github.com/osowski/confluent-platform-gitops/issues/449) |
| `dtm-view-tasks` | `agent.tasks.*` → `agent.tasks_human_readable` | Unnests JSON-RPC and `parts` | [#450](https://github.com/osowski/confluent-platform-gitops/issues/450) |
| `dtm-view-decisions` | `agent.task-events` → `agent.decisions_human_readable` | One row per artifact | [#450](https://github.com/osowski/confluent-platform-gitops/issues/450) |
| `dtm-view-task-status` | `agent.task-events` → `agent.task-status_human_readable` | One row per state change | [#450](https://github.com/osowski/confluent-platform-gitops/issues/450) |
| `dtm-view-cards` | `agent.cards` → `agent.cards_human_readable` | Flattened Agent Cards | [#450](https://github.com/osowski/confluent-platform-gitops/issues/450) |

The context statements ([`base/flink-statements.yaml`](base/flink-statements.yaml), wave 70) are pure `GROUP BY` aggregates:

- **Ordering.** `LAST_VALUE` follows arrival order across the two input topics, not event time. That is acceptable at demo rates. Event times (`last_event_time`, `envelope.event_time`) use `MAX`, because `LAST_VALUE` does not accept `TIMESTAMP_LTZ` on Flink 1.19.
- **`trust_status`** comes from the device's latest policy command:

  | Latest command | `trust_status` |
  |---|---|
  | `ALLOW` | `TRUSTED` |
  | `READ_ONLY` | `READ_ONLY` |
  | `CHALLENGE` | `CHALLENGED` |
  | `BLOCK`, reason `UNENROLLED` | `UNENROLLED` |
  | other `BLOCK` | `BLOCKED` |
  | none yet, `ENROL_REQUESTED` seen | `PENDING` |
  | none yet, no enrolment request | `UNKNOWN` |

- **Command-only devices.** A device with commands but no events still gets a `device.context` row. Its fingerprint, geo and `context_seq` are null and its envelope comes from the latest command.
- **Commands carry `customer_id`.** Every `device.policy-commands` record an agent produces must carry `envelope.customer_id`; `dtm-customer-context` ignores a command without one, so it never counts toward `trusted_device_count` or `recent_anomaly_count`.
- **Duplicate commands.** `recent_anomaly_count` counts distinct non-`ALLOW` command message ids, so a re-produced command is counted once.
- **Intermediate counts.** One command can change both of a customer's counts. `customer.context` may then briefly show an in-between pair within one commit (for example `recent_anomaly_count` rises before `trusted_device_count` falls). The pair converges.
- **State TTL.** Statement state expires after 7 days without input for a key (`table.exec.state.ttl`). After more than 7 days without commands for a device, that device can stay counted in `trusted_device_count`, and the device's `trust_status` reverts once its next event arrives.
- **No tombstones.** Neither statement writes tombstones to the compacted topics: every update is an upsert. The header comment in `base/flink-statements.yaml` explains how.

### Ad-hoc Queries

Run these from the Flink SQL shell or the CMF UI against `dtm-catalog`.`dtm-database`:

```sql
-- Decisions for one device
SELECT envelope.device_id, agent, outcome, policy_action, risk_score, rationale
FROM `agent.decisions_human_readable`
WHERE envelope.device_id = 'dev-0007';

-- The A2A conversation for one request
SELECT envelope.event_time, from_agent, to_agent, task_type, summary
FROM `agent.tasks_human_readable`
WHERE envelope.correlation_id = '<correlation id>';

-- Which agents are in the mesh right now
SELECT agent, version, description, request_topic FROM `agent.cards_human_readable`;
```

---

## Device Cap

`DEVICE_CAP` in ConfigMap `device-trust-mesh-config` (default **20**) is the upper bound on unique device ids in a run. It is the only place to set it.

- The simulator draws ids from the fixed pool `dev-0001..dev-<DEVICE_CAP>`, so it can't exceed the cap.
- The `mesh-runtime` component's Kustomize `replacements` copy the value into the simulator and into the Ray head and worker containers.
- `context-mcp` exports `dtm_tracked_devices` and flags `dtm_device_cap_exceeded`.
- Partition counts are fixed at 6 and support caps up to 500. Agent replicas must stay ≤ 6.

---

## Agents

| Agent | Phase 1 | Consumes | Produces | LLM |
|---|---|---|---|---|
| Risk | Enabled | `agent.tasks.risk` | `risk-assessment` artifact, `SendMessage` → enrolment, LLM log | Score 0–100 + rationale |
| Enrolment | Enabled | `agent.tasks.enrolment` | `enrolment-decision` artifact, `SendMessage` → step-up, policy commands, LLM log | `DECIDE_ENROLMENT` only |
| Step-up | Enabled | `agent.tasks.step-up` | `step-up-challenge` artifact, `CHALLENGE` command | No |
| Compliance | Enabled | `agent.task-events` (observer) | `audit.log`, `audit-record` artifact | No |
| Revocation | **Disabled** | `agent.tasks.revocation` | decisions, policy commands | Placeholder |

Enabling Revocation publishes its Agent Card to `agent.cards`, which is the live "expand the mesh" moment. Routing work to it is [#457](https://github.com/osowski/confluent-platform-gitops/issues/457).

**Enrolment guardrails.**
- Before the LLM: `COMPROMISED_OS` → `DENY` without calling it, and an already-trusted device → idempotent `GRANT`.
- After the LLM: the output must be schema-valid with an allowed outcome, and `GRANT` above the risk threshold is coerced to `CHALLENGE`.
- Guardrail firings are recorded in the decision artifact.

### Phase 1 Enrolment Flow

Every arrow between agents is a Kafka hand-off: the sender produces an A2A `SendMessage` to the receiver's `agent.tasks.<name>`, and the receiver consumes it under its own group.

1. The simulator produces `ENROL_REQUESTED` to `device.events`.
2. Flink updates `device.context` / `customer.context`, emits any risk signals, and the router sends `SendMessage` to `agent.tasks.risk`.
3. **Risk** reads context through `context-mcp` and makes LLM call #1. It reports its task and `risk-assessment` on `agent.task-events`, then sends `SendMessage` to `agent.tasks.enrolment`.
4. **Enrolment** applies the guardrails and makes LLM call #2: `GRANT`, `DENY`, `CHALLENGE` or `GRANT_READ_ONLY`.
   - Non-challenge outcomes produce `ALLOW`, `BLOCK` or `READ_ONLY` to `device.policy-commands`.
   - `CHALLENGE` sets the task to `AUTH_REQUIRED` and sends `SendMessage` to `agent.tasks.step-up`.
5. **Step-up** sends a `CHALLENGE` policy command (`MFA_PUSH`, `BIOMETRIC` or `OTP`).
6. The simulator answers with `CHALLENGE_PASSED` or `CHALLENGE_FAILED`. The router resumes the enrolment task by `taskId`, and it ends in `ALLOW` or `BLOCK`.
7. **Compliance** writes one `audit.log` record per decision artifact. Flink folds the policy command back into `device.context.trust_status`.

**Unenrolment** is straight-through: `UNENROL_REQUESTED` → Enrolment (`REMOVE_TRUST`, deterministic) → `BLOCK` (reason `UNENROLLED`) → audit.

---

## Configuration Reference

All set per overlay.

| ConfigMap | Key | Default | Purpose |
|---|---|---|---|
| `device-trust-mesh-config` | `DEVICE_CAP` | `"20"` | Upper bound on unique devices per run |
| `device-trust-mesh-config` | `LLM_ENDPOINT` | `http://host.docker.internal:11434` | Interpolated into `agents.yaml` |
| `device-trust-mesh-agents` | `agents.yaml` | see below | LLM, per-agent enablement, bus and context settings |
| `device-trust-mesh-prompts` | `risk.v1`, `enrolment.v1`, `revocation.v1` | placeholders | Versioned prompts |

```yaml
llm:
  provider: ollama                 # ollama | openai-compatible | recorded (replay)
  endpoint: ${LLM_ENDPOINT}
  model: qwen3:4b
  options: { temperature: 0, seed: 42, think: false, num_ctx: 4096 }
agents:
  risk:       { enabled: true,  replicas: 1, promptRef: risk.v1,       llm: {} }  # llm: per-agent override
  revocation: { enabled: false, replicas: 1, promptRef: revocation.v1, llm: {} }
bus:
  startPosition: committed         # committed | earliest | offset | timestamp (replay)
  topicPrefix: ""                  # replay sets "replay.<run-id>."
  policyCommands: enabled          # enabled | redirect | disabled
  allowedConsume: [ "agent.tasks.<self>", "agent.task-events", "agent.cards" ]
```

- Agents reload these files at a message boundary, with no pod restart. Each output, and the agent's Agent Card, carries the resulting `configVersion`.
- `enabled: false` pauses the agent and tombstones its card.
- `replicas` maps to the Serve `num_replicas` in the `RayService`.

| Component | Effect |
|---|---|
| `components/mesh-runtime` | Adds the `RayService` and simulator, and the `DEVICE_CAP` replacements. Add it to the overlay once `kuberay-operator` is applied and images are published ([#451](https://github.com/osowski/confluent-platform-gitops/issues/451)). |
| `components/ollama-in-cluster-mode` | Switches `LLM_ENDPOINT` to `http://ollama.ollama.svc.cluster.local:11434` |

### Model Recommendation

Every agent uses the same Ollama model. The default is **`qwen3:4b`** with `think: false`; turning off Qwen3's thinking mode matters more for latency than model size. The fallback is **`qwen3:8b`**, the model [Flink Agents](../flink-agents/README.md) uses. `temperature: 0`, a fixed `seed` and schema-constrained output (`format`) keep decisions reproducible.

| Model | p50 / p95 (risk + enrolment) | Schema-valid rate |
|---|---|---|
| `qwen3:4b` | *to be recorded* ([osowski/flink-sandbox#31](https://github.com/osowski/flink-sandbox/issues/31)) | *to be recorded* |
| `qwen3:8b` | *to be recorded* | *to be recorded* |

---

## Running It

1. **Start native Ollama** and pull the model. See [Flink Agents: Ollama on the native macOS host](../flink-agents/README.md#option-1-ollama-on-the-native-macos-host-global-default):
   ```bash
   brew services run ollama
   ollama pull qwen3:4b
   ```
2. **Free resources** by suspending `colors-and-shapes` and `flink-agents` if they are running.
3. **Apply the KubeRay operator** (opt-in):
   ```bash
   kubectl apply -f clusters/flink-demo/workloads/kuberay-operator.yaml -n argocd
   kubectl get crd rayservices.ray.io
   ```
4. **Apply and sync the workload** (manual sync):
   ```bash
   kubectl apply -f clusters/flink-demo/workloads/device-trust-mesh.yaml -n argocd
   kubectl patch application device-trust-mesh -n argocd --type merge -p '{"operation":{"sync":{"syncStrategy":{"hook":{}}}}}'
   ```
   On a cluster that was bootstrapped before `device-trust-mesh` joined the Flink Kubernetes Operator's `watchNamespaces`, restart the operator once so it watches the new namespace. Otherwise the shared pool's `FlinkDeployment` never gets pods. See [Adding Applications](../../docs/adding-applications.md#2-flink-kubernetes-operators-watchnamespaces):
   ```bash
   kubectl rollout restart deployment/flink-kubernetes-operator -n operator
   ```
5. **Verify:**
   ```bash
   kubectl get kafkatopic -n device-trust-mesh
   kubectl get flinkenvironment,flinkkafkacatalog,flinkkafkadatabase,flinkcomputepool -n device-trust-mesh
   kubectl get schema -n device-trust-mesh          # 21 subjects, STATUS SUCCEEDED
   kubectl get flinkstatement -n device-trust-mesh  # dtm-ddl-* COMPLETED, dtm-*-context RUNNING
   kubectl get pods -n device-trust-mesh    # shared-pool JobManager; TaskManagers start once statements run
   ```
6. **Watch the mesh** once the runtime stories land:
   - Control Center topic browser: `agent.tasks.*`, `agent.task-events`, `*_human_readable`
   - The Ray dashboard
   - The ad-hoc queries above

   Scale `device-simulator` to 1 to start a run.

The full Phase 1 acceptance run is [#453](https://github.com/osowski/confluent-platform-gitops/issues/453).

---

## Replay Design

Replaying one agent from a chosen point in the stream is a later phase ([#454](https://github.com/osowski/confluent-platform-gitops/issues/454)). The architecture already supports it:

| Requirement | How |
|---|---|
| Kafka is the source of truth | Agents are stateless per message; challenge tasks resume by `taskId`; `context-mcp` rebuilds from topics |
| Envelope on every message | A2A `metadata` extension, enforced by `AgentBus` |
| Determinism | `temperature: 0`, `seed`, deterministic `messageId` / `taskId`, `configVersion` |
| Recorded LLM responses | `agent.llm-interactions`, keyed by `request_hash`; a `RecordedProvider` replays them |
| Replay window | 7d retention on inputs, compacted context topics, `audit.log` kept indefinitely |
| Separate consumer group | `dtm.<agent>.<mode>[.<run-id>]` |
| Replay-namespaced outputs | `bus.topicPrefix: "replay.<run-id>."`; replay requests name a prefixed `a2a-reply-topic` |
| Side effects | `bus.policyCommands: enabled \| redirect \| disabled` |

**Seeking.** `bus.startPosition: offset` assigns explicit `(partition, offset)` pairs. `bus.startPosition: timestamp` resolves a wall-clock time per partition with the consumer's `offsetsForTimes` and seeks there. Both run under the replay consumer group, so production offsets are never touched.

## Later Phases

- **UI layer:** agent traffic and device status via lightning-style queries against `context-mcp` ([#455](https://github.com/osowski/confluent-platform-gitops/issues/455)).
- **External A2A gateway:** an HTTP/JSON-RPC A2A endpoint mapping external `SendMessage` calls onto `agent.tasks.*` ([#456](https://github.com/osowski/confluent-platform-gitops/issues/456)).
- **Mesh expansion:** route compromised trusted devices to the Revocation agent ([#457](https://github.com/osowski/confluent-platform-gitops/issues/457)).

## References

- [A2A protocol specification (v1.0)](https://a2a-protocol.org/latest/specification/)
- [Way Back Home Level 5 codelab (A2A over Kafka)](https://codelabs.developers.google.com/way-back-home-level-5/instructions)
- [Why Google's Agent2Agent Protocol Needs Apache Kafka](https://www.confluent.io/blog/google-agent2agent-protocol-needs-kafka/)
- [ADR-0014: RTCE-style context engine on CP + KubeRay](../../adrs/0014-rtce-style-context-engine-on-cp-kuberay.md)
- [ADR-0015: A2A v1.0 over Kafka](../../adrs/0015-a2a-over-kafka-agent-communication.md)
- [Bootstrap procedure: live-testing a branch](../../docs/bootstrap-procedure.md#live-testing-an-unmerged-branch-on-a-cluster)
