#!/usr/bin/env bash
#
# reset-session.sh - Empty the Device Trust Mesh for a fresh demo session
#
# Runs in the cluster as the dtm-reset Job (workloads/device-trust-mesh/reset-job.yaml):
#   kubectl create -f workloads/device-trust-mesh/reset-job.yaml
#
# Every pane of the mesh UI starts empty afterwards (devices, traffic feed, busiest pairs,
# latencies), while topics, schemas, Agent Cards, the DDL statements and the agents survive.
#

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="device-trust-mesh"
ARGOCD_NAMESPACE="argocd"
APPLICATION="device-trust-mesh"
KAFKA_NAMESPACE="kafka"
BROKER_POD="kafka-0"
BOOTSTRAP="kafka.kafka.svc.cluster.local:9071"
# none: the internal listener is anonymous. oauth: authenticate as the broker's own OAuth
# client, a super user, reading its credentials from the broker's mounted secret.
KAFKA_AUTH="${DTM_RESET_KAFKA_AUTH:-none}"
TOKEN_URL="${DTM_RESET_TOKEN_URL:-}"
BROKER_OAUTH_SECRET="/mnt/secrets/kafka-oauth-client/oauth.txt"
CLIENT_CONFIG="/tmp/dtm-reset-client.properties"
KAFKA_CLI_OPTS=""
SIMULATOR="device-simulator"
UI="device-trust-mesh-ui"
RAY_SELECTOR="ray.io/is-ray-node=yes"
CONTEXT_MCP_URL="http://device-trust-mesh-serve-svc.device-trust-mesh.svc.cluster.local:8000/context-mcp"
# Agent Cards are the agents' published identity, not session data.
KEEP_TOPICS=" agent.cards agent.cards_human_readable "
WAIT_TIMEOUT_S=600
DRY_RUN=false

# Helper functions
error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
}

success() {
    echo -e "${GREEN}✓ $1${NC}"
}

info() {
    echo -e "${YELLOW}→ $1${NC}"
}

debug() {
    echo -e "${BLUE}  $1${NC}"
}

usage() {
    cat <<EOF
Usage: $0 [--dry-run]

Empty the Device Trust Mesh for a fresh demo session. Runs as the dtm-reset Job.

Steps:
  1. Scale the simulator to 0.
  2. Delete the long-running FlinkStatements (the dtm-ddl-* statements stay).
  3. Switch the compacted session topics to compact,delete so they can be purged.
  4. Purge every session topic in place with kafka-delete-records (Agent Cards stay).
  5. Restart the Ray pods, so context-mcp reloads empty tables and in-flight agent work stops.
  6. Purge again, to drop anything the agents wrote before they stopped.
  7. Sync the ${APPLICATION} Application: the statements come back and the topic
     policies return to what git declares.
  8. Wait for the statements to be RUNNING, then restart the UI.
  9. Check that context-mcp lists no devices and the UI reports nothing stale.

The simulator stays at 0 replicas; start the session with:
  kubectl -n ${NAMESPACE} scale deploy ${SIMULATOR} --replicas=1

Options:
  --dry-run         Show the plan and the commands without changing anything

Environment (from the dtm-reset-settings ConfigMap):
  DTM_RESET_KAFKA_AUTH  none or oauth (default: none)
  DTM_RESET_TOKEN_URL   OAuth token endpoint, required with oauth
EOF
}

kc() {
    kubectl --request-timeout=30s "$@"
}

# Runs a command that changes the cluster, or prints it under --dry-run.
run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        debug "[dry-run] $*"
    else
        "$@"
    fi
}

# Polls a command until it succeeds or WAIT_TIMEOUT_S passes.
wait_for() {
    local description="$1"
    shift
    local deadline=$((SECONDS + WAIT_TIMEOUT_S))
    until "$@" >/dev/null 2>&1; do
        if ((SECONDS >= deadline)); then
            error "Timed out after ${WAIT_TIMEOUT_S}s waiting for ${description}"
            return 1
        fi
        sleep 5
    done
}

broker() {
    kc -n "$KAFKA_NAMESPACE" exec -i "$BROKER_POD" -c kafka -- \
        env ${KAFKA_CLI_OPTS:+"KAFKA_OPTS=${KAFKA_CLI_OPTS}"} "$@"
}

# Client properties for the Kafka CLI. The oauth variant names the broker's secret file
# through the file config provider, so the credentials never leave the broker pod.
client_config() {
    if [[ "$KAFKA_AUTH" == "oauth" ]]; then
        cat <<EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=OAUTHBEARER
sasl.oauthbearer.token.endpoint.url=${TOKEN_URL}
sasl.login.callback.handler.class=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginCallbackHandler
config.providers=file
config.providers.file.class=org.apache.kafka.common.config.provider.FileConfigProvider
sasl.oauthbearer.client.credentials.client.id=\${file:${BROKER_OAUTH_SECRET}:clientId}
sasl.oauthbearer.client.credentials.client.secret=\${file:${BROKER_OAUTH_SECRET}:clientSecret}
sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required ;
EOF
    else
        echo "security.protocol=PLAINTEXT"
    fi
}

topic_policy_is() {
    broker kafka-configs --bootstrap-server "$BOOTSTRAP" --command-config "$CLIENT_CONFIG" \
        --describe --entity-type topics --entity-name "$1" | grep -q "cleanup.policy=$2 "
}

# Moves every partition's start offset to its end; -1 means the partition's high watermark.
purge_topics() {
    local entries="" count=0 topic partitions p
    while read -r topic partitions; do
        for ((p = 0; p < partitions; p++)); do
            entries="${entries:+${entries},}{\"topic\":\"${topic}\",\"partition\":${p},\"offset\":-1}"
            count=$((count + 1))
        done
    done <<< "$PURGE_LINES"
    if [[ "$DRY_RUN" == "true" ]]; then
        debug "[dry-run] kafka-delete-records on ${count} partitions"
        return
    fi
    local purged
    purged=$(echo "{\"version\":1,\"partitions\":[${entries}]}" |
        broker bash -c "cat > /tmp/dtm-reset-offsets.json && kafka-delete-records \
        --bootstrap-server ${BOOTSTRAP} --command-config ${CLIENT_CONFIG} \
        --offset-json-file /tmp/dtm-reset-offsets.json" | grep -c 'low_watermark' || true)
    if [[ "$purged" != "$count" ]]; then
        error "kafka-delete-records purged ${purged} of ${count} partitions"
        return 1
    fi
    debug "purged ${purged} partitions"
}

statements_running() {
    local name phase
    for name in $STATEMENTS; do
        phase=$(kc -n "$NAMESPACE" get flinkstatement "$name" -o jsonpath='{.status.phase}' 2>/dev/null)
        [[ "$phase" == "RUNNING" ]] || return 1
    done
}

sync_succeeded() {
    [[ "$(kc -n "$ARGOCD_NAMESPACE" get application "$APPLICATION" \
        -o jsonpath='{.status.operationState.phase}')" == "Succeeded" ]]
}

ray_ready() {
    local pods
    pods=$(kc -n "$NAMESPACE" get pods -l "$RAY_SELECTOR" -o name)
    [[ -n "$pods" ]] && kc -n "$NAMESPACE" wait --for=condition=Ready pod -l "$RAY_SELECTOR" --timeout=5s
}

ui_get() {
    kc -n "$NAMESPACE" exec "deploy/${UI}" -- python -c \
        "import urllib.request, sys; print(urllib.request.urlopen(sys.argv[1], timeout=5).read().decode())" "$1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        -h|--help) usage; exit 0 ;;
        *) error "Unknown argument: $1"; usage; exit 1 ;;
    esac
    shift
done

# Preflight
command -v kubectl >/dev/null || { error "kubectl not found"; exit 1; }
# kubectl uses the in-cluster config only when no client flag changes its defaults, and
# --request-timeout does, so point it at the pod's ServiceAccount through a kubeconfig.
SA_DIR="/var/run/secrets/kubernetes.io/serviceaccount"
[[ -f "${SA_DIR}/token" ]] || { error "no ServiceAccount token at ${SA_DIR}; run this as the dtm-reset Job"; exit 1; }
export KUBECONFIG="/tmp/dtm-reset-kubeconfig"
export KUBECACHEDIR="/tmp/dtm-reset-kube-cache"
cat > "$KUBECONFIG" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: in-cluster
    cluster:
      server: https://kubernetes.default.svc
      certificate-authority: ${SA_DIR}/ca.crt
users:
  - name: dtm-reset
    user:
      tokenFile: ${SA_DIR}/token
contexts:
  - name: in-cluster
    context:
      cluster: in-cluster
      user: dtm-reset
current-context: in-cluster
EOF
case "$KAFKA_AUTH" in
    none) ;;
    oauth)
        [[ -n "$TOKEN_URL" ]] || { error "DTM_RESET_TOKEN_URL is required with DTM_RESET_KAFKA_AUTH=oauth"; exit 1; }
        KAFKA_CLI_OPTS="-Dorg.apache.kafka.sasl.oauthbearer.allowed.urls=${TOKEN_URL}"
        ;;
    *) error "DTM_RESET_KAFKA_AUTH must be none or oauth, not '${KAFKA_AUTH}'"; exit 1 ;;
esac
kc -n "$ARGOCD_NAMESPACE" get application "$APPLICATION" >/dev/null ||
    { error "Argo CD Application ${APPLICATION} not found"; exit 1; }
kc -n "$KAFKA_NAMESPACE" get pod "$BROKER_POD" >/dev/null ||
    { error "broker pod ${KAFKA_NAMESPACE}/${BROKER_POD} not found"; exit 1; }
# Written on every run, dry runs included, so the topic checks can authenticate.
client_config | broker bash -c "cat > ${CLIENT_CONFIG}"
broker kafka-configs --bootstrap-server "$BOOTSTRAP" --command-config "$CLIENT_CONFIG" \
    --describe --entity-type brokers --entity-default >/dev/null ||
    { error "Kafka CLI cannot reach ${BOOTSTRAP} with DTM_RESET_KAFKA_AUTH=${KAFKA_AUTH}"; exit 1; }

STATEMENTS=$(kc -n "$NAMESPACE" get flinkstatements \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -v '^dtm-ddl-' || true)
STATEMENT_COUNT=$(echo "$STATEMENTS" | grep -c . || true)

PURGE_LINES=""
PURGE_TOPICS=""
COMPACT_CRS=""
COMPACT_TOPICS=""
while read -r cr topic partitions policy; do
    [[ -z "$topic" || "$KEEP_TOPICS" == *" ${topic} "* ]] && continue
    PURGE_LINES="${PURGE_LINES:+${PURGE_LINES}
}${topic} ${partitions}"
    PURGE_TOPICS="${PURGE_TOPICS} ${topic}"
    if [[ "$policy" == "compact" ]]; then
        COMPACT_CRS="${COMPACT_CRS} ${cr}"
        COMPACT_TOPICS="${COMPACT_TOPICS} ${topic}"
    fi
done < <(kc -n "$NAMESPACE" get kafkatopics -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.name}{" "}{.spec.partitionCount}{" "}{.spec.configs.cleanup\.policy}{"\n"}{end}')

if [[ -z "$PURGE_LINES" ]]; then
    error "no session topics found in namespace ${NAMESPACE}"
    exit 1
fi

info "Reset plan (Kafka auth: ${KAFKA_AUTH})"
debug "Statements to recreate (${STATEMENT_COUNT}): $(echo $STATEMENTS)"
debug "Topics to purge:${PURGE_TOPICS}"
debug "Compacted topics switched to compact,delete for the purge:${COMPACT_TOPICS:- none}"
debug "Topics kept:${KEEP_TOPICS}"
[[ "$DRY_RUN" == "true" ]] && info "Dry run: nothing will change"

info "1/9 Scaling ${SIMULATOR} to 0"
run kc -n "$NAMESPACE" scale deploy "$SIMULATOR" --replicas=0

info "2/9 Deleting ${STATEMENT_COUNT} long-running statements"
if [[ -n "$STATEMENTS" ]]; then
    # shellcheck disable=SC2086 # one argument per statement name
    run kc -n "$NAMESPACE" delete flinkstatement $STATEMENTS --wait=true --timeout=300s
fi

info "3/9 Switching compacted topics to compact,delete:${COMPACT_TOPICS:- none}"
for cr in $COMPACT_CRS; do
    run kc -n "$NAMESPACE" patch kafkatopic "$cr" --type merge \
        -p '{"spec":{"configs":{"cleanup.policy":"compact,delete"}}}'
done
if [[ "$DRY_RUN" != "true" ]]; then
    for topic in $COMPACT_TOPICS; do
        wait_for "${topic} to allow deletion" topic_policy_is "$topic" "compact,delete"
    done
fi

info "4/9 Purging session topics"
purge_topics

info "5/9 Restarting the Ray pods"
run kc -n "$NAMESPACE" delete pod -l "$RAY_SELECTOR" --wait=true --timeout=300s
[[ "$DRY_RUN" == "true" ]] || wait_for "the Ray pods to be Ready" ray_ready

info "6/9 Purging again to drop in-flight agent writes"
purge_topics

info "7/9 Syncing ${APPLICATION}"
revision=$(kc -n "$ARGOCD_NAMESPACE" get application "$APPLICATION" -o jsonpath='{.spec.source.targetRevision}')
run kc -n "$ARGOCD_NAMESPACE" patch application "$APPLICATION" --type merge \
    -p "{\"operation\":{\"initiatedBy\":{\"username\":\"dtm-reset\"},\"sync\":{\"revision\":\"${revision}\",\"syncStrategy\":{\"hook\":{}}}}}"
[[ "$DRY_RUN" == "true" ]] || wait_for "the ${APPLICATION} sync" sync_succeeded

info "8/9 Waiting for the statements, then restarting the UI"
if [[ "$DRY_RUN" != "true" ]]; then
    wait_for "${STATEMENT_COUNT} statements to be RUNNING" statements_running
    for topic in $COMPACT_TOPICS; do
        wait_for "${topic} to return to compact" topic_policy_is "$topic" "compact"
    done
fi
if kc -n "$NAMESPACE" get deploy "$UI" >/dev/null 2>&1; then
    run kc -n "$NAMESPACE" rollout restart deploy "$UI"
    run kc -n "$NAMESPACE" rollout status deploy "$UI" --timeout=300s
else
    debug "No ${UI} Deployment; skipping"
fi

info "9/9 Checking the result"
if [[ "$DRY_RUN" == "true" ]]; then
    success "Dry run complete"
    exit 0
fi
devices=$(ui_get "${CONTEXT_MCP_URL}/v1/devices" | tr -d '[:space:]')
if [[ "$devices" != "[]" ]]; then
    error "context-mcp still lists devices: ${devices:0:200}"
    exit 1
fi
health=$(ui_get "http://localhost:8080/healthz")
if [[ "$health" != *'"kafka_stale_since_ms":null'*'"context_stale_since_ms":null'* ]]; then
    error "UI reports a stale source: ${health}"
    exit 1
fi
success "Device Trust Mesh is empty and ready"
echo "Start the session with: kubectl -n ${NAMESPACE} scale deploy ${SIMULATOR} --replicas=1"
