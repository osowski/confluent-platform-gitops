#!/usr/bin/env bash
#
# resource-state-check.sh - Run a kubectl get/describe check command and
# compare its output to an expected value. Backs the `resource-state`
# assertion kind — the one that covers config/Helm-chart verification.
#
# Usage: ./resource-state-check.sh "<check-command>" "<expect>"
#
# <expect> is an exact string match by default. Prefix it with "regex:" to
# match as a regular expression instead.

set -uo pipefail

usage() {
    cat <<EOF
Usage: $0 "<check-command>" "<expect>"

<check-command> is run as-is via bash -c (typically a "kubectl get ... -o
jsonpath=..." or "kubectl describe ..." command from test-case.yaml).

<expect> is matched against the trimmed stdout of <check-command>:
  exact string match by default
  "regex:<pattern>" to match as a bash [[ =~ ]] regular expression instead

Example:
  $0 "kubectl get deployment cmf -n confluent -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'" "2Gi"
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ $# -ne 2 ]; then
    usage
    exit 1
fi

check_command="$1"
expect="$2"

observed=$(bash -c "$check_command" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

if [[ "$expect" == regex:* ]]; then
    pattern="${expect#regex:}"
    if [[ "$observed" =~ $pattern ]]; then
        echo "PASS observed=[$observed] matches /$pattern/"
        exit 0
    else
        echo "FAIL observed=[$observed] does not match /$pattern/"
        exit 1
    fi
else
    if [ "$observed" = "$expect" ]; then
        echo "PASS observed=[$observed]"
        exit 0
    else
        echo "FAIL observed=[$observed] expected=[$expect]"
        exit 1
    fi
fi
