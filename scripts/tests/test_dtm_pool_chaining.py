"""Render check: the device-trust-mesh compute pool chains operators (stdlib unittest only).

The statements write through transactional Kafka sinks. With operator chaining
off, each sink's committer runs in its own task, the committed producer never
returns to the writer's pool, and the writer opens a new producer (and network
thread) on every checkpoint without closing the old one, until the
TaskManager runs out of memory. This test renders every overlay and fails
unless the pool turns chaining on.

Run from the repository root:
    python3 -I -m unittest discover -s scripts/tests -v
"""

import re
import shutil
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
WORKLOAD = REPO / "workloads" / "device-trust-mesh"
KEY = "pipeline.operator-chaining.enabled"


def overlays():
    return sorted(
        p for p in (WORKLOAD / "overlays").iterdir() if (p / "kustomization.yaml").is_file()
    )


def render(path):
    return subprocess.run(
        ["kustomize", "build", str(path)], check=True, capture_output=True, text=True
    ).stdout


def compute_pools(manifests):
    """Return the FlinkComputePool documents in a multi-document YAML string."""
    return [doc for doc in re.split(r"^---\s*$", manifests, flags=re.M) if re.search(r"^kind: FlinkComputePool\s*$", doc, re.M)]


def chaining_values(doc):
    """Return every value set for KEY in a document."""
    return re.findall(rf"^\s*{re.escape(KEY)}:\s*\"?(\w+)\"?\s*$", doc, re.M)


@unittest.skipUnless(shutil.which("kustomize"), "kustomize is not installed")
class DtmPoolChainingTest(unittest.TestCase):
    def test_overlays_chain_operators(self):
        found = overlays()
        self.assertTrue(found, "no device-trust-mesh overlays")
        for overlay in found:
            with self.subTest(overlay=str(overlay.relative_to(REPO))):
                pools = compute_pools(render(overlay))
                self.assertTrue(pools, "no FlinkComputePool rendered")
                for pool in pools:
                    self.assertEqual(chaining_values(pool), ["true"])


class HelperTest(unittest.TestCase):
    def test_chaining_values_reads_quoted_and_bare(self):
        doc = f'kind: FlinkComputePool\n  {KEY}: "false"\n  other: x\n'
        self.assertEqual(chaining_values(doc), ["false"])
        self.assertEqual(chaining_values(f"  {KEY}: true\n"), ["true"])
        self.assertEqual(chaining_values("  other: true\n"), [])

    def test_compute_pools_splits_documents(self):
        text = "kind: ConfigMap\n---\nkind: FlinkComputePool\nmetadata: {}\n---\nkind: Secret\n"
        self.assertEqual(len(compute_pools(text)), 1)


if __name__ == "__main__":
    unittest.main()
