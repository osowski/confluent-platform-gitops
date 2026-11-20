"""Tests for the AI-functions CMF setup script (stdlib unittest only).

The script uploads the AI-functions JAR to a CMF environment and writes the
model-server URLs into the environment's statement defaults. These tests run it
against a fake CMF, a fake token endpoint and a fake JAR host (all
`http.server` on 127.0.0.1) and assert on the requests that went over the wire.

Run from the repository root:
    python3 -I -m unittest discover -s scripts/tests -v
"""

import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "workloads/flink-resources/base/ai-functions/ai_functions_setup.py"

sys.dont_write_bytecode = True  # keep a __pycache__ out of the manifest directory
spec = importlib.util.spec_from_file_location("ai_functions_setup", SCRIPT)
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)

ENV_NAME = "default"
ARTIFACT = "ai-functions.jar"
JAR_BYTES = b"PK\x03\x04fake-jar-bytes\x00\xff"
JAR_SHA = hashlib.sha256(JAR_BYTES).hexdigest()
ENDPOINT = "http://model-server-ttm.flink.svc.cluster.local:8080/v1/forecast"
ENVS_PATH = "/cmf/api/v1/environments"
ENV_PATH = f"{ENVS_PATH}/{ENV_NAME}"
ARTIFACTS_PATH = f"{ENV_PATH}/artifacts"
ARTIFACT_PATH = f"{ARTIFACTS_PATH}/{ARTIFACT}"
OAUTH_TXT = "clientId=cmf\nclientSecret=cmf-secret\n"


class Truncated(bytes):
    """A response body the server cuts short of its declared Content-Length."""


class FakeServer:
    """Records every request and answers from scripted responses.

    `routes` maps (method, path) to a list of (status, body) tuples; the last
    one repeats. A dict or list body is sent as JSON, bytes as-is, and a
    Truncated body is sent short of its Content-Length. Unrouted requests get a 404.
    """

    def __init__(self, routes=None):
        self.routes = {key: list(value) for key, value in (routes or {}).items()}
        self.requests = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _handle(self):
                length = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(length) if length else b""
                outer.requests.append((self.command, self.path, dict(self.headers), body))
                queue = outer.routes.get((self.command, self.path))
                status, payload = (queue.pop(0) if len(queue) > 1 else queue[0]) if queue else (404, {})
                if not isinstance(payload, bytes):
                    payload = json.dumps(payload).encode()
                self.send_response(status)
                declared = len(payload) + (100 if isinstance(payload, Truncated) else 0)
                self.send_header("Content-Length", str(declared))
                self.end_headers()
                self.wfile.write(payload)
                self.close_connection = True

            do_GET = do_POST = do_PUT = _handle

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        self.thread = threading.Thread(target=self.httpd.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        self.thread.start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join()

    def calls(self, method=None, path=None):
        return [r for r in self.requests if (method is None or r[0] == method) and (path is None or r[1] == path)]


def environment_payload():
    """A GET /environments/<env> response with every defaults block populated."""
    return {
        "name": ENV_NAME,
        "kubernetesNamespace": "flink",
        "kubernetesClusterName": "default-k8s-cluster",
        "computePoolDefaults": {"clusterSpec": {"image": "confluentinc/cp-flink-sql:1.19-cp10"}},
        "flinkApplicationDefaults": {"spec": {"flinkConfiguration": {"taskmanager.numberOfTaskSlots": "2"}}},
        "statementDefaults": {
            "detached": {
                "flinkConfiguration": {"state.backend.type": "hashmap"},
                "savepointSchedule": {"cronExpression": "0 */10 * * * *"},
            },
            "interactive": {"flinkConfiguration": {"table.exec.resource.default-parallelism": "1"}},
        },
        "secrets": {"conn": "secret-a"},
        "metadata": {
            "name": ENV_NAME,
            "labels": {"team": "demo"},
            "annotations": {"owner": "gitops"},
            "creationTimestamp": "2026-11-20T10:00:00Z",
            "updateTimestamp": "2026-11-20T10:05:00Z",
        },
        "status": {"kubernetesCluster": {"state": "CONNECTED"}, "resources": {}},
        "created_time": "2026-11-20T10:00:00Z",
        "updated_time": "2026-11-20T10:05:00Z",
    }


def with_endpoint(environment):
    return setup.merge_model_endpoints(environment, {"ttm": ENDPOINT})


class ParseOauthTests(unittest.TestCase):
    def test_parse_oauth_txt_reads_both_values(self):
        self.assertEqual(setup.parse_oauth_txt(OAUTH_TXT), ("cmf", "cmf-secret"))

    def test_parse_oauth_txt_missing_secret_raises(self):
        with self.assertRaises(ValueError):
            setup.parse_oauth_txt("clientId=cmf\n")


class NetworkTestCase(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.dict(os.environ, {"no_proxy": "*", "NO_PROXY": "*"})
        patcher.start()
        self.addCleanup(patcher.stop)

    def serve(self, routes=None):
        server = FakeServer(routes)
        self.addCleanup(server.close)
        return server


class FetchTokenTests(NetworkTestCase):
    def test_fetch_token_posts_client_credentials(self):
        server = self.serve({("POST", "/token"): [(200, {"access_token": "tok-1"})]})
        token = setup.fetch_token(server.url + "/token", "cmf", "cmf-secret")
        self.assertEqual(token, "tok-1")
        (_, _, headers, body), = server.calls("POST", "/token")
        self.assertEqual(body, b"grant_type=client_credentials&client_id=cmf&client_secret=cmf-secret")
        self.assertEqual(headers["Content-Type"], "application/x-www-form-urlencoded")


class DownloadJarTests(NetworkTestCase):
    def test_download_jar_returns_bytes_on_match(self):
        server = self.serve({("GET", "/a.jar"): [(200, JAR_BYTES)]})
        self.assertEqual(setup.download_jar(server.url + "/a.jar", JAR_SHA), JAR_BYTES)

    def test_download_jar_rejects_checksum_mismatch(self):
        server = self.serve({("GET", "/a.jar"): [(200, b"tampered")]})
        with self.assertRaises(setup.ChecksumMismatch):
            setup.download_jar(server.url + "/a.jar", JAR_SHA)


class WaitForEnvironmentTests(NetworkTestCase):
    def test_wait_for_environment_retries_until_200(self):
        server = self.serve({("GET", ENV_PATH): [(404, {}), (404, {}), (200, environment_payload())]})
        sleeps = []
        setup.wait_for_environment(
            setup.CmfClient(server.url), ENV_NAME, timeout_s=60, interval_s=1, sleep=sleeps.append
        )
        self.assertEqual(len(sleeps), 2)
        self.assertEqual(len(server.calls("GET", ENV_PATH)), 3)

    def test_wait_for_environment_times_out(self):
        server = self.serve({("GET", ENV_PATH): [(404, {})]})
        with self.assertRaises(TimeoutError):
            setup.wait_for_environment(
                setup.CmfClient(server.url), ENV_NAME, timeout_s=3, interval_s=1, sleep=lambda s: None
            )


class MergeModelEndpointsTests(unittest.TestCase):
    def test_merge_preserves_flink_application_defaults_and_other_keys(self):
        original = environment_payload()
        before = copy.deepcopy(original)
        merged = setup.merge_model_endpoints(original, {"ttm": ENDPOINT})
        self.assertEqual(original, before, "input must not be mutated")
        for key in ("flinkApplicationDefaults", "computePoolDefaults", "secrets", "metadata", "name"):
            self.assertEqual(merged[key], before[key], key)
        detached = merged["statementDefaults"]["detached"]
        interactive = merged["statementDefaults"]["interactive"]
        self.assertEqual(detached["savepointSchedule"], before["statementDefaults"]["detached"]["savepointSchedule"])
        self.assertEqual(
            detached["flinkConfiguration"],
            {"state.backend.type": "hashmap", "ai.models.ttm.endpoint": ENDPOINT},
        )
        self.assertEqual(
            interactive["flinkConfiguration"],
            {"table.exec.resource.default-parallelism": "1", "ai.models.ttm.endpoint": ENDPOINT},
        )

    def test_merge_creates_missing_blocks(self):
        for defaults in ({"detached": None, "interactive": None}, None, {}):
            environment = {"name": ENV_NAME, "statementDefaults": defaults}
            if defaults is None:
                del environment["statementDefaults"]
            merged = setup.merge_model_endpoints(environment, {"ttm": ENDPOINT})
            for kind in ("interactive", "detached"):
                self.assertEqual(
                    merged["statementDefaults"][kind]["flinkConfiguration"],
                    {"ai.models.ttm.endpoint": ENDPOINT},
                )

    def test_merge_replaces_a_stale_endpoint(self):
        stale = setup.merge_model_endpoints(environment_payload(), {"ttm": "http://old:8080/v1/forecast"})
        merged = setup.merge_model_endpoints(stale, {"ttm": ENDPOINT})
        for kind in ("interactive", "detached"):
            self.assertEqual(merged["statementDefaults"][kind]["flinkConfiguration"]["ai.models.ttm.endpoint"], ENDPOINT)

    def test_merge_is_idempotent(self):
        once = setup.merge_model_endpoints(environment_payload(), {"ttm": ENDPOINT})
        self.assertEqual(setup.merge_model_endpoints(once, {"ttm": ENDPOINT}), once)


class MainTests(NetworkTestCase):
    def setUp(self):
        super().setUp()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.jar_host = self.serve({("GET", "/ai-functions.jar"): [(200, JAR_BYTES)]})
        self.environment = environment_payload()

    def cmf(self, overrides=None):
        routes = {
            ("GET", ENV_PATH): [(200, self.environment)],
            ("GET", ARTIFACT_PATH): [(404, {})],
            ("POST", ARTIFACTS_PATH): [(201, {})],
            ("POST", ENVS_PATH): [(200, self.environment)],
        }
        routes.update(overrides or {})
        self.cmf_server = self.serve(routes)
        return self.cmf_server

    def environ(self, cmf, **overrides):
        base = {
            "CMF_URL": cmf.url,
            "ENVIRONMENT": ENV_NAME,
            "ARTIFACT_NAME": ARTIFACT,
            "JAR_URL": self.jar_host.url + "/ai-functions.jar",
            "JAR_SHA256": JAR_SHA,
        }
        base.update(overrides)
        return base

    def run_main(self, environ, **kwargs):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = setup.main(environ, sleep=lambda s: None, **kwargs)
        self.stderr = err.getvalue()
        return code

    def assert_single_stderr_line_without(self, *secrets):
        self.assertEqual(len(self.stderr.strip().splitlines()), 1, self.stderr)
        for secret in secrets:
            self.assertNotIn(secret, self.stderr)

    def token_setup(self, status=200, body=None):
        body = {"access_token": "tok-secret-1"} if body is None else body
        token_server = self.serve({("POST", "/token"): [(status, body)]})
        oauth = Path(self.tmp.name) / "oauth.txt"
        oauth.write_text(OAUTH_TXT)
        return {"TOKEN_URL": token_server.url + "/token", "OAUTH_FILE": str(oauth)}

    # artifact behavior

    def test_main_uploads_when_artifact_missing(self):
        cmf = self.cmf()
        self.assertEqual(self.run_main(self.environ(cmf)), 0)
        (_, _, headers, body), = cmf.calls("POST", ARTIFACTS_PATH)
        self.assertIn(b'"name":"ai-functions.jar"', body)
        self.assertIn(b'"kind":"Artifact"', body)
        self.assertIn(JAR_BYTES, body)
        self.assertTrue(headers["Content-Type"].startswith("multipart/form-data; boundary="))

    def test_main_skips_download_and_upload_when_artifact_exists(self):
        cmf = self.cmf({("GET", ARTIFACT_PATH): [(200, {})]})
        self.assertEqual(self.run_main(self.environ(cmf)), 0)
        self.assertEqual(cmf.calls("POST"), [])
        self.assertEqual(self.jar_host.requests, [])

    def test_main_treats_409_as_success(self):
        cmf = self.cmf({("POST", ARTIFACTS_PATH): [(409, {})]})
        self.assertEqual(self.run_main(self.environ(cmf)), 0)

    def test_main_returns_nonzero_on_500(self):
        cmf = self.cmf({("POST", ARTIFACTS_PATH): [(500, {"error": "boom"})]})
        self.assertNotEqual(self.run_main(self.environ(cmf)), 0)
        self.assert_single_stderr_line_without()

    def test_main_does_not_upload_on_checksum_mismatch(self):
        cmf = self.cmf()
        self.assertNotEqual(self.run_main(self.environ(cmf, JAR_SHA256="0" * 64)), 0)
        self.assertEqual(cmf.calls("POST"), [])
        self.assert_single_stderr_line_without()

    def test_main_reports_truncated_jar_download_in_one_line(self):
        self.jar_host.routes[("GET", "/ai-functions.jar")] = [(200, Truncated(JAR_BYTES[:5]))]
        cmf = self.cmf()
        self.assertNotEqual(self.run_main(self.environ(cmf)), 0)
        self.assertEqual(cmf.calls("POST"), [])
        self.assert_single_stderr_line_without("Traceback")

    # auth

    def test_main_sends_bearer_only_when_token_url_set(self):
        cmf = self.cmf()
        self.assertEqual(self.run_main(self.environ(cmf, **self.token_setup())), 0)
        self.assertGreater(len(cmf.requests), 0)
        for method, path, headers, _ in cmf.requests:
            self.assertEqual(headers.get("Authorization"), "Bearer tok-secret-1", (method, path))
        for _, _, headers, _ in self.jar_host.requests:
            self.assertNotIn("Authorization", headers)

        anonymous = self.cmf()
        self.assertEqual(self.run_main(self.environ(anonymous)), 0)
        for method, path, headers, _ in anonymous.requests:
            self.assertNotIn("Authorization", headers, (method, path))

    def test_main_fails_without_anonymous_fallback_when_token_fetch_fails(self):
        cmf = self.cmf()
        self.assertNotEqual(self.run_main(self.environ(cmf, **self.token_setup(status=500))), 0)
        self.assertEqual(cmf.requests, [])
        self.assert_single_stderr_line_without("cmf-secret", "tok-secret-1")

    def test_main_reports_non_object_token_response_in_one_line(self):
        for body in (["leaked-array-body"], "leaked-string-body", 7):
            cmf = self.cmf()
            self.assertNotEqual(self.run_main(self.environ(cmf, **self.token_setup(body=body))), 0, body)
            self.assertEqual(cmf.requests, [], body)
            self.assert_single_stderr_line_without("cmf-secret", "leaked-array-body", "leaked-string-body", "Traceback")

    def test_main_reports_incomplete_oauth_file_without_echoing_it(self):
        cmf = self.cmf()
        oauth = Path(self.tmp.name) / "oauth.txt"
        oauth.write_text("clientId=cmf\n")
        environ = self.environ(cmf, TOKEN_URL=self.jar_host.url + "/token", OAUTH_FILE=str(oauth))
        self.assertNotEqual(self.run_main(environ), 0)
        self.assertEqual(cmf.requests, [])
        self.assert_single_stderr_line_without("clientId=cmf")

    # ordering and model endpoints

    def test_main_waits_for_environment_before_any_write(self):
        cmf = self.cmf({("GET", ENV_PATH): [(404, {}), (200, self.environment)]})
        self.assertEqual(self.run_main(self.environ(cmf, MODEL_ENDPOINTS=json.dumps({"ttm": ENDPOINT}))), 0)
        methods_and_paths = [(m, p) for m, p, _, _ in cmf.requests]
        self.assertEqual(methods_and_paths[:2], [("GET", ENV_PATH)] * 2)
        first_write = next(i for i, (m, _) in enumerate(methods_and_paths) if m == "POST")
        self.assertGreaterEqual(first_write, 2)

    def test_main_leaves_environment_alone_when_model_endpoints_unset(self):
        for value in (None, ""):
            cmf = self.cmf()
            environ = self.environ(cmf)
            if value is not None:
                environ["MODEL_ENDPOINTS"] = value
            self.assertEqual(self.run_main(environ), 0)
            self.assertEqual(cmf.calls("POST", ENVS_PATH), [])
            self.assertEqual(len(cmf.calls("GET", ENV_PATH)), 1, "only the existence check")

    def test_main_posts_merged_environment_once(self):
        cmf = self.cmf()
        self.assertEqual(self.run_main(self.environ(cmf, MODEL_ENDPOINTS=json.dumps({"ttm": ENDPOINT}))), 0)
        (_, _, headers, body), = cmf.calls("POST", ENVS_PATH)
        self.assertEqual(headers["Content-Type"], "application/json")
        sent = json.loads(body)
        for kind in ("interactive", "detached"):
            self.assertEqual(sent["statementDefaults"][kind]["flinkConfiguration"]["ai.models.ttm.endpoint"], ENDPOINT)
        self.assertEqual(sent["flinkApplicationDefaults"], self.environment["flinkApplicationDefaults"])
        self.assertEqual(sent["computePoolDefaults"], self.environment["computePoolDefaults"])
        self.assertEqual(sent["statementDefaults"]["detached"]["savepointSchedule"], {"cronExpression": "0 */10 * * * *"})
        self.assertEqual(
            sent["statementDefaults"]["detached"]["flinkConfiguration"]["state.backend.type"], "hashmap"
        )
        self.assertEqual(sent["metadata"]["labels"], {"team": "demo"})
        self.assertEqual(sent["metadata"]["annotations"], {"owner": "gitops"})
        self.assertEqual(sent["kubernetesNamespace"], "flink")

    def test_main_posts_when_statement_defaults_are_null_blocks(self):
        self.environment["statementDefaults"] = {"detached": None, "interactive": None}
        cmf = self.cmf()
        self.assertEqual(self.run_main(self.environ(cmf, MODEL_ENDPOINTS=json.dumps({"ttm": ENDPOINT}))), 0)
        (_, _, _, body), = cmf.calls("POST", ENVS_PATH)
        sent = json.loads(body)
        for kind in ("interactive", "detached"):
            self.assertEqual(sent["statementDefaults"][kind], {"flinkConfiguration": {"ai.models.ttm.endpoint": ENDPOINT}})

    def test_main_skips_post_when_values_already_set(self):
        self.environment = with_endpoint(environment_payload())
        cmf = self.cmf()
        self.assertEqual(self.run_main(self.environ(cmf, MODEL_ENDPOINTS=json.dumps({"ttm": ENDPOINT}))), 0)
        self.assertEqual(cmf.calls("POST", ENVS_PATH), [])

    def test_main_merges_even_when_artifact_exists(self):
        cmf = self.cmf({("GET", ARTIFACT_PATH): [(200, {})]})
        self.assertEqual(self.run_main(self.environ(cmf, MODEL_ENDPOINTS=json.dumps({"ttm": ENDPOINT}))), 0)
        self.assertEqual(len(cmf.calls("POST", ENVS_PATH)), 1)
        self.assertEqual(cmf.calls("POST", ARTIFACTS_PATH), [])

    def test_main_returns_nonzero_when_environment_update_fails(self):
        cmf = self.cmf({("POST", ENVS_PATH): [(500, {})]})
        self.assertNotEqual(self.run_main(self.environ(cmf, MODEL_ENDPOINTS=json.dumps({"ttm": ENDPOINT}))), 0)
        self.assertEqual(cmf.calls("POST", ARTIFACTS_PATH), [], "no artifact work after a failed merge")
        self.assert_single_stderr_line_without()

    def test_update_body_never_contains_server_populated_fields(self):
        cmf = self.cmf()
        self.assertEqual(self.run_main(self.environ(cmf, MODEL_ENDPOINTS=json.dumps({"ttm": ENDPOINT}))), 0)
        (_, _, _, body), = cmf.calls("POST", ENVS_PATH)
        sent = json.loads(body)
        for field in ("status", "secrets", "created_time", "updated_time", "kubernetesClusterName"):
            self.assertNotIn(field, sent, field)
        for field in ("creationTimestamp", "updateTimestamp"):
            self.assertNotIn(field, sent["metadata"], field)
        self.assertEqual(sent["metadata"]["name"], ENV_NAME)
        self.assertNotIn("name", sent, "the name is sent once, in metadata")

    def test_malformed_model_endpoints_fail_without_any_cmf_write(self):
        for bad in ("{not json", "[]", '{"ttm": 3}', '{"ttm": ""}'):
            cmf = self.cmf()
            self.assertNotEqual(self.run_main(self.environ(cmf, MODEL_ENDPOINTS=bad)), 0, bad)
            self.assertEqual(cmf.calls("POST"), [], bad)
            self.assert_single_stderr_line_without()

    def test_missing_required_variable_fails_with_one_line(self):
        cmf = self.cmf()
        environ = self.environ(cmf)
        del environ["JAR_SHA256"]
        self.assertNotEqual(self.run_main(environ), 0)
        self.assertEqual(cmf.requests, [])
        self.assert_single_stderr_line_without()


class EnvironmentUpdateBodyTests(unittest.TestCase):
    def test_update_environment_refuses_a_body_for_another_environment(self):
        client = setup.CmfClient("http://127.0.0.1:1")
        with self.assertRaises(ValueError):
            client.update_environment("other", setup.environment_update_body(environment_payload()))


class ScriptCopyTests(unittest.TestCase):
    def test_ai_functions_script_copies_are_identical(self):
        # Each Application carries its own copy so it can sync alone.
        copy_path = REPO / "workloads/colors-and-shapes/base/ai-functions/ai_functions_setup.py"
        self.assertTrue(copy_path.is_file(), f"{copy_path} is missing")
        self.assertEqual(SCRIPT.read_bytes(), copy_path.read_bytes())


if __name__ == "__main__":
    unittest.main()
