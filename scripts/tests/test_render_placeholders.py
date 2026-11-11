"""Render check for Kustomize replacement placeholders (stdlib unittest only).

A value written as `set-by-replacements` is filled in by a Kustomize
replacement at build time. A copy with no matching replacement target renders
the literal placeholder, and `kustomize build` doesn't reject it. This test
renders every overlay of each workload that uses the placeholder and fails if
the placeholder survives.

Run from the repository root:
    python3 -I -m unittest discover -s scripts/tests -v
"""

import shutil
import subprocess
import unittest
from pathlib import Path

PLACEHOLDER = "set-by-replacements"
REPO = Path(__file__).resolve().parents[2]


def workloads_using_placeholder():
    """Return the workload directories with a manifest that contains PLACEHOLDER."""
    found = set()
    for path in (REPO / "workloads").rglob("*.yaml"):
        if PLACEHOLDER in path.read_text():
            found.add(path.relative_to(REPO / "workloads").parts[0])
    return sorted(REPO / "workloads" / name for name in found)


def overlays(workload):
    return sorted(
        p for p in (workload / "overlays").iterdir() if (p / "kustomization.yaml").is_file()
    )


def render(path):
    return subprocess.run(
        ["kustomize", "build", str(path)], check=True, capture_output=True, text=True
    ).stdout


@unittest.skipUnless(shutil.which("kustomize"), "kustomize is not installed")
class PlaceholderRenderTest(unittest.TestCase):
    def test_overlays_render_without_placeholder(self):
        workloads = workloads_using_placeholder()
        self.assertTrue(workloads, f"no workload uses {PLACEHOLDER}")
        for workload in workloads:
            for overlay in overlays(workload):
                with self.subTest(overlay=str(overlay.relative_to(REPO))):
                    left = [line.strip() for line in render(overlay).splitlines() if PLACEHOLDER in line]
                    self.assertEqual(left, [], "placeholder with no replacement target")


if __name__ == "__main__":
    unittest.main()
