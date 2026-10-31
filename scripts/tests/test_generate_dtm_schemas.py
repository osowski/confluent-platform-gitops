"""Unit tests for scripts/generate-dtm-schemas.py (stdlib unittest only).

Run from the repository root:
    python3 -I -m unittest discover -s scripts/tests -v
"""

import contextlib
import importlib.util
import io
import shutil
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "generate-dtm-schemas.py"


def load_generator():
    spec = importlib.util.spec_from_file_location("generate_dtm_schemas", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gen = load_generator()


def walk(node):
    """Yield every dict nested anywhere in node, node included."""
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)


def resolve(schema, node):
    """Follow local `#/$defs/<name>` references until node is not a $ref."""
    while isinstance(node, dict) and "$ref" in node:
        node = schema["$defs"][node["$ref"][len("#/$defs/"):]]
    return node


class GeneratorTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.outputs = gen.build_outputs()
        cls.a2a = {
            path: obj for path, obj in cls.outputs.items() if path.startswith("a2a/")
        }
        cls.avro = {
            path: obj for path, obj in cls.outputs.items() if path.startswith("avro/")
        }

    def test_upstream_hash_verified(self):
        with tempfile.TemporaryDirectory() as tmp:
            tampered = Path(tmp) / "a2a.json"
            shutil.copyfile(gen.UPSTREAM, tampered)
            # Swap one indentation space for a tab: still valid JSON, so only
            # the hash check can reject it.
            data = bytearray(tampered.read_bytes())
            data[data.index(b"\n  ") + 1] = ord("\t")
            tampered.write_bytes(bytes(data))
            with self.assertRaises(SystemExit):
                gen.load_upstream(tampered)

    def test_refs_resolve(self):
        self.assertEqual(len(self.a2a), 6)
        for path, schema in self.a2a.items():
            for node in walk(schema):
                ref = node.get("$ref")
                if ref is None:
                    continue
                with self.subTest(path=path, ref=ref):
                    self.assertTrue(ref.startswith("#/$defs/"))
                    self.assertIn(ref[len("#/$defs/"):], schema["$defs"])

    def test_no_pattern_properties(self):
        for path, schema in self.a2a.items():
            with self.subTest(path=path):
                self.assertFalse(
                    any("patternProperties" in node for node in walk(schema))
                )

    def test_risk_request_narrowed(self):
        schema = self.a2a["a2a/agent.tasks.risk.json"]
        node = schema
        for key in ("params", "message", "parts"):
            node = resolve(schema, resolve(schema, node)["properties"][key])
        data = resolve(schema, node["prefixItems"][0]["properties"]["data"])
        self.assertEqual(
            data["required"],
            ["deviceId", "customerId", "requiredContextSeq", "fingerprintSummary"],
        )

    def test_task_events_artifact_union(self):
        schema = self.a2a["a2a/agent.task-events.json"]
        names = set()
        for node in walk(schema):
            if "if" in node and "then" in node:
                names.update(
                    inner["const"] for inner in walk(node["if"]) if "const" in inner
                )
        self.assertTrue(
            {"risk-assessment", "enrolment-decision", "step-up-challenge",
             "audit-record"} <= names
        )

    def test_envelope_inlined_identically(self):
        envelope = gen.read_json(gen.SRC_AVRO / "envelope.avsc")
        values = {p: s for p, s in self.avro.items() if p.endswith("-value.avsc")}
        self.assertEqual(len(values), 12)
        for path, schema in values.items():
            with self.subTest(path=path):
                field = schema["fields"][0]
                self.assertEqual(field["name"], "envelope")
                self.assertEqual(field["type"], envelope)

    def test_key_fields_not_in_values(self):
        cases = {
            "avro/device.context-value.avsc": "device_id",
            "avro/customer.context-value.avsc": "customer_id",
            "avro/agent.cards_human_readable-value.avsc": "agent",
        }
        for path, key_field in cases.items():
            with self.subTest(path=path):
                names = [f["name"] for f in self.avro[path]["fields"]]
                self.assertNotIn(key_field, names)

    def test_check_detects_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            gen.write_outputs(out, self.outputs)
            edited = out / "avro" / "device.events-value.avsc"
            edited.write_text(edited.read_text() + " ")
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                code = gen.main(["--check", "--out-dir", str(out)])
            self.assertEqual(code, 1)
            self.assertIn("device.events-value.avsc", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
