#!/usr/bin/env bash
#
# slugify.sh - Derive and validate a <test-name> slug from a free-text description.
#
# Usage: ./slugify.sh "<description>"
#
# Prints the slug to stdout on success. Exits non-zero with an error on
# stderr if the description collapses to an empty or invalid slug.

set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 "<description>"

Derive a Kubernetes-DNS-1123-safe <test-name> slug from a free-text
description: lowercase, non-alphanumeric runs collapsed to a single hyphen,
trimmed, truncated to 40 characters (leaving headroom for suffixes like
-src-topic appended later).

Example:
  $0 "Verify Orders Aggregation SQL Job"
  # orders-aggregation-sql-job
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ $# -ne 1 ]; then
    usage
    exit 1
fi

description="$1"

slug=$(echo "$description" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g' \
    | sed -E 's/^-+//; s/-+$//')

slug="${slug:0:40}"
slug=$(echo "$slug" | sed -E 's/-+$//')

if [ -z "$slug" ]; then
    echo "ERROR: description produced an empty slug — ask the user for a short, plain-words name instead" >&2
    exit 1
fi

if ! [[ "$slug" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo "ERROR: derived slug '$slug' is not a valid Kubernetes DNS-1123 label" >&2
    exit 1
fi

echo "$slug"
