"""Set up AI functions in one Confluent Manager for Apache Flink (CMF) environment.

Runs as a hook Job and is safe to run repeatedly. Python standard library only.

Steps, in order:
  1. Fetch an OAuth token (only when TOKEN_URL is set).
  2. Wait for the environment to exist in CMF.
  3. Write the model-server URLs into the environment's statement defaults
     (only when MODEL_ENDPOINTS is set).
  4. Check whether the artifact exists; if not, download the JAR, verify its
     sha256, and upload it.

Environment variables:
  CMF_URL, ENVIRONMENT, ARTIFACT_NAME, JAR_URL, JAR_SHA256   required
  TOKEN_URL, OAUTH_FILE      client-credentials token fetch; OAUTH_FILE holds
                             `clientId=` and `clientSecret=` lines
  MODEL_ENDPOINTS            JSON object mapping a model name to its URL,
                             e.g. {"ttm": "http://model-server:8080/v1/forecast"}
  WAIT_SECONDS               how long to wait for the environment (default 300)

Every failure writes one line to stderr and exits non-zero. Tokens, client
secrets and the OAuth file contents are never printed.
"""

import copy
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

REQUEST_TIMEOUT_S = 60
DOWNLOAD_TIMEOUT_S = 300
DEFAULT_WAIT_S = 300
STATEMENT_KINDS = ("interactive", "detached")


class ChecksumMismatch(Exception):
    """The downloaded JAR does not match the pinned sha256."""


class CmfError(Exception):
    """CMF (or the token endpoint) answered with an unexpected status."""


def parse_oauth_txt(text):
    """Return (client id, client secret) from `clientId=`/`clientSecret=` lines."""
    values = {}
    for line in text.splitlines():
        key, separator, value = line.partition("=")
        if separator:
            values[key.strip()] = value.strip()
    for key in ("clientId", "clientSecret"):
        if not values.get(key):
            raise ValueError(f"OAuth file has no {key} line")
    return values["clientId"], values["clientSecret"]


def _http(method, url, headers=None, data=None, timeout=REQUEST_TIMEOUT_S):
    """Send one request and return (status, body); HTTP error statuses are returned, not raised."""
    request = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        with error:
            return error.code, error.read()


def fetch_token(token_url, client_id, client_secret):
    """Return an access token from a client-credentials grant."""
    form = urllib.parse.urlencode(
        [("grant_type", "client_credentials"), ("client_id", client_id), ("client_secret", client_secret)]
    )
    status, body = _http(
        "POST",
        token_url,
        {"Content-Type": "application/x-www-form-urlencoded"},
        form.encode(),
    )
    if status != 200:
        raise CmfError(f"token request returned HTTP {status}")
    token = json.loads(body).get("access_token")
    if not token:
        raise CmfError("token response has no access_token")
    return token


def download_jar(url, sha256_hex):
    """Download url and return its bytes, or raise ChecksumMismatch if the sha256 differs."""
    status, body = _http("GET", url, timeout=DOWNLOAD_TIMEOUT_S)
    if status != 200:
        raise CmfError(f"JAR download returned HTTP {status}")
    actual = hashlib.sha256(body).hexdigest()
    if actual != sha256_hex.strip().lower():
        raise ChecksumMismatch(f"JAR sha256 is {actual}, expected {sha256_hex}")
    return body


def merge_model_endpoints(environment, endpoints):
    """Return a copy of a CMF environment with `ai.models.<name>.endpoint` set.

    The key is set in both statementDefaults.interactive.flinkConfiguration and
    statementDefaults.detached.flinkConfiguration. Null or missing blocks are
    created; every other key is left as it was.
    """
    merged = copy.deepcopy(environment)
    defaults = merged.get("statementDefaults") or {}
    for kind in STATEMENT_KINDS:
        block = defaults.get(kind) or {}
        configuration = block.get("flinkConfiguration") or {}
        for name, url in endpoints.items():
            configuration[f"ai.models.{name}.endpoint"] = url
        block["flinkConfiguration"] = configuration
        defaults[kind] = block
    merged["statementDefaults"] = defaults
    return merged


def environment_update_body(environment):
    """Build the createOrUpdateEnvironment request body from a GET response.

    An update replaces the environment's flinkApplicationDefaults,
    computePoolDefaults, both statementDefaults blocks and its metadata labels
    and annotations with what is sent, so each of those is carried over. These
    GET fields are left out because the server owns them:
      status, secrets, created_time, updated_time   (computed, or managed by
                                                     secret mappings)
      metadata.creationTimestamp, metadata.updateTimestamp   (read-only)
      kubernetesClusterName   (immutable; omitting it skips the cluster-use
                               authorization check)
      the top-level name      (sending it next to metadata.name is rejected)
    Keys whose value is null are omitted; CMF stores the same null either way.
    """
    metadata = environment.get("metadata") or {}
    name = metadata.get("name") or environment.get("name")
    if not name:
        raise ValueError("environment has no name")
    body_metadata = {"name": name}
    for key in ("labels", "annotations"):
        if metadata.get(key) is not None:
            body_metadata[key] = metadata[key]
    body = {"metadata": body_metadata}
    for key in ("kubernetesNamespace", "flinkApplicationDefaults", "computePoolDefaults"):
        if environment.get(key) is not None:
            body[key] = environment[key]
    defaults = {kind: block for kind, block in (environment.get("statementDefaults") or {}).items() if block is not None}
    if defaults:
        body["statementDefaults"] = defaults
    return body


class CmfClient:
    """Minimal CMF REST client."""

    def __init__(self, base_url, token=None):
        self.base_url = base_url.rstrip("/")
        self.token = token

    def _call(self, method, path, data=None, content_type=None):
        headers = {"Accept": "application/json"}
        if content_type:
            headers["Content-Type"] = content_type
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        return _http(method, self.base_url + path, headers, data)

    @staticmethod
    def _environment_path(env):
        return f"/cmf/api/v1/environments/{urllib.parse.quote(env, safe='')}"

    def environment_exists(self, env):
        path = self._environment_path(env)
        status, _ = self._call("GET", path)
        if status == 404:
            return False
        if status != 200:
            raise CmfError(f"GET {path} returned HTTP {status}")
        return True

    def get_environment(self, env):
        path = self._environment_path(env)
        status, body = self._call("GET", path)
        if status != 200:
            raise CmfError(f"GET {path} returned HTTP {status}")
        environment = json.loads(body)
        if not isinstance(environment, dict):
            raise CmfError(f"GET {path} did not return a JSON object")
        return environment

    def update_environment(self, env, body):
        """Create-or-update the environment named env with body (see environment_update_body)."""
        if body.get("metadata", {}).get("name") != env:
            raise ValueError(f"update body is not for environment {env}")
        status, _ = self._call("POST", "/cmf/api/v1/environments", json.dumps(body).encode(), "application/json")
        if not 200 <= status < 300:
            raise CmfError(f"updating environment {env} returned HTTP {status}")

    def artifact_exists(self, env, name):
        path = f"{self._environment_path(env)}/artifacts/{urllib.parse.quote(name, safe='')}"
        status, _ = self._call("GET", path)
        if status == 404:
            return False
        if status != 200:
            raise CmfError(f"GET {path} returned HTTP {status}")
        return True

    def upload_artifact(self, env, name, jar):
        path = f"{self._environment_path(env)}/artifacts"
        metadata = {"apiVersion": "cmf.confluent.io/v1", "kind": "Artifact", "metadata": {"name": name}, "spec": {}}
        boundary = uuid.uuid4().hex
        parts = [
            (
                f'--{boundary}\r\nContent-Disposition: form-data; name="artifact"\r\n'
                "Content-Type: application/json\r\n\r\n"
            ).encode()
            + json.dumps(metadata, separators=(",", ":")).encode()
            + b"\r\n",
            (
                f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\n'
                "Content-Type: application/java-archive\r\n\r\n"
            ).encode()
            + jar
            + b"\r\n",
            f"--{boundary}--\r\n".encode(),
        ]
        status, _ = self._call("POST", path, b"".join(parts), f"multipart/form-data; boundary={boundary}")
        if status == 409 or 200 <= status < 300:
            return
        raise CmfError(f"uploading artifact {name} returned HTTP {status}")


def wait_for_environment(client, env, timeout_s, interval_s=5, sleep=time.sleep):
    """Poll until the environment exists; raise TimeoutError after timeout_s of waiting."""
    waited = 0
    while not client.environment_exists(env):
        if waited >= timeout_s:
            raise TimeoutError(f"environment {env} did not appear within {timeout_s} seconds")
        sleep(interval_s)
        waited += interval_s


def parse_model_endpoints(raw):
    """Parse MODEL_ENDPOINTS into {name: url}; an unset or empty value means none."""
    if not raw or not raw.strip():
        return {}
    endpoints = json.loads(raw)
    valid = isinstance(endpoints, dict) and all(
        isinstance(name, str) and name and isinstance(url, str) and url for name, url in endpoints.items()
    )
    if not valid:
        raise ValueError("MODEL_ENDPOINTS must be a JSON object of model name to URL")
    return endpoints


def _run(environ, sleep):
    for key in ("CMF_URL", "ENVIRONMENT", "ARTIFACT_NAME", "JAR_URL", "JAR_SHA256"):
        if not environ.get(key):
            raise ValueError(f"{key} is not set")
    env = environ["ENVIRONMENT"]
    endpoints = parse_model_endpoints(environ.get("MODEL_ENDPOINTS"))
    wait_seconds = float(environ.get("WAIT_SECONDS") or DEFAULT_WAIT_S)

    token = None
    if environ.get("TOKEN_URL"):
        if not environ.get("OAUTH_FILE"):
            raise ValueError("OAUTH_FILE is not set")
        with open(environ["OAUTH_FILE"], encoding="utf-8") as handle:
            client_id, client_secret = parse_oauth_txt(handle.read())
        token = fetch_token(environ["TOKEN_URL"], client_id, client_secret)

    client = CmfClient(environ["CMF_URL"], token)
    wait_for_environment(client, env, wait_seconds, sleep=sleep)

    if endpoints:
        current = client.get_environment(env)
        merged = merge_model_endpoints(current, endpoints)
        if merged == current:
            print(f"environment {env}: model endpoints already set")
        else:
            client.update_environment(env, environment_update_body(merged))
            print(f"environment {env}: model endpoints set")

    name = environ["ARTIFACT_NAME"]
    if client.artifact_exists(env, name):
        print(f"artifact {name} already exists in {env}")
        return 0
    jar = download_jar(environ["JAR_URL"], environ["JAR_SHA256"])
    client.upload_artifact(env, name, jar)
    print(f"artifact {name} uploaded to {env}")
    return 0


def main(environ=os.environ, sleep=time.sleep):
    try:
        return _run(environ, sleep)
    except (ChecksumMismatch, CmfError, TimeoutError, ValueError, OSError) as error:
        message = " ".join(str(error).split()) or type(error).__name__
        print(f"ai-functions-setup: {message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
