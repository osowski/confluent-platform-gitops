"""Render checks for the `default` environment's AI function setup (stdlib unittest only).

The upload Job, the compute pool and the two CREATE FUNCTION statements form a
chain that only works in one order, and the OAuth wiring differs per overlay.
These tests render every flink-resources overlay with `kustomize build` and
check the sync waves, the Job's environment and the statements' SQL.

Run from the repository root:
    python3 -I -m unittest discover -s scripts/tests -v
"""

import json
import re
import shutil
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
FLINK_RESOURCES = REPO / "workloads" / "flink-resources"

JOB = "ai-functions-setup-default"
STATEMENTS = ("create-ai-forecast", "create-ai-detect-anomalies")
OAUTH_OVERLAYS = ("eks-demo", "flink-demo-rbac", "flink-demo-rbac-mtls")
ANONYMOUS_OVERLAYS = ("flink-demo",)
ALL_OVERLAYS = OAUTH_OVERLAYS + ANONYMOUS_OVERLAYS
JAR_REFERENCE = "USING JAR 'cmf://default/ai-functions.jar'"

# Waves the flink-resources Application already uses (the RBAC component uses
# 10/20/30). The Job and statements must not share a wave with any of them.
EXISTING_WAVES = {"5", "10", "20", "30", "35", "40", "45", "50"}


def overlays():
    return sorted(p for p in (FLINK_RESOURCES / "overlays").iterdir() if (p / "kustomization.yaml").is_file())


def render_docs(path):
    """Run `kustomize build` and return one dict per rendered document."""
    output = subprocess.run(
        ["kustomize", "build", str(path)], check=True, capture_output=True, text=True
    ).stdout
    return [parse_doc(text) for text in output.split("\n---\n") if text.strip()]


def parse_doc(text):
    """Extract the identity and sync annotations of one document by line parsing."""
    doc = {"text": text}
    for key, pattern in (("kind", r"^kind: (\S+)"), ("name", r"^  name: (\S+)"), ("namespace", r"^  namespace: (\S+)")):
        match = re.search(pattern, text, re.MULTILINE)
        doc[key] = match.group(1) if match else None
    wave = re.search(r"argocd\.argoproj\.io/sync-wave: [\"']?(-?\d+)", text)
    hook = re.search(r"argocd\.argoproj\.io/hook: [\"']?(\w+)", text)
    doc["wave"] = wave.group(1) if wave else None
    doc["hook"] = hook.group(1) if hook else None
    return doc


def find(docs, kind, name):
    for doc in docs:
        if doc["kind"] == kind and doc["name"] == name:
            return doc
    raise AssertionError(f"{kind} {name} not rendered")


def job_env(doc):
    """Return the Job container's env as {name: value} for plain `value:` entries."""
    env = {}
    for match in re.finditer(r"- name: (\w+)\n\s+value: (.+)", doc["text"]):
        value = match.group(2).strip()
        if value[:1] in "\"'" and value[-1:] == value[:1]:
            value = value[1:-1]
        env[match.group(1)] = value
    return env


@unittest.skipUnless(shutil.which("kustomize"), "kustomize is not installed")
class DefaultEnvironmentAiFunctionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rendered = {path.name: render_docs(path) for path in overlays()}

    def overlay_docs(self):
        """Return (name, docs) for every overlay, failing if one of the four is missing."""
        self.assertTrue(self.rendered, "no flink-resources overlays found")
        self.assertEqual(sorted(ALL_OVERLAYS), sorted(set(ALL_OVERLAYS) & set(self.rendered)), "overlay missing")
        return list(self.rendered.items())

    def test_default_env_ai_wave_order(self):
        for name, docs in self.overlay_docs():
            with self.subTest(overlay=name):
                environment = find(docs, "FlinkEnvironment", "default")
                job = find(docs, "Job", JOB)
                pool = find(docs, "FlinkComputePool", "pool")
                statements = [find(docs, "FlinkStatement", s) for s in STATEMENTS]
                for doc in (environment, job, pool, *statements):
                    self.assertIsNotNone(doc["wave"], f"{doc['name']} has no sync-wave")
                # The Job runs after the pool, so a stuck Job cannot block the
                # base SQL demo (topics, schemas, catalog, database, pool).
                self.assertLess(int(environment["wave"]), int(pool["wave"]))
                self.assertLess(int(pool["wave"]), int(job["wave"]))
                for statement in statements:
                    self.assertLess(int(job["wave"]), int(statement["wave"]))
                for added in (job, *statements):
                    self.assertNotIn(added["wave"], EXISTING_WAVES, f"{added['name']} shares a wave")

    def test_job_is_a_sync_hook_in_the_flink_namespace(self):
        for name, docs in self.overlay_docs():
            with self.subTest(overlay=name):
                job = find(docs, "Job", JOB)
                self.assertEqual(job["namespace"], "flink")
                self.assertEqual(job["hook"], "Sync")
                self.assertIn("argocd.argoproj.io/hook-delete-policy: BeforeHookCreation", job["text"])

    def test_script_configmap_is_not_a_hook_and_has_a_stable_name(self):
        for name, docs in self.overlay_docs():
            with self.subTest(overlay=name):
                config_map = find(docs, "ConfigMap", "ai-functions-setup-script")
                self.assertEqual(config_map["namespace"], "flink")
                self.assertIsNone(config_map["hook"])
                self.assertIn("ai_functions_setup.py", config_map["text"])

    def test_job_mounts_the_generated_script_configmap(self):
        for name, docs in self.overlay_docs():
            with self.subTest(overlay=name):
                job = find(docs, "Job", JOB)
                self.assertRegex(job["text"], r"configMap:\n\s+name: ai-functions-setup-script")
                self.assertRegex(job["text"], r"- mountPath: /scripts\n\s+name: script\n\s+readOnly: true")
                find(docs, "ConfigMap", "ai-functions-setup-script")

    def test_default_env_has_two_create_function_statements(self):
        for name, docs in self.overlay_docs():
            with self.subTest(overlay=name):
                expected = {
                    "create-ai-forecast": ("AI_FORECAST", "io.confluent.cpflink.udf.ai.AIForecastFunction"),
                    "create-ai-detect-anomalies": (
                        "AI_DETECT_ANOMALIES",
                        "io.confluent.cpflink.udf.ai.AIDetectAnomaliesFunction",
                    ),
                }
                for statement_name, (function, klass) in expected.items():
                    statement = find(docs, "FlinkStatement", statement_name)
                    self.assertEqual(statement["namespace"], "flink")
                    self.assertIn(f"CREATE FUNCTION IF NOT EXISTS {function} AS '{klass}'", statement["text"])
                    self.assertIn(JAR_REFERENCE, statement["text"])
                    self.assertIn("flinkEnvironment: default", statement["text"])
                    self.assertIn("computePoolName: pool", statement["text"])
                    self.assertIn("sql.current-catalog: _env_default", statement["text"])
                    self.assertIn("sql.current-database: default", statement["text"])

    def test_job_model_endpoints_name_the_ttm_server(self):
        for name, docs in self.overlay_docs():
            with self.subTest(overlay=name):
                env = job_env(find(docs, "Job", JOB))
                endpoints = json.loads(env["MODEL_ENDPOINTS"])
                self.assertEqual(endpoints["ttm"], "http://model-server-ttm.flink.svc.cluster.local:8080/v1/forecast")
                self.assertEqual(env["ENVIRONMENT"], "default")

    def test_oauth_wiring_only_on_oauth_overlays(self):
        self.overlay_docs()
        for name in OAUTH_OVERLAYS:
            with self.subTest(overlay=name):
                job = find(self.rendered[name], "Job", JOB)
                env = job_env(job)
                self.assertEqual(
                    env["TOKEN_URL"],
                    "http://keycloak.keycloak.svc.cluster.local:8080/realms/confluent/protocol/openid-connect/token",
                )
                self.assertEqual(env["OAUTH_FILE"], "/oauth/oauth.txt")
                self.assertIn("secretName: cfk-cmf-oauth-client", job["text"])
                self.assertRegex(
                    job["text"], r"- mountPath: /oauth\n\s+name: oauth\n\s+readOnly: true"
                )
                self.assertRegex(job["text"], r"- name: oauth\n\s+secret:\n\s+secretName: cfk-cmf-oauth-client")
        for name in ANONYMOUS_OVERLAYS:
            with self.subTest(overlay=name):
                job = find(self.rendered[name], "Job", JOB)
                self.assertNotIn("TOKEN_URL", job["text"])
                self.assertNotIn("OAUTH_FILE", job["text"])
                self.assertNotIn("cfk-cmf-oauth-client", job["text"])

    def test_default_environment_carries_no_statement_defaults(self):
        # CFK does not send statementDefaults to CMF when it creates an
        # environment, so the Job writes the model URLs. A CR block would be
        # ignored and would hide that.
        for name, docs in self.overlay_docs():
            with self.subTest(overlay=name):
                self.assertNotIn("statementDefaults", find(docs, "FlinkEnvironment", "default")["text"])


if __name__ == "__main__":
    unittest.main()
