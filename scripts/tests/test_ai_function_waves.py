"""Sync-wave checks for the AI function resources in flink-resources (stdlib unittest only).

The model server owns a PVC that stays Pending until its pod exists, and Argo
CD waits for a Deployment to be Ready before it starts the next wave. If the
server shared a wave with the environments, the compute pool or the topics, a
slow model download would stall them. These tests render every overlay and
check that all model-server resources sit in one wave after every other
resource.

`render_docs` and `wave` are shared by the other AI function checks.

Run from the repository root:
    python3 -I -m unittest discover -s scripts/tests -v
"""

import re
import shutil
import subprocess
import unittest
from collections import namedtuple
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
FLINK_RESOURCES = REPO / "workloads" / "flink-resources"

WAVE_ANNOTATION = "argocd.argoproj.io/sync-wave"
MODEL_SERVER_PREFIX = "model-server-ttm"
MODEL_SERVER_WAVE = 90
MODEL_SERVER_KINDS = {"PersistentVolumeClaim", "Deployment", "Service", "NetworkPolicy"}

Doc = namedtuple("Doc", "kind name namespace annotations")


def overlays(workload):
    return sorted(
        p for p in (workload / "overlays").iterdir() if (p / "kustomization.yaml").is_file()
    )


def parse_doc(text):
    """Read kind, name, namespace and annotations from one rendered manifest.

    `kustomize build` emits top-level `kind:` and `metadata:` keys with 2-space
    indentation, so line matching is enough: no YAML library is needed.
    """
    kind = re.search(r"^kind: (\S+)", text, re.M).group(1)
    metadata = re.search(r"^metadata:\n((?:[ ].*\n?)+)", text, re.M).group(1)
    name = re.search(r"^  name: (\S+)", metadata, re.M).group(1)
    namespace = re.search(r"^  namespace: (\S+)", metadata, re.M)
    annotations = {}
    block = re.search(r"^  annotations:\n((?:    \S.*\n?)+)", metadata, re.M)
    for line in (block.group(1).splitlines() if block else []):
        key, _, value = line.strip().partition(": ")
        annotations[key] = value.strip("\"'")
    return Doc(kind, name, namespace.group(1) if namespace else None, annotations)


def render_docs(path):
    """Render a Kustomize directory and return one Doc per manifest."""
    out = subprocess.run(
        ["kustomize", "build", str(path)], check=True, capture_output=True, text=True
    ).stdout
    return [parse_doc(chunk) for chunk in out.split("\n---\n") if chunk.strip()]


def wave(doc):
    """Return the Argo CD sync wave of a Doc; Argo CD's default is 0."""
    return int(doc.annotations.get(WAVE_ANNOTATION, "0"))


@unittest.skipUnless(shutil.which("kustomize"), "kustomize is not installed")
class ModelServerWaveTest(unittest.TestCase):
    def test_model_server_waves_follow_every_other_flink_resource(self):
        for overlay in overlays(FLINK_RESOURCES):
            with self.subTest(overlay=overlay.name):
                docs = render_docs(overlay)
                server = [d for d in docs if d.name.startswith(MODEL_SERVER_PREFIX)]
                self.assertEqual({d.kind for d in server}, MODEL_SERVER_KINDS)
                for doc in server:
                    self.assertEqual(wave(doc), MODEL_SERVER_WAVE, f"{doc.kind}/{doc.name}")
                for doc in docs:
                    if doc not in server:
                        self.assertLess(wave(doc), MODEL_SERVER_WAVE, f"{doc.kind}/{doc.name}")

    def test_model_server_pvc_and_deployment_share_a_wave(self):
        for overlay in overlays(FLINK_RESOURCES):
            with self.subTest(overlay=overlay.name):
                by_kind = {d.kind: d for d in render_docs(overlay) if d.name.startswith(MODEL_SERVER_PREFIX)}
                self.assertIn("PersistentVolumeClaim", by_kind)
                self.assertIn("Deployment", by_kind)
                self.assertEqual(wave(by_kind["PersistentVolumeClaim"]), wave(by_kind["Deployment"]))


if __name__ == "__main__":
    unittest.main()
