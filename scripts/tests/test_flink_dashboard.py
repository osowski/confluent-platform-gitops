"""Checks for the Flink Grafana dashboard ConfigMap (stdlib unittest only).

The dashboard JSON is embedded in a ConfigMap, so nothing parses it before
Grafana loads it. This test parses it, checks that every per-job query is
narrowed by the dashboard variables, and checks the job health rows.

Run from the repository root:
    python3 -I -m unittest discover -s scripts/tests -v
"""

import json
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DASHBOARD = REPO / "workloads/observability-resources/base/grafana-dashboard.yaml"
KEY = "flink-dashboard.json: |-\n"

# Every query on a per-job metric carries all four filters.
PER_JOB_METRIC = re.compile(r"\bflink_(jobmanager|taskmanager)_job_\w+")
JOB_FILTERS = ['job="flink"', 'namespace="$namespace"', 'app="$env"', 'job_name=~"$job"']

# Collapsed job health rows and the metrics each one queries.
HEALTH_ROWS = {
    "Checkpoints": [
        "flink_jobmanager_job_lastCheckpointDuration",
        "flink_jobmanager_job_lastCheckpointSize",
        "flink_jobmanager_job_numberOfCompletedCheckpoints",
        "flink_jobmanager_job_numberOfFailedCheckpoints",
    ],
    "Restarts and uptime": [
        "flink_jobmanager_job_numRestarts",
        "flink_jobmanager_job_uptime",
    ],
    "Lag": [
        "flink_taskmanager_job_task_operator_pendingRecords",
        "flink_taskmanager_job_task_operator_KafkaSourceReader_KafkaConsumer_records_lag_max",
        "flink_taskmanager_job_task_operator_currentEmitEventTimeLag",
        "flink_taskmanager_job_task_operator_watermarkLag",
    ],
}


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
    """Yield (panel title, expr) for every query in panels."""
    for panel in walk(panels):
        for target in panel.get("targets", []):
            if "expr" in target:
                yield panel["title"], target["expr"]


class FlinkDashboardTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dashboard = load_dashboard(DASHBOARD.read_text())

    def test_panel_ids_are_unique(self):
        ids = [panel["id"] for panel in walk(self.dashboard["panels"])]
        self.assertEqual(len(ids), len(set(ids)), "duplicate panel ids")

    def test_per_job_queries_filter_on_dashboard_variables(self):
        for title, expr in exprs(self.dashboard["panels"]):
            if not PER_JOB_METRIC.search(expr):
                continue
            with self.subTest(panel=title, expr=expr):
                for selector in re.findall(r"flink_\w+\{[^}]*\}|flink_\w+", expr):
                    if not PER_JOB_METRIC.match(selector):
                        continue
                    missing = [f for f in JOB_FILTERS if f not in selector]
                    self.assertFalse(missing, f"{selector} lacks {missing}")

    def test_health_rows_are_collapsed_and_query_their_metrics(self):
        rows = {p["title"]: p for p in self.dashboard["panels"] if p["type"] == "row"}
        for title, metrics in HEALTH_ROWS.items():
            with self.subTest(row=title):
                self.assertIn(title, sorted(rows))
                row = rows[title]
                self.assertTrue(row["collapsed"], "row must be collapsed")
                queried = " ".join(expr for _, expr in exprs(row["panels"]))
                for metric in metrics:
                    self.assertRegex(queried, rf"\b{metric}\b")

    def test_collapsed_row_panels_sit_below_their_row(self):
        for row in self.dashboard["panels"]:
            if row["type"] != "row" or not row["collapsed"]:
                continue
            for panel in row["panels"]:
                with self.subTest(row=row["title"], panel=panel["title"]):
                    self.assertGreater(panel["gridPos"]["y"], row["gridPos"]["y"])

    def test_load_dashboard_requires_key(self):
        with self.assertRaisesRegex(ValueError, "not found"):
            load_dashboard("data:\n  other.json: |-\n    {}\n")

    def test_bare_metric_without_filters_is_caught(self):
        selector = re.findall(r"flink_\w+\{[^}]*\}|flink_\w+", "rate(flink_jobmanager_job_uptime[5m])")
        self.assertEqual(selector, ["flink_jobmanager_job_uptime"])
        self.assertTrue(PER_JOB_METRIC.match(selector[0]))


if __name__ == "__main__":
    unittest.main()
