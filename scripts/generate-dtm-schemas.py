#!/usr/bin/env python3
"""Generate the device-trust-mesh Schema Registry schemas from their sources.

Reads workloads/device-trust-mesh/schemas/ and writes the registered schemas to
workloads/device-trust-mesh/base/schemas/, where Kustomize's configMapGenerator
picks them up:

  avro/<subject>.avsc  Avro sources with the shared Envelope record inlined.
  a2a/<topic>.json     A2A v1.0.1 JSON Schemas (draft 2020-12) narrowed to the
                       mesh's Kafka binding: JSON-RPC wrapper, required
                       envelope metadata, and parts[0].data typed per topic.

Usage:
  python3 -I scripts/generate-dtm-schemas.py            # write outputs
  python3 -I scripts/generate-dtm-schemas.py --check    # exit 1 on drift

Python 3 standard library only.
"""

import argparse
import copy
import hashlib
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
WORKLOAD = REPO / "workloads" / "device-trust-mesh"
UPSTREAM = WORKLOAD / "schemas" / "upstream" / "a2a-v1.0.1.json"
SRC_AVRO = WORKLOAD / "schemas" / "src" / "avro"
SRC_A2A = WORKLOAD / "schemas" / "src" / "a2a"
OUT_DIR = WORKLOAD / "base" / "schemas"

# SHA-256 of the unmodified bundle from https://a2a-protocol.org/v1.0.1/spec/a2a.json
A2A_SHA256 = "ba4b702b5edbdcbfe972c272484eb38e1fcd72af3c0b7eaa114b50e97455d8dd"

JSON_SCHEMA_DRAFT = "https://json-schema.org/draft/2020-12/schema"
ENVELOPE_URI = "urn:device-trust-mesh:envelope:v1"
ENVELOPE_AVRO_TYPE = "io.confluent.dtm.Envelope"
ENVELOPE_AVRO_SOURCE = "envelope.avsc"

# Avro source file -> Schema Registry subject (TopicNameStrategy).
SUBJECTS = {
    "device-event.avsc": "device.events-value",
    "policy-command.avsc": "device.policy-commands-value",
    "device-context-key.avsc": "device.context-key",
    "device-context.avsc": "device.context-value",
    "customer-context-key.avsc": "customer.context-key",
    "customer-context.avsc": "customer.context-value",
    "risk-signal.avsc": "device.risk-signals-value",
    "audit-record.avsc": "audit.log-value",
    "llm-interaction.avsc": "agent.llm-interactions-value",
    "simulator-control.avsc": "simulator.control-value",
    "task-hr.avsc": "agent.tasks_human_readable-value",
    "decision-hr.avsc": "agent.decisions_human_readable-value",
    "task-status-hr.avsc": "agent.task-status_human_readable-value",
    "card-hr-key.avsc": "agent.cards_human_readable-key",
    "card-hr.avsc": "agent.cards_human_readable-value",
}

# A2A request topic -> source of the payload carried in parts[0].data.
REQUEST_TOPICS = {
    "agent.tasks.risk": "assess-enrolment-request.json",
    "agent.tasks.enrolment": "decide-enrolment-request.json",
    "agent.tasks.step-up": "step-up-request.json",
    "agent.tasks.revocation": "revocation-request.json",
}
REPLY_TOPIC = "agent.task-events"
CARDS_TOPIC = "agent.cards"

# Artifact name on agent.task-events -> source of its parts[0].data payload.
ARTIFACTS = {
    "risk-assessment": "risk-assessment.json",
    "enrolment-decision": "enrolment-decision.json",
    "step-up-challenge": "step-up-challenge.json",
    "audit-record": "audit-record.json",
}
ENVELOPE_A2A_SOURCE = "envelope.json"

AGENT_CARD_REQUIRED = [
    "name", "version", "description", "supportedInterfaces", "capabilities", "skills",
]

UPSTREAM_REF = re.compile(
    r"^(?:lf\.a2a\.v1|google\.protobuf)\.(?P<name>[A-Za-z0-9]+)\.jsonschema\.json$"
)
LOCAL_REF = "#/$defs/"


def fail(message):
    raise SystemExit(f"generate-dtm-schemas: {message}")


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read {path}: {exc}")


def render(obj):
    return json.dumps(obj, indent=2, sort_keys=False) + "\n"


# --------------------------------------------------------------------------- #
# Avro
# --------------------------------------------------------------------------- #

def inline_envelope(schema, envelope):
    """Replace the first field typed ENVELOPE_AVRO_TYPE with the full record.

    Avro defines a named type once per schema, so later occurrences keep the
    by-name reference.
    """
    inlined = False

    def visit(node):
        nonlocal inlined
        if isinstance(node, dict):
            if (not inlined and "name" in node
                    and node.get("type") == ENVELOPE_AVRO_TYPE):
                node["type"] = copy.deepcopy(envelope)
                inlined = True
            for value in node.values():
                visit(value)
        elif isinstance(node, list):
            for value in node:
                visit(value)

    schema = copy.deepcopy(schema)
    visit(schema)
    return schema


def build_avro(src_dir=SRC_AVRO):
    sources = {p.name for p in Path(src_dir).glob("*.avsc")}
    expected = set(SUBJECTS) | {ENVELOPE_AVRO_SOURCE}
    if sources != expected:
        fail(
            f"Avro sources in {src_dir} do not match SUBJECTS: "
            f"missing {sorted(expected - sources)}, unmapped {sorted(sources - expected)}"
        )
    envelope = read_json(Path(src_dir) / ENVELOPE_AVRO_SOURCE)
    return {
        f"avro/{subject}.avsc": inline_envelope(read_json(Path(src_dir) / source), envelope)
        for source, subject in SUBJECTS.items()
    }


# --------------------------------------------------------------------------- #
# A2A JSON Schema
# --------------------------------------------------------------------------- #

def load_upstream(path=UPSTREAM):
    data = Path(path).read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != A2A_SHA256:
        fail(f"{path} SHA-256 {digest} does not match pinned A2A_SHA256 {A2A_SHA256}")
    return json.loads(data)


def clean_upstream(node):
    """Rewrite bundle $refs to #/$defs/<X>; drop patternProperties and $schema.

    patternProperties only carries the snake_case aliases of each field; the
    mesh emits protojson camelCase.
    """
    if isinstance(node, list):
        return [clean_upstream(value) for value in node]
    if not isinstance(node, dict):
        return node
    out = {}
    for key, value in node.items():
        if key in ("patternProperties", "$schema"):
            continue
        if key == "$ref":
            match = UPSTREAM_REF.match(value)
            if not match:
                fail(f"unrecognised upstream $ref {value!r}")
            out[key] = LOCAL_REF + match.group("name")
        else:
            out[key] = clean_upstream(value)
    return out


def upstream_defs(upstream):
    return {
        name.replace(" ", ""): clean_upstream(definition)
        for name, definition in upstream["definitions"].items()
    }


def mesh_defs(src_dir, taken):
    """Load the mesh sources; returns ($defs keyed by title, file -> ref)."""
    defs, refs = {}, {}
    for path in sorted(Path(src_dir).glob("*.json")):
        schema = read_json(path)
        name = schema.get("title")
        if not name or not re.fullmatch(r"[A-Za-z0-9]+", name):
            fail(f"{path} needs an alphanumeric title (used as its $defs key)")
        if name in taken or name in defs:
            fail(f"{path} title {name!r} collides with another $defs entry")
        defs[name] = schema
        refs[path.name] = {"$ref": LOCAL_REF + name}
    return defs, refs


def envelope_metadata(description):
    return {
        "description": description,
        "type": "object",
        "required": [ENVELOPE_URI],
        "properties": {ENVELOPE_URI: {"$ref": LOCAL_REF + "Envelope"}},
    }


def typed_parts(defs, data_schema, description):
    """parts = [data part, text part]; part order is part of the binding."""
    data_part = copy.deepcopy(defs["Part"])
    data_part["properties"]["data"] = data_schema
    data_part["required"] = ["data"]
    text_part = copy.deepcopy(defs["Part"])
    text_part["required"] = ["text"]
    return {
        "description": description,
        "type": "array",
        "prefixItems": [data_part, text_part],
        "minItems": 2,
    }


def narrowed_message(defs, payload_ref):
    message = copy.deepcopy(defs["Message"])
    props = message["properties"]
    props["metadata"] = envelope_metadata("Carries the mesh envelope.")
    props["parts"] = typed_parts(
        defs, payload_ref, "parts[0] is the typed data part, parts[1] the text summary."
    )
    message["required"] = [
        "messageId", "contextId", "role", "extensions", "metadata", "parts",
    ]
    return message


def jsonrpc_root(title, description, properties, required):
    return {
        "$schema": JSON_SCHEMA_DRAFT,
        "title": title,
        "description": description,
        "type": "object",
        "additionalProperties": False,
        "required": required,
        "properties": properties,
    }


def request_schema(defs, topic, payload_ref):
    params = copy.deepcopy(defs["SendMessageRequest"])
    params["properties"]["message"] = narrowed_message(defs, payload_ref)
    params["required"] = ["message"]
    return jsonrpc_root(
        topic,
        f"A2A v1.0.1 SendMessage JSON-RPC request on {topic} (mesh Kafka binding).",
        {
            "jsonrpc": {"const": "2.0"},
            "id": {"description": "Equals params.message.messageId.", "type": "string"},
            "method": {"const": "SendMessage"},
            "params": params,
        },
        ["jsonrpc", "id", "method", "params"],
    )


def artifact_union(refs):
    """allOf of if artifact.name == <name> then parts[0].data -> payload."""
    branches = []
    for name, source in ARTIFACTS.items():
        branches.append({
            "if": {
                "required": ["artifact"],
                "properties": {
                    "artifact": {
                        "required": ["name"],
                        "properties": {"name": {"const": name}},
                    }
                },
            },
            "then": {
                "properties": {
                    "artifact": {
                        "properties": {
                            "parts": {
                                "prefixItems": [
                                    {"properties": {"data": refs[source]}}
                                ]
                            }
                        }
                    }
                }
            },
        })
    return branches


def reply_schema(defs, refs):
    task = copy.deepcopy(defs["Task"])
    task["properties"]["metadata"] = envelope_metadata("Carries the mesh envelope.")
    task["required"] = ["id", "contextId", "status", "metadata"]

    status = copy.deepcopy(defs["TaskStatusUpdateEvent"])
    status["properties"]["metadata"] = envelope_metadata("Carries the mesh envelope.")
    status["required"] = ["taskId", "contextId", "status", "metadata"]

    artifact = copy.deepcopy(defs["Artifact"])
    artifact["properties"]["parts"] = typed_parts(
        defs,
        {"$ref": LOCAL_REF + "Value"},
        "parts[0] is the typed data part (narrowed by artifact name), parts[1] the text summary.",
    )
    artifact["required"] = ["artifactId", "name", "parts"]
    update = copy.deepcopy(defs["TaskArtifactUpdateEvent"])
    update["properties"]["artifact"] = artifact
    update["properties"]["metadata"] = envelope_metadata("Carries the mesh envelope.")
    update["required"] = ["taskId", "contextId", "artifact", "metadata"]
    update["allOf"] = artifact_union(refs)

    def only(key, schema):
        return {
            "type": "object",
            "additionalProperties": False,
            "required": [key],
            "properties": {key: schema},
        }

    return jsonrpc_root(
        REPLY_TOPIC,
        f"A2A v1.0.1 JSON-RPC reply on {REPLY_TOPIC}: exactly one Task, "
        "TaskStatusUpdateEvent or TaskArtifactUpdateEvent (mesh Kafka binding).",
        {
            "jsonrpc": {"const": "2.0"},
            "id": {"description": "JSON-RPC id of the request being answered.", "type": "string"},
            "result": {
                "oneOf": [
                    only("task", task),
                    only("statusUpdate", status),
                    only("artifactUpdate", update),
                ]
            },
        },
        ["jsonrpc", "id", "result"],
    )


def cards_schema(defs):
    card = copy.deepcopy(defs["AgentCard"])
    card.pop("title", None)
    card.pop("description", None)
    card["required"] = AGENT_CARD_REQUIRED
    return {
        "$schema": JSON_SCHEMA_DRAFT,
        "title": CARDS_TOPIC,
        "description": f"A2A v1.0.1 AgentCard on {CARDS_TOPIC}, keyed by agent name.",
        **card,
    }


def refs_in(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "$ref":
                yield value
            else:
                yield from refs_in(value)
    elif isinstance(node, list):
        for value in node:
            yield from refs_in(value)


def with_reachable_defs(root, defs):
    """Attach the $defs reachable from root, failing on any dangling $ref."""
    reachable = {}
    pending = list(refs_in(root))
    while pending:
        ref = pending.pop()
        if not ref.startswith(LOCAL_REF):
            fail(f"non-local $ref {ref!r} in {root.get('title')}")
        name = ref[len(LOCAL_REF):]
        if name in reachable:
            continue
        if name not in defs:
            fail(f"$ref {ref!r} in {root.get('title')} names no definition")
        reachable[name] = defs[name]
        pending.extend(refs_in(defs[name]))
    root = dict(root)
    root["$defs"] = {name: reachable[name] for name in sorted(reachable)}
    return root


def build_a2a(upstream, src_dir=SRC_A2A):
    defs = upstream_defs(upstream)
    mesh, refs = mesh_defs(src_dir, defs)
    expected = set(REQUEST_TOPICS.values()) | set(ARTIFACTS.values()) | {ENVELOPE_A2A_SOURCE}
    if set(refs) != expected:
        fail(
            f"A2A sources in {src_dir} do not match the topic tables: "
            f"missing {sorted(expected - set(refs))}, unmapped {sorted(set(refs) - expected)}"
        )
    if refs[ENVELOPE_A2A_SOURCE] != {"$ref": LOCAL_REF + "Envelope"}:
        fail(f"{ENVELOPE_A2A_SOURCE} must be titled Envelope")
    defs.update(mesh)
    roots = {
        topic: request_schema(defs, topic, refs[source])
        for topic, source in REQUEST_TOPICS.items()
    }
    roots[REPLY_TOPIC] = reply_schema(defs, refs)
    roots[CARDS_TOPIC] = cards_schema(defs)
    return {
        f"a2a/{topic}.json": with_reachable_defs(root, defs)
        for topic, root in roots.items()
    }


# --------------------------------------------------------------------------- #
# Output
# --------------------------------------------------------------------------- #

def build_outputs(upstream_path=UPSTREAM, src_avro=SRC_AVRO, src_a2a=SRC_A2A):
    """Return {relative output path: schema object}."""
    outputs = build_avro(src_avro)
    outputs.update(build_a2a(load_upstream(upstream_path), src_a2a))
    return outputs


def write_outputs(out_dir, outputs):
    out_dir = Path(out_dir)
    for rel, obj in outputs.items():
        path = out_dir / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(render(obj))
    for stale in sorted(existing_outputs(out_dir) - set(outputs)):
        (out_dir / stale).unlink()


def existing_outputs(out_dir):
    out_dir = Path(out_dir)
    return {
        str(path.relative_to(out_dir))
        for sub in ("avro", "a2a")
        for path in (out_dir / sub).glob("*")
        if path.is_file()
    }


def drifted(out_dir, outputs):
    """Paths whose committed content differs from, or is absent in, outputs."""
    out_dir = Path(out_dir)
    paths = []
    for rel in sorted(set(outputs) | existing_outputs(out_dir)):
        path = out_dir / rel
        if rel not in outputs or not path.is_file() or path.read_text() != render(outputs[rel]):
            paths.append(path)
    return paths


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true",
                        help="exit 1 if the generated files differ from the sources")
    parser.add_argument("--out-dir", type=Path, default=OUT_DIR,
                        help=f"output directory (default: {OUT_DIR.relative_to(REPO)})")
    args = parser.parse_args(argv)
    outputs = build_outputs()
    if args.check:
        stale = drifted(args.out_dir, outputs)
        for path in stale:
            print(f"drift: {path}")
        if stale:
            print("run: python3 -I scripts/generate-dtm-schemas.py")
            return 1
        print(f"OK: {len(outputs)} schemas up to date")
        return 0
    write_outputs(args.out_dir, outputs)
    print(f"wrote {len(outputs)} schemas to {args.out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
