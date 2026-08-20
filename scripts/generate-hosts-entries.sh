#!/usr/bin/env bash
#
# generate-hosts-entries.sh - Print a ready-to-paste /etc/hosts block for a cluster
#
# Usage: ./scripts/generate-hosts-entries.sh <cluster-name> [ip-address]
#
# Hostnames are discovered from the cluster's own overlay manifests (Traefik
# `Host()` matches, cert-manager `dnsNames`, externalUrl/host fields, etc.)
# rather than hand-maintained, so the output can't drift from what's actually
# deployed. If ip-address is omitted: on macOS it defaults to 127.0.0.1 (your
# local machine); on Linux it auto-detects the public IP via
# `curl -4 ifconfig.me` (a remote VM); if that fails, you're prompted for one.
#
# Example:
#   ./scripts/generate-hosts-entries.sh flink-demo-rbac
#   ./scripts/generate-hosts-entries.sh flink-demo-rbac 203.0.113.42
#

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
}

warn() {
    echo -e "${YELLOW}WARNING: $1${NC}" >&2
}

usage() {
    cat <<EOF
Usage: $0 <cluster-name> [ip-address]

Print a /etc/hosts block for every hostname the given cluster's overlays
actually reference, pointed at ip-address.

Arguments:
  cluster-name  A directory under clusters/ (e.g. flink-demo-rbac)
  ip-address    Optional. Defaults to 127.0.0.1 on macOS (your local
                machine), or the caller's public IP on Linux (a remote VM),
                detected via 'curl -4 ifconfig.me'. Falls back to an
                interactive prompt if that detection isn't applicable.

Example:
  $0 flink-demo-rbac
  $0 flink-demo-rbac 127.0.0.1
EOF
}

if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    exit 0
fi

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    error "Invalid arguments"
    echo ""
    usage
    exit 1
fi

CLUSTER_NAME="$1"
IP_ADDRESS="${2:-}"

# Must run from repository root (handles both normal repos and worktrees)
if [ ! -e ".git" ] || [ ! -f "bootstrap/Chart.yaml" ]; then
    error "Must run from repository root"
    exit 1
fi

CLUSTER_DIR="clusters/$CLUSTER_NAME"
if [ ! -d "$CLUSTER_DIR" ]; then
    error "No such cluster: $CLUSTER_DIR"
    echo "Available clusters:" >&2
    find clusters -mindepth 1 -maxdepth 1 -type d -printf '  - %f\n' 2>/dev/null \
        || ls -1 clusters | sed 's/^/  - /'
    exit 1
fi

# Clusters that document their own DNS as externally managed (e.g. ExternalDNS
# + Route53) don't need /etc/hosts entries at all. Detect this from the
# cluster's own README rather than hardcoding cluster names, so it still works
# for future clusters.
if [ -f "$CLUSTER_DIR/README.md" ] && grep -qi "ExternalDNS" "$CLUSTER_DIR/README.md"; then
    warn "$CLUSTER_NAME's README documents ExternalDNS-managed DNS — no /etc/hosts entries are needed for this cluster."
    exit 0
fi

# Resolve the IP address to use, when one wasn't passed explicitly:
#   - macOS is assumed to be your local machine -> 127.0.0.1 (a kind cluster's
#     Ingress is only ever reachable via localhost port-mapping).
#   - Linux is assumed to be a remote VM with a public IP (e.g. a lab VSI) ->
#     auto-detect it via 'curl -4 ifconfig.me'.
#   - If that detection isn't applicable or fails, fall back to asking
#     interactively rather than guessing.
if [ -z "$IP_ADDRESS" ]; then
    case "$(uname -s)" in
        Darwin)
            IP_ADDRESS="127.0.0.1"
            warn "No IP address given — defaulting to $IP_ADDRESS (local macOS machine)."
            ;;
        Linux)
            warn "No IP address given — this looks like a remote Linux VM; auto-detecting its public IP via 'curl -4 ifconfig.me'."
            IP_ADDRESS="$(curl -4 -s --max-time 5 ifconfig.me || true)"
            if [ -n "$IP_ADDRESS" ]; then
                warn "Detected public IP: $IP_ADDRESS (pass an IP explicitly to override, e.g. 127.0.0.1 if this is actually local)"
            fi
            ;;
    esac

    if [ -z "$IP_ADDRESS" ]; then
        warn "Could not determine an IP address automatically."
        read -rp "Enter the IP address to use [127.0.0.1]: " IP_ADDRESS
        IP_ADDRESS="${IP_ADDRESS:-127.0.0.1}"
    fi
fi

# Every directory literally named overlays/<cluster-name>, wherever it lives
# in infrastructure/ or workloads/ - this is the same convention new-cluster.sh
# and the rest of the repo use to scope a cluster's overrides.
OVERLAY_DIRS=$(find infrastructure workloads -type d -path "*/overlays/$CLUSTER_NAME" 2>/dev/null | sort)

if [ -z "$OVERLAY_DIRS" ]; then
    error "No overlays found for $CLUSTER_NAME under infrastructure/ or workloads/"
    exit 1
fi

# Pull out any hostname of the form <label>.<cluster-name>.<domain...> from
# the overlay manifests - this matches Traefik `Host(\`...\`)` matches,
# cert-manager dnsNames entries, values.yaml externalUrl/host fields, and
# OAuth issuer URLs alike, without needing to special-case each resource kind.
# The `|| true` guards against `set -e`/pipefail exiting the script early when
# grep finds zero matches (exit 1) - we want to reach our own error message
# below instead, not a silent non-zero exit here.
HOSTNAMES=$( (echo "$OVERLAY_DIRS" | xargs -I{} find {} -type f \( -name '*.yaml' -o -name '*.yml' \) \
    | xargs grep -hoE "[a-zA-Z0-9-]+\.${CLUSTER_NAME}\.[a-zA-Z0-9.-]+" 2>/dev/null | sort -u) || true)

if [ -z "$HOSTNAMES" ]; then
    error "No hostnames found in: $OVERLAY_DIRS"
    exit 1
fi

echo "# /etc/hosts entries for $CLUSTER_NAME (generated $(date -u +%Y-%m-%dT%H:%M:%SZ))"
while IFS= read -r host; do
    printf '%s  %s\n' "$IP_ADDRESS" "$host"
done <<< "$HOSTNAMES"
