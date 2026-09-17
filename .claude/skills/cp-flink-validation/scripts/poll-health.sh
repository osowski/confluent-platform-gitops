#!/usr/bin/env bash
#
# poll-health.sh - Poll a kubectl jsonpath field until it matches an expected
# value, or time out. Backs the `health` assertion kind.
#
# Usage: ./poll-health.sh <namespace> <resource-type> <resource-name> <jsonpath> <expected-value> [timeout-seconds]
#
# Example:
#   ./poll-health.sh flink flinkstatement orders-agg '{.status.jobStatus.state}' RUNNING 120

set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 <namespace> <resource-type> <resource-name> <jsonpath> <expected-value> [timeout-seconds]

Polls:
  kubectl get <resource-type> <resource-name> -n <namespace> -o jsonpath=<jsonpath>
every 5 seconds until the output equals <expected-value>, or <timeout-seconds>
(default 120) elapses.

Prints "PASS observed=<value>" and exits 0 on success.
Prints "FAIL observed=<value> expected=<expected-value>" and exits 1 on timeout.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ $# -lt 5 ]; then
    usage
    exit 1
fi

namespace="$1"
resource_type="$2"
resource_name="$3"
jsonpath="$4"
expected="$5"
timeout="${6:-120}"

elapsed=0
interval=5
observed=""

while [ "$elapsed" -lt "$timeout" ]; do
    observed=$(kubectl get "$resource_type" "$resource_name" -n "$namespace" -o "jsonpath=$jsonpath" 2>/dev/null || echo "")

    if [ "$observed" = "$expected" ]; then
        echo "PASS observed=$observed"
        exit 0
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
done

echo "FAIL observed=$observed expected=$expected (timed out after ${timeout}s)"
exit 1
