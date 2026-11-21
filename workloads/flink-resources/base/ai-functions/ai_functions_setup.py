"""Set up AI functions in one Confluent Manager for Apache Flink (CMF) environment.

Runs as a hook Job and is safe to run repeatedly. Python standard library only.

Steps, in order:
  1. Fetch an OAuth token (only when TOKEN_URL is set).
  2. Wait for the environment to exist in CMF.
  3. Write the model-server URLs into the environment's statement defaults
     (only when MODEL_ENDPOINTS is set). The script owns every
     `ai.models.<name>.endpoint` key in the `interactive` and `detached` blocks:
     a key for a model not in MODEL_ENDPOINTS is removed.
  4. Check the artifact. If it is missing, download the JAR, verify its sha256,
     and upload it, then read it back: its latest version must be READY with the
     pinned sha256 (an upload answered with 409, because another run created the
     artifact first, is accepted only on that condition). If it already exists,
     the same rule applies and the script changes nothing.

Environment variables:
  CMF_URL, ENVIRONMENT, ARTIFACT_NAME, JAR_URL, JAR_SHA256   required
  TOKEN_URL, OAUTH_FILE      client-credentials token fetch; OAUTH_FILE holds
                             `clientId=` and `clientSecret=` lines
  MODEL_ENDPOINTS            JSON object mapping a model name to its URL,
                             e.g. {"ttm": "http://model-server:8080/v1/forecast"}
  WAIT_SECONDS               how long to wait for the environment (default 300)

Every failure writes one line to stderr. The exit code is 2 for an error that
running again cannot fix (a missing or malformed variable, an OAuth file without
its clientId or clientSecret line, a JAR or artifact that does not match the
pinned sha256, an artifact in a phase other than READY, UPLOADING or
STORE_UNREACHABLE, HTTP 401 or 403 from the token endpoint, an environment body
that fails its safety check) and 1 for everything else, including an artifact
that is UPLOADING or STORE_UNREACHABLE and any HTTP error status from CMF, 401
and 403 included (CMF also answers 401 when a role binding is not effective
yet). A failed CMF call includes CMF's error detail, truncated. Tokens, client
secrets and the OAuth file contents are never printed.
"""

import copy
import hashlib
import http.client
import json
import os
import re
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
ERROR_DETAIL_CHARS = 300
EXIT_RETRYABLE = 1
EXIT_NOT_RETRYABLE = 2
SHA256_HEX = re.compile(r"[0-9a-fA-F]{64}")
MODEL_KEY_PREFIX = "ai.models."
MODEL_KEY_SUFFIX = ".endpoint"
TRANSIENT_ARTIFACT_PHASES = ("UPLOADING", "STORE_UNREACHABLE")


class NotRetryable(Exception):
    """An error that running the script again cannot fix; main exits 2 for it."""


class ConfigError(NotRetryable, ValueError):
    """A required environment variable is missing or malformed."""


class UnsafeUpdate(NotRetryable, ValueError):
    """An environment update body failed its safety check and was not sent."""


class ChecksumMismatch(NotRetryable):
    """The downloaded JAR does not match the pinned sha256."""


class ArtifactMismatch(NotRetryable):
    """The existing artifact is in a phase that does not clear, does not match the pin, or could not be read."""


class CmfError(Exception):
    """CMF (or the token endpoint) answered with an unexpected status."""


class ArtifactPending(CmfError):
    """The existing artifact is in a phase that can clear by itself."""


class AuthError(CmfError, NotRetryable):
    """The token endpoint answered HTTP 401 or 403."""


def error_detail(body):
    """Return a one-line, truncated summary of a CMF error body, or "" for an empty one.

    CMF error bodies are `{"errors": [{"message": ...}]}`; their messages are
    preferred, and any other body is used as text.
    """
    text = (body or b"").decode("utf-8", errors="replace").strip()
    if not text:
        return ""
    try:
        payload = json.loads(text)
    except ValueError:
        payload = text
    if payload in ({}, [], None):
        return ""
    if isinstance(payload, dict) and isinstance(payload.get("errors"), list):
        messages = [
            error["message"]
            for error in payload["errors"]
            if isinstance(error, dict) and isinstance(error.get("message"), str) and error["message"].strip()
        ]
        if messages:
            text = "; ".join(messages)
    text = " ".join(text.split())
    if len(text) > ERROR_DETAIL_CHARS:
        text = text[: ERROR_DETAIL_CHARS - 3] + "..."
    return text


def cmf_error(what, status, body):
    """Return the exception for a CMF call that answered `status`, with CMF's error detail."""
    message = f"{what} returned HTTP {status}"
    detail = error_detail(body)
    if detail:
        message = f"{message}: {detail}"
    # Every CMF status is retryable, 401 and 403 included: CMF answers 401 for an
    # authorization denial too, and a new role binding can take a while to apply.
    return CmfError(message)


def parse_oauth_txt(text):
    """Return (client id, client secret) from `clientId=`/`clientSecret=` lines."""
    values = {}
    for line in text.splitlines():
        key, separator, value = line.partition("=")
        if separator:
            values[key.strip()] = value.strip()
    for key in ("clientId", "clientSecret"):
        if not values.get(key):
            raise ConfigError(f"OAuth file has no {key} line")
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
        # The token endpoint's error body is left out: it is not CMF's and may echo the request.
        raise (AuthError if status in (401, 403) else CmfError)(f"token request returned HTTP {status}")
    payload = json.loads(body)
    token = payload.get("access_token") if isinstance(payload, dict) else None
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


def is_model_endpoint_key(key):
    """True for a key of the form `ai.models.<name>.endpoint` with a non-empty name."""
    return (
        key.startswith(MODEL_KEY_PREFIX)
        and key.endswith(MODEL_KEY_SUFFIX)
        and len(key) > len(MODEL_KEY_PREFIX) + len(MODEL_KEY_SUFFIX)
    )


def merge_model_endpoints(environment, endpoints):
    """Return a copy of a CMF environment whose model endpoint keys match endpoints.

    In both statementDefaults.interactive.flinkConfiguration and
    statementDefaults.detached.flinkConfiguration, `ai.models.<name>.endpoint`
    is set for each entry of endpoints and removed for any other name. Null or
    missing blocks are created; every other key is left as it was.
    """
    wanted = {f"{MODEL_KEY_PREFIX}{name}{MODEL_KEY_SUFFIX}": url for name, url in endpoints.items()}
    merged = copy.deepcopy(environment)
    defaults = merged.get("statementDefaults") or {}
    for kind in STATEMENT_KINDS:
        block = defaults.get(kind) or {}
        configuration = block.get("flinkConfiguration") or {}
        for key in [key for key in configuration if is_model_endpoint_key(key) and key not in wanted]:
            del configuration[key]
        configuration.update(wanted)
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

    The body is built from an allow-list of fields. A settable field that a later
    CMF version adds is not carried over, and because the update replaces
    everything it omits, that field would be reset to its default. Re-check the
    environment's fields on a CMF upgrade and extend the list.
    """
    metadata = environment.get("metadata") or {}
    name = metadata.get("name") or environment.get("name")
    if not name:
        raise UnsafeUpdate("environment has no name")
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
        status, body = self._call("GET", path)
        if status == 404:
            return False
        if status != 200:
            raise cmf_error(f"GET {path}", status, body)
        return True

    def get_environment(self, env):
        path = self._environment_path(env)
        status, body = self._call("GET", path)
        if status != 200:
            raise cmf_error(f"GET {path}", status, body)
        environment = json.loads(body)
        if not isinstance(environment, dict):
            raise CmfError(f"GET {path} did not return a JSON object")
        return environment

    def update_environment(self, env, body):
        """Create-or-update the environment named env with body (see environment_update_body)."""
        if body.get("metadata", {}).get("name") != env:
            raise UnsafeUpdate(f"update body is not for environment {env}")
        # createOrUpdate: this would create the environment if it vanished between the wait and this POST.
        status, response = self._call(
            "POST", "/cmf/api/v1/environments", json.dumps(body).encode(), "application/json"
        )
        if not 200 <= status < 300:
            raise cmf_error(f"updating environment {env}", status, response)

    def get_artifact(self, env, name):
        """Return the artifact as CMF reports it (its status is the latest version's), or None if absent."""
        path = f"{self._environment_path(env)}/artifacts/{urllib.parse.quote(name, safe='')}"
        status, body = self._call("GET", path)
        if status == 404:
            return None
        if status != 200:
            raise cmf_error(f"GET {path}", status, body)
        return json.loads(body)

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
        status, body = self._call("POST", path, b"".join(parts), f"multipart/form-data; boundary={boundary}")
        if status == 409 or 200 <= status < 300:
            return
        raise cmf_error(f"uploading artifact {name}", status, body)


def check_existing_artifact(env, name, artifact, sha256_hex):
    """Return if the artifact's latest version is READY with the pinned sha256, else raise.

    A phase that can clear by itself (UPLOADING, STORE_UNREACHABLE) raises the
    retryable ArtifactPending. Any other phase, a different checksum or an
    unreadable status raises ArtifactMismatch. The script never replaces an
    existing artifact: the functions registered from it keep using the stored
    JAR, so a mismatch is resolved by hand.
    """
    status = artifact.get("status") if isinstance(artifact, dict) else None
    phase = status.get("phase") if isinstance(status, dict) else None
    if not isinstance(phase, str) or not phase:
        raise ArtifactMismatch(
            f"artifact {name} in environment {env}: unexpected CMF response, no status.phase for its latest version"
        )
    if phase in TRANSIENT_ARTIFACT_PHASES:
        raise ArtifactPending(f"artifact {name} in environment {env} is {phase}; the Job will retry")
    checksum = status.get("checksum")
    expected = f"sha256:{sha256_hex.strip().lower()}"
    if phase == "READY" and isinstance(checksum, str) and checksum.lower() == expected:
        return
    raise ArtifactMismatch(
        f"artifact {name} in environment {env} is {phase} with checksum {checksum or 'none'}, expected READY "
        f"with {expected}; drop the registered functions, delete the artifact and the create-ai-* FlinkStatement "
        "CRs (see ADR-0026, teardown), then sync again"
    )


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
    message = "MODEL_ENDPOINTS must be a JSON object of model name to URL"
    try:
        endpoints = json.loads(raw)
    except ValueError:
        raise ConfigError(message) from None
    valid = isinstance(endpoints, dict) and all(
        isinstance(name, str) and name and isinstance(url, str) and url for name, url in endpoints.items()
    )
    if not valid:
        raise ConfigError(message)
    return endpoints


def _run(environ, sleep):
    for key in ("CMF_URL", "ENVIRONMENT", "ARTIFACT_NAME", "JAR_URL", "JAR_SHA256"):
        if not environ.get(key):
            raise ConfigError(f"{key} is not set")
    if not SHA256_HEX.fullmatch(environ["JAR_SHA256"].strip()):
        raise ConfigError("JAR_SHA256 must be 64 hexadecimal characters")
    env = environ["ENVIRONMENT"]
    endpoints = parse_model_endpoints(environ.get("MODEL_ENDPOINTS"))
    try:
        wait_seconds = float(environ.get("WAIT_SECONDS") or DEFAULT_WAIT_S)
    except ValueError:
        raise ConfigError("WAIT_SECONDS must be a number of seconds") from None

    token = None
    if environ.get("TOKEN_URL"):
        if not environ.get("OAUTH_FILE"):
            raise ConfigError("OAUTH_FILE is not set")
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
    artifact = client.get_artifact(env, name)
    if artifact is not None:
        check_existing_artifact(env, name, artifact, environ["JAR_SHA256"])
        print(f"artifact {name} already exists in {env} (READY, sha256 matches)")
        return 0
    jar = download_jar(environ["JAR_URL"], environ["JAR_SHA256"])
    client.upload_artifact(env, name, jar)
    # A 409 means another run created the artifact first, so what is stored is not necessarily this JAR.
    stored = client.get_artifact(env, name)
    if stored is None:
        raise CmfError(f"artifact {name} in environment {env} is not visible after the upload; the Job will retry")
    check_existing_artifact(env, name, stored, environ["JAR_SHA256"])
    print(f"artifact {name} uploaded to {env} (READY, sha256 matches)")
    return 0


def _report(error):
    message = " ".join(str(error).split()) or type(error).__name__
    print(f"ai-functions-setup: {message}", file=sys.stderr)


def main(environ=os.environ, sleep=time.sleep):
    try:
        return _run(environ, sleep)
    except NotRetryable as error:
        _report(error)
        return EXIT_NOT_RETRYABLE
    except (CmfError, TimeoutError, ValueError, OSError, http.client.HTTPException) as error:
        _report(error)
        return EXIT_RETRYABLE


if __name__ == "__main__":
    sys.exit(main())
