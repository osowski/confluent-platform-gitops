#!/usr/bin/env bash
#
# rest-call.sh - Issue a REST call, log it to tests/<test-name>/rest-commands.md
# in execution order, print the response body to stdout. Backs the
# `rest-response` assertion kind, and Manual mode's REST fallback for setup.
#
# Usage: ./rest-call.sh <test-name> <method> <url> [body-file]
#
# Always logs; every REST call made by this skill goes through this script
# so rest-commands.md is a complete, ordered audit trail.

set -uo pipefail

usage() {
    cat <<EOF
Usage: $0 <test-name> <method> <url> [body-file]

Issues:
  curl -sS -X <method> <url> [-H 'Content-Type: application/json' --data @<body-file>]

Appends an entry to tests/<test-name>/rest-commands.md with the exact
command run (real values, no placeholders), HTTP status, and a response
summary. Prints the raw response body to stdout so the caller can evaluate
a jq expression against it.

Exit code reflects curl's own transport-level success, not HTTP status —
check the printed status yourself for 4xx/5xx.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ $# -lt 3 ]; then
    usage
    exit 1
fi

test_name="$1"
method="$2"
url="$3"
body_file="${4:-}"

out_dir="tests/${test_name}"
log_file="${out_dir}/rest-commands.md"
mkdir -p "$out_dir"

if [ ! -f "$log_file" ]; then
    echo "# REST commands — ${test_name}" > "$log_file"
    echo "" >> "$log_file"
    echo "Every REST call made during this test run, in execution order." >> "$log_file"
    echo "" >> "$log_file"
fi

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [ -n "$body_file" ]; then
    if [ ! -f "$body_file" ]; then
        echo "ERROR: body file not found: $body_file" >&2
        exit 1
    fi
    curl_cmd="curl -sS -X ${method} ${url} -H 'Content-Type: application/json' --data @${body_file}"
    response=$(curl -sS -w '\n%{http_code}' -X "$method" "$url" -H 'Content-Type: application/json' --data @"$body_file")
else
    curl_cmd="curl -sS -X ${method} ${url}"
    response=$(curl -sS -w '\n%{http_code}' -X "$method" "$url")
fi

status=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

{
    echo "## ${timestamp}"
    echo ""
    echo '```bash'
    echo "$curl_cmd"
    echo '```'
    echo ""
    echo "Status: \`${status}\`"
    echo ""
    echo '```json'
    echo "$body" | head -c 2000
    echo ""
    echo '```'
    echo ""
} >> "$log_file"

echo "$body"
echo "HTTP status: $status" >&2
