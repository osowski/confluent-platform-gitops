"""Check that whole-copy overlays still match their base values (stdlib unittest only).

Kustomize can't patch inside a string, so an overlay that changes one field of
an embedded YAML string replaces the whole string. A base change that isn't
copied into the overlay still builds, and the cluster silently runs the old
value. This test compares each copy with its base, with the fields the overlay
owns masked out, and fails on any other difference.

Run from the repository root:
    python3 -I -m unittest discover -s scripts/tests -v
"""

import difflib
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DTM = REPO / "workloads" / "device-trust-mesh"
MASK = "<owned by overlay>"

# Each copy: the base block scalar, the overlay block scalar, and the fields
# the overlay owns. A block scalar is located by its key line, optionally the
# first one after an anchor line.
COPIES = [
    {
        "name": "eks-demo agents.yaml",
        "base": (DTM / "base/config.yaml", "agents.yaml: |", None),
        "overlay": (DTM / "overlays/eks-demo/agents-config-patch.yaml", "agents.yaml: |", None),
        "owned": [r"\breplicas: \d+"],
    },
    {
        "name": "eks-demo serveConfigV2",
        "base": (DTM / "components/mesh-runtime/rayservice.yaml", "serveConfigV2: |", None),
        "overlay": (
            DTM / "overlays/eks-demo/rayservice-scale-patch.yaml",
            "value: |",
            "path: /spec/serveConfigV2",
        ),
        "owned": [r"\bnum_replicas: \d+"],
    },
]


def block_scalar(text, key, after=None):
    """Return the dedented body of the `key: |` block scalar in text.

    With after, the block is the first `key` line following the `after` line.
    """
    lines = text.splitlines()
    start = 0
    if after is not None:
        anchor = next((i for i, line in enumerate(lines) if line.strip() == after), None)
        if anchor is None:
            raise ValueError(f"anchor line {after!r} not found")
        start = anchor + 1
    head = next((i for i in range(start, len(lines)) if lines[i].strip() == key), None)
    if head is None:
        raise ValueError(f"block scalar {key!r} not found")
    indent = len(lines[head]) - len(lines[head].lstrip())
    body = []
    for line in lines[head + 1 :]:
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            break
        body.append(line)
    while body and not body[-1].strip():
        body.pop()
    margin = min(len(line) - len(line.lstrip()) for line in body if line.strip())
    return [line[margin:] for line in body]


def masked(lines, owned):
    """Replace every match of an owned-field pattern with MASK."""
    out = []
    for line in lines:
        for pattern in owned:
            line = re.sub(pattern, MASK, line)
        out.append(line.rstrip())
    return out


def read_block(spec):
    path, key, after = spec
    return block_scalar(path.read_text(), key, after)


class OverlayCopyTest(unittest.TestCase):
    def test_copies_match_base_outside_owned_fields(self):
        for copy in COPIES:
            with self.subTest(copy=copy["name"]):
                base = read_block(copy["base"])
                overlay = read_block(copy["overlay"])
                for pattern in copy["owned"]:
                    self.assertTrue(
                        any(re.search(pattern, line) for line in overlay),
                        f"owned field {pattern!r} no longer appears in the overlay",
                    )
                diff = list(
                    difflib.unified_diff(
                        masked(base, copy["owned"]),
                        masked(overlay, copy["owned"]),
                        fromfile=str(copy["base"][0].relative_to(REPO)),
                        tofile=str(copy["overlay"][0].relative_to(REPO)),
                        lineterm="",
                    )
                )
                if diff:
                    self.fail("overlay copy differs from base:\n" + "\n".join(diff))

    def test_mask_ignores_owned_fields_only(self):
        owned = [r"\bnum_replicas: \d+"]
        base = ["- name: risk", "  import_path: dtm.mesh.risk:app", "  num_replicas: 1"]
        scaled = ["- name: risk", "  import_path: dtm.mesh.risk:app", "  num_replicas: 2"]
        moved = ["- name: risk", "  import_path: dtm.mesh.risk_v2:app", "  num_replicas: 2"]
        self.assertEqual(masked(base, owned), masked(scaled, owned))
        self.assertNotEqual(masked(base, owned), masked(moved, owned))

    def test_block_scalar_stops_at_parent_indent(self):
        text = "data:\n  a: |\n    x: 1\n\n    y: 2\n  b: other\n"
        self.assertEqual(block_scalar(text, "a: |"), ["x: 1", "", "y: 2"])

    def test_block_scalar_after_anchor(self):
        text = "- path: /one\n  value: |\n    first\n- path: /two\n  value: |\n    second\n"
        self.assertEqual(block_scalar(text, "value: |", "- path: /two"), ["second"])

    def test_block_scalar_missing_key_raises(self):
        with self.assertRaisesRegex(ValueError, "not found"):
            block_scalar("data:\n  a: |\n    x: 1\n", "b: |")
        with self.assertRaisesRegex(ValueError, "not found"):
            block_scalar("data:\n  a: |\n    x: 1\n", "a: |", "path: /nowhere")


if __name__ == "__main__":
    unittest.main()
