"""Render checks for the AI function resources in flink-resources and colors-and-shapes (stdlib unittest only).

Two things have to hold across every overlay. The model server owns a PVC that
stays Pending until its pod exists, and Argo CD waits for a Deployment to be
Ready before it starts the next wave, so its resources sit in one wave after
every other resource: a slow model download would otherwise stall the
environments, the compute pool and the topics. And the upload Job, the compute
pool and the two CREATE FUNCTION statements form a chain that only works in one
order, with OAuth wiring that differs per overlay.

colors-and-shapes repeats the chain for `colors-env` and `shapes-env`.

These tests render every flink-resources and colors-and-shapes overlay with
`kustomize build` and check the sync waves, the Jobs' environment and OAuth
wiring and the statements' SQL.

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
COLORS_AND_SHAPES = REPO / "workloads" / "colors-and-shapes"

JOB = "ai-functions-setup-default"
STATEMENTS = ("create-ai-forecast", "create-ai-detect-anomalies")
OAUTH_OVERLAYS = ("eks-demo", "flink-demo-rbac", "flink-demo-rbac-mtls")
ANONYMOUS_OVERLAYS = ("flink-demo",)
ALL_OVERLAYS = OAUTH_OVERLAYS + ANONYMOUS_OVERLAYS
JAR_REFERENCE = "USING JAR 'cmf://default/ai-functions.jar'"

# Waves the flink-resources Application already uses (the RBAC component uses
# 10/20/30). The Job and statements must not share a wave with any of them.
EXISTING_WAVES = {"5", "10", "20", "30", "35", "40", "45", "50"}

MODEL_SERVER_PREFIX = "model-server-ttm"
MODEL_SERVER_WAVE = 90
MODEL_SERVER_KINDS = {"PersistentVolumeClaim", "Deployment", "Service", "NetworkPolicy"}


def overlays(workload=FLINK_RESOURCES):
    return sorted(p for p in (workload / "overlays").iterdir() if (p / "kustomization.yaml").is_file())


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


def find(docs, kind, name, namespace=None):
    for doc in docs:
        if doc["kind"] == kind and doc["name"] == name and namespace in (None, doc["namespace"]):
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
class FlinkResourcesAiFunctionTest(unittest.TestCase):
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

    def test_model_server_waves_follow_every_other_flink_resource(self):
        for name, docs in self.overlay_docs():
            with self.subTest(overlay=name):
                server = [d for d in docs if d["name"].startswith(MODEL_SERVER_PREFIX)]
                self.assertEqual({d["kind"] for d in server}, MODEL_SERVER_KINDS)
                for doc in server:
                    self.assertEqual(doc["wave"], str(MODEL_SERVER_WAVE), f"{doc['kind']}/{doc['name']}")
                for doc in docs:
                    if doc not in server:
                        # Argo CD's default wave, with no annotation, is 0.
                        self.assertLess(int(doc["wave"] or 0), MODEL_SERVER_WAVE, f"{doc['kind']}/{doc['name']}")

    def test_model_server_pvc_and_deployment_share_a_wave(self):
        for name, docs in self.overlay_docs():
            with self.subTest(overlay=name):
                by_kind = {d["kind"]: d for d in docs if d["name"].startswith(MODEL_SERVER_PREFIX)}
                self.assertIn("PersistentVolumeClaim", by_kind)
                self.assertIn("Deployment", by_kind)
                self.assertEqual(by_kind["PersistentVolumeClaim"]["wave"], by_kind["Deployment"]["wave"])


# One entry per colors-and-shapes tenant: the environment, its pool, the
# namespace its statements live in, the setup Job and the statement that
# already runs on the pool.
TENANTS = {
    "colors": {
        "environment": "colors-env",
        "pool": "colors-pool",
        "namespace": "flink-colors",
        "job": "ai-functions-setup-colors",
        "existing_statement": "colors-sql-enrich",
    },
    "shapes": {
        "environment": "shapes-env",
        "pool": "shapes-pool",
        "namespace": "flink-shapes",
        "job": "ai-functions-setup-shapes",
        "existing_statement": "shapes-sql-enrich",
    },
}
TENANT_SCRIPT_CONFIGMAP = "ai-functions-setup-script-cs"
JOB_WAVE = "62"
STATEMENT_WAVE = "65"
FUNCTIONS = {
    "create-ai-forecast": ("AI_FORECAST", "io.confluent.cpflink.udf.ai.AIForecastFunction"),
    "create-ai-detect-anomalies": ("AI_DETECT_ANOMALIES", "io.confluent.cpflink.udf.ai.AIDetectAnomaliesFunction"),
}


@unittest.skipUnless(shutil.which("kustomize"), "kustomize is not installed")
class ColorsAndShapesAiFunctionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rendered = {path.name: render_docs(path) for path in overlays(COLORS_AND_SHAPES)}
        cls.flink_resources = {path.name: render_docs(path) for path in overlays(FLINK_RESOURCES)}

    def overlay_docs(self):
        self.assertEqual(sorted(ALL_OVERLAYS), sorted(self.rendered), "colors-and-shapes overlays changed")
        return list(self.rendered.items())

    def each_tenant(self):
        for overlay, docs in self.overlay_docs():
            for tenant, spec in TENANTS.items():
                with self.subTest(overlay=overlay, tenant=tenant):
                    yield overlay, docs, spec

    def test_ai_wave_order_per_environment(self):
        for _, docs, spec in self.each_tenant():
            environment = find(docs, "FlinkEnvironment", spec["environment"])
            pool = find(docs, "FlinkComputePool", spec["pool"])
            job = find(docs, "Job", spec["job"])
            statements = [find(docs, "FlinkStatement", s, spec["namespace"]) for s in FUNCTIONS]
            jobs = [find(docs, "Job", t["job"]) for t in TENANTS.values()]
            all_statements = [
                find(docs, "FlinkStatement", s, t["namespace"]) for t in TENANTS.values() for s in FUNCTIONS
            ]
            existing = find(docs, "FlinkStatement", spec["existing_statement"])
            self.assertEqual(job["wave"], JOB_WAVE)
            for statement in statements:
                self.assertEqual(statement["wave"], STATEMENT_WAVE)
            # The Job follows the pools, so a stuck Job leaves everything before
            # them applied. The create statements need the artifact the Job
            # uploads, and the existing statements come after them.
            self.assertLess(int(environment["wave"]), int(pool["wave"]))
            self.assertLess(int(pool["wave"]), int(job["wave"]))
            self.assertLess(int(job["wave"]), int(STATEMENT_WAVE))
            self.assertLess(int(STATEMENT_WAVE), int(existing["wave"]))
            # The new waves are not shared with any other rendered resource.
            added = {id(doc) for doc in (*jobs, *all_statements)}
            other_waves = {doc["wave"] for doc in docs if id(doc) not in added and doc["wave"] is not None}
            for doc in (*jobs, *all_statements):
                self.assertNotIn(doc["wave"], other_waves, f"{doc['name']} shares a wave")

    def test_job_is_a_sync_hook_that_mounts_its_own_script_configmap(self):
        for _, docs, spec in self.each_tenant():
            job = find(docs, "Job", spec["job"])
            self.assertEqual(job["namespace"], "flink")
            self.assertEqual(job["hook"], "Sync")
            self.assertIn("argocd.argoproj.io/hook-delete-policy: BeforeHookCreation", job["text"])
            # flink-resources generates ai-functions-setup-script in the same
            # namespace; two Applications must not own one object.
            self.assertRegex(job["text"], rf"configMap:\n\s+name: {TENANT_SCRIPT_CONFIGMAP}\n")
            config_map = find(docs, "ConfigMap", TENANT_SCRIPT_CONFIGMAP)
            self.assertEqual(config_map["namespace"], "flink")
            self.assertIsNone(config_map["hook"])
            self.assertIn("ai_functions_setup.py", config_map["text"])

    def test_no_object_is_owned_by_both_flink_resources_and_colors_and_shapes(self):
        # Both Applications deploy into the `flink` namespace; two Applications
        # must not own one object.
        for overlay, docs in self.overlay_docs():
            with self.subTest(overlay=overlay):
                self.assertIn(overlay, self.flink_resources)
                ours = {(d["kind"], d["namespace"], d["name"]) for d in docs}
                theirs = {(d["kind"], d["namespace"], d["name"]) for d in self.flink_resources[overlay]}
                self.assertEqual(ours & theirs, set())

    def test_job_targets_its_own_environment_and_the_ttm_server(self):
        for _, docs, spec in self.each_tenant():
            env = job_env(find(docs, "Job", spec["job"]))
            self.assertEqual(env["ENVIRONMENT"], spec["environment"])
            self.assertEqual(
                json.loads(env["MODEL_ENDPOINTS"])["ttm"],
                "http://model-server-ttm.flink.svc.cluster.local:8080/v1/forecast",
            )

    def test_environments_carry_no_statement_defaults(self):
        # CFK does not send statementDefaults to CMF; the Job writes them.
        for _, docs, spec in self.each_tenant():
            self.assertNotIn("statementDefaults", find(docs, "FlinkEnvironment", spec["environment"])["text"])

    def test_create_function_statements_target_the_tenant_environment(self):
        for _, docs, spec in self.each_tenant():
            for name, (function, klass) in FUNCTIONS.items():
                text = find(docs, "FlinkStatement", name, spec["namespace"])["text"]
                self.assertIn(f"CREATE FUNCTION IF NOT EXISTS {function} AS '{klass}'", text)
                self.assertIn(f"USING JAR 'cmf://{spec['environment']}/ai-functions.jar'", text)
                self.assertIn(f"flinkEnvironment: {spec['environment']}", text)
                self.assertIn(f"computePoolName: {spec['pool']}", text)
                self.assertIn(f"sql.current-catalog: _env_{spec['environment']}", text)
                self.assertIn("sql.current-database: default", text)

    def test_oauth_wiring_only_on_oauth_overlays(self):
        self.overlay_docs()
        for overlay in sorted(ALL_OVERLAYS):
            for spec in TENANTS.values():
                with self.subTest(overlay=overlay, job=spec["job"]):
                    job = find(self.rendered[overlay], "Job", spec["job"])
                    if overlay in OAUTH_OVERLAYS:
                        env = job_env(job)
                        self.assertEqual(
                            env["TOKEN_URL"],
                            "http://keycloak.keycloak.svc.cluster.local:8080/realms/confluent/protocol/openid-connect/token",
                        )
                        self.assertEqual(env["OAUTH_FILE"], "/oauth/oauth.txt")
                        self.assertRegex(job["text"], r"- mountPath: /oauth\n\s+name: oauth\n\s+readOnly: true")
                        self.assertRegex(
                            job["text"], r"- name: oauth\n\s+secret:\n\s+secretName: cfk-cmf-oauth-client"
                        )
                    else:
                        for token in ("TOKEN_URL", "OAUTH_FILE", "cfk-cmf-oauth-client"):
                            self.assertNotIn(token, job["text"])


if __name__ == "__main__":
    unittest.main()
