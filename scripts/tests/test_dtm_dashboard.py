"""Checks for the Device Trust Mesh Grafana dashboard ConfigMap (stdlib unittest only).

The dashboard JSON is embedded in a ConfigMap, so nothing parses it before
Grafana loads it. This test parses it and checks which metric names each
panel queries: the context service is scraped directly (unprefixed dtm_*),
while the agents run on Ray and keep the ray_ prefix.

Run from the repository root:
    python3 -I -m unittest discover -s scripts/tests -v
"""

import json
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DASHBOARD = REPO / "workloads/device-trust-mesh/components/observability/grafana-dashboard.yaml"
KEY = "device-trust-mesh-dashboard.json: |-\n"

# Emitted by the context service process.
CONTEXT_METRICS = [
    "dtm_context_tool_latency_ms_bucket",
    "dtm_context_stale_total",
    "dtm_materialization_lag_ms_bucket",
    "dtm_materializer_skipped_total",
    "dtm_tracked_devices",
]
RAY_PREFIXED_CONTEXT = [
    "ray_dtm_context_",
    "ray_dtm_materialization_lag_ms",
    "ray_dtm_materializer_skipped_total",
    "ray_dtm_tracked_devices",
]
# Emitted by the agents, which run on Ray.
AGENT_METRICS = [
    "ray_dtm_agent_processing_latency_ms_bucket",
    "ray_dtm_llm_latency_ms_bucket",
]


def load_dashboard(text):
    """Return the dashboard dict from the ConfigMap text."""
    head, sep, body = text.partition(KEY)
    if not sep:
        raise ValueError(f"{KEY.strip()!r} not found")
    lines = body.split("\n")
    indent = len(lines[0]) - len(lines[0].lstrip())
    return json.loads("\n".join(line[indent:] for line in lines))


def walk(panels):
    """Yield every panel, including the panels inside collapsed rows."""
    for panel in panels:
        yield panel
        yield from walk(panel.get("panels", []))


def exprs(panels):
    """Yield every query expression in panels."""
    for panel in walk(panels):
        for target in panel.get("targets", []):
            if "expr" in target:
                yield target["expr"]


class DtmDashboardTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dashboard = load_dashboard(DASHBOARD.read_text())
        cls.exprs = list(exprs(cls.dashboard["panels"]))

    def test_dashboard_json_parses(self):
        self.assertEqual(self.dashboard["uid"], "device-trust-mesh")
        self.assertTrue(self.exprs)

    def test_context_panels_use_unprefixed_metrics(self):
        for expr in self.exprs:
            for prefixed in RAY_PREFIXED_CONTEXT:
                with self.subTest(expr=expr, prefixed=prefixed):
                    self.assertNotIn(prefixed, expr)
        for metric in CONTEXT_METRICS:
            with self.subTest(metric=metric):
                self.assertTrue(any(metric in expr for expr in self.exprs), f"{metric} not queried")

    def test_agent_panels_keep_ray_metrics(self):
        for metric in AGENT_METRICS:
            with self.subTest(metric=metric):
                self.assertTrue(any(metric in expr for expr in self.exprs), f"{metric} not queried")

    def test_load_dashboard_requires_key(self):
        with self.assertRaisesRegex(ValueError, "not found"):
            load_dashboard("data:\n  other.json: |-\n    {}\n")


if __name__ == "__main__":
    unittest.main()
