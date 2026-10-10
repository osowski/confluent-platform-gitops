#!/usr/bin/env bash
#
# data-flow-check.sh - Produce known input into a source topic, consume the
# sink topic, compare against an expected outcome. Backs the `data-flow`
# assertion kind.
#
# Usage: ./data-flow-check.sh <namespace> <test-name> <source-topic> <sink-topic> \
#          <bootstrap-servers> <messages-file> <expect-mode> <expect-value> [timeout-seconds]
#
# expect-mode is one of: exact | count | contains

set -uo pipefail

usage() {
    cat <<EOF
Usage: $0 <namespace> <test-name> <source-topic> <sink-topic> <bootstrap-servers> <messages-file> <expect-mode> <expect-value> [timeout-seconds]

expect-mode:
  exact     trimmed consumer output must equal expect-value exactly
  count     number of messages consumed must equal expect-value
  contains  consumer output must contain expect-value as a substring

Uses disposable kubectl-run pods (confluentinc/cp-kafka image) for both the
producer and the consumer; both are --rm, no cleanup needed afterward.

Prints "PASS ..." and exits 0 on success, "FAIL ..." and exits 1 otherwise.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ $# -lt 8 ]; then
    usage
    exit 1
fi

namespace="$1"
test_name="$2"
source_topic="$3"
sink_topic="$4"
bootstrap_servers="$5"
messages_file="$6"
expect_mode="$7"
expect_value="$8"
timeout_s="${9:-60}"

kafka_image="confluentinc/cp-kafka:7.7.0"

if [ ! -f "$messages_file" ]; then
    echo "ERROR: messages file not found: $messages_file" >&2
    exit 1
fi

echo "→ Producing $(wc -l < "$messages_file" | tr -d ' ') message(s) to $source_topic ..." >&2
if ! cat "$messages_file" | kubectl run "${test_name}-producer" -n "$namespace" --rm -i --restart=Never \
    --image="$kafka_image" -- kafka-console-producer --broker-list "$bootstrap_servers" --topic "$source_topic" >&2; then
    echo "FAIL producer pod failed to run"
    exit 1
fi

echo "→ Consuming $sink_topic for up to ${timeout_s}s ..." >&2
output=$(kubectl run "${test_name}-consumer" -n "$namespace" --rm -i --restart=Never \
    --image="$kafka_image" -- timeout "${timeout_s}s" kafka-console-consumer \
    --bootstrap-server "$bootstrap_servers" --topic "$sink_topic" --from-beginning 2>/dev/null)

case "$expect_mode" in
    exact)
        observed=$(echo "$output" | sed -e 's/[[:space:]]*$//')
        expected=$(echo "$expect_value" | sed -e 's/[[:space:]]*$//')
        if [ "$observed" = "$expected" ]; then
            echo "PASS observed matches expected exactly"
            exit 0
        else
            echo "FAIL observed=[$observed] expected=[$expected]"
            exit 1
        fi
        ;;
    count)
        observed_count=$(echo "$output" | grep -c . || true)
        if [ "$observed_count" = "$expect_value" ]; then
            echo "PASS observed_count=$observed_count"
            exit 0
        else
            echo "FAIL observed_count=$observed_count expected_count=$expect_value"
            exit 1
        fi
        ;;
    contains)
        if echo "$output" | grep -qF "$expect_value"; then
            echo "PASS output contains expected substring"
            exit 0
        else
            echo "FAIL output does not contain [$expect_value]; observed=[$output]"
            exit 1
        fi
        ;;
    *)
        echo "ERROR: unknown expect-mode '$expect_mode' (use exact|count|contains)" >&2
        exit 1
        ;;
esac
