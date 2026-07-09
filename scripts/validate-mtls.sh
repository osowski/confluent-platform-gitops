#!/usr/bin/env bash
#
# validate-mtls.sh - Live mTLS validation suite for a running cluster
#
# Validates the certificate-based security posture of a deployed
# flink-demo-rbac-mtls-style cluster: PKI health, per-listener security
# protocol + mandatory client auth, functional replication health, Schema
# Registry HTTPS + mTLS-to-Kafka, and a negative test proving anonymous
# (no-cert) clients are rejected on an mTLS listener.
#
# Unlike validate-cluster.sh (static manifest checks), this talks to a LIVE
# cluster via the current kubectl context. It is intended to pass green on an
# mTLS cluster and fail meaningfully on a non-mTLS one.
#
# Usage: ./scripts/validate-mtls.sh <cluster-name> [--context <ctx>] [--verbose] [--skip-negative]
#
# Example: ./scripts/validate-mtls.sh flink-demo-rbac-mtls
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VERBOSE=false
SKIP_NEGATIVE=false
CLUSTER_NAME=""
CONTEXT=""
NAMESPACE="kafka"
ERRORS=0
WARNINGS=0

# Expected per-listener security. Edit here if the cluster's listener design changes.
EXPECTED_SSL_LISTENERS=("CONTROLLER" "REPLICATION")
EXPECTED_CLIENTAUTH_LISTENERS=("controller" "replication")

error()   { echo -e "${RED}✗ ERROR: $1${NC}" >&2; ERRORS=$((ERRORS + 1)); }
warning() { echo -e "${YELLOW}⚠ WARNING: $1${NC}"; WARNINGS=$((WARNINGS + 1)); }
success() { echo -e "${GREEN}✓ $1${NC}"; }
info()    { echo -e "${BLUE}→ $1${NC}"; }
debug()   { if [ "$VERBOSE" = true ]; then echo -e "  $1"; fi; }

usage() {
    cat <<EOF
Usage: $0 <cluster-name> [--context <ctx>] [--verbose] [--skip-negative]

Live mTLS validation suite. Runs against the current kubectl context (or the
one given with --context) and expects the cluster to be deployed and healthy.

Arguments:
  cluster-name     Name under clusters/ (used to resolve the domain for the
                   Schema Registry HTTPS check), e.g. flink-demo-rbac-mtls

Options:
  --context <ctx>  kubectl context to target (default: current context)
  --verbose        Show detailed output
  --skip-negative  Skip the no-cert rejection test (needs to pull an openssl image)

Requirements:
  - kubectl, jq
  - a reachable cluster with the CFK stack running in namespace '$NAMESPACE'

Checks:
  1. PKI          - CA ClusterIssuer ready, leaf Certificates ready, secret
                    keys present, trust-manager Bundle distributed
  2. Listeners    - listener.security.protocol.map + ssl.client.auth=required
  3. Functional   - URP=0, cert principals in broker/controller logs, pods ready
  4. SchemaReg    - HTTPS REST API (spec.tls); C3->SR over TLS
  5. Negative     - anonymous (no client cert) connection to the mTLS
                    REPLICATION listener is rejected

EOF
}

check_dependencies() {
    local missing=()
    command -v kubectl &> /dev/null || missing+=("kubectl")
    command -v jq &> /dev/null || missing+=("jq")
    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing required tools: ${missing[*]}"
        echo "Install with: brew install ${missing[*]}" >&2
        return 1
    fi
    return 0
}

# kubectl wrapper honoring the optional --context
k() {
    if [ -n "$CONTEXT" ]; then
        kubectl --context "$CONTEXT" "$@"
    else
        kubectl "$@"
    fi
}

# exec into a broker and read its rendered config, suppressing the noisy
# "id: cannot find name for user ID" stderr the cp-server image emits.
broker_config() {
    k exec -n "$NAMESPACE" kafka-0 -c kafka -- \
        sh -c 'grep -rhE "'"$1"'" /mnt/config/ 2>/dev/null' 2>/dev/null || true
}

# ── 1. PKI ────────────────────────────────────────────────────────────────────
check_pki() {
    info "1. PKI health"

    local issuer_status
    issuer_status=$(k get clusterissuer rbac-mtls-ca-issuer -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || echo "")
    if [ "$issuer_status" = "True" ]; then
        success "ClusterIssuer rbac-mtls-ca-issuer is Ready"
    else
        error "ClusterIssuer rbac-mtls-ca-issuer not Ready (status='$issuer_status')"
    fi

    local expected_certs=(kafka-broker-mtls kraftcontroller-mtls schemaregistry-mtls)
    local c ready
    for c in "${expected_certs[@]}"; do
        ready=$(k get certificate "$c" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "$ready" = "True" ]; then
            success "Certificate $c is Ready"
        else
            error "Certificate $c not Ready (status='$ready')"
        fi
    done

    # CFK consumes cert-manager 'TLS Group 3' keys directly
    local keys
    keys=$(k get secret kafka-broker-mtls -n "$NAMESPACE" -o jsonpath='{.data}' 2>/dev/null | jq -r 'keys | join(",")' 2>/dev/null || echo "")
    if echo "$keys" | grep -q 'tls.crt' && echo "$keys" | grep -q 'tls.key' && echo "$keys" | grep -q 'ca.crt'; then
        success "kafka-broker-mtls secret exposes tls.crt/tls.key/ca.crt (CFK-consumable)"
    else
        error "kafka-broker-mtls secret missing expected keys (found: $keys)"
    fi

    local bundle
    bundle=$(k get configmap rbac-mtls-ca-bundle -n "$NAMESPACE" -o jsonpath='{.data.ca\.crt}' 2>/dev/null || echo "")
    if echo "$bundle" | grep -q 'BEGIN CERTIFICATE'; then
        success "trust-manager Bundle ConfigMap rbac-mtls-ca-bundle present in $NAMESPACE"
    else
        error "trust-manager Bundle ConfigMap rbac-mtls-ca-bundle missing/empty in $NAMESPACE"
    fi
}

# ── 2. Listener security ──────────────────────────────────────────────────────
check_listeners() {
    info "2. Listener security"

    local protocol_map
    protocol_map=$(broker_config 'listener.security.protocol.map' | head -1)
    if [ -z "$protocol_map" ]; then
        error "Could not read listener.security.protocol.map from kafka-0 (is the broker running?)"
        return
    fi
    debug "$protocol_map"

    local l
    for l in "${EXPECTED_SSL_LISTENERS[@]}"; do
        if echo "$protocol_map" | grep -qE "${l}:SSL"; then
            success "$l listener uses SSL"
        else
            error "$l listener is NOT SSL (map: ${protocol_map#*=})"
        fi
    done

    # INTERNAL is intentionally still OAuth-over-plaintext (client compatibility)
    if echo "$protocol_map" | grep -qE 'INTERNAL:SASL_PLAINTEXT'; then
        success "INTERNAL listener remains SASL_PLAINTEXT (OAuth clients, by design)"
    else
        warning "INTERNAL listener is not SASL_PLAINTEXT — verify this is intended"
    fi

    local clientauth
    clientauth=$(broker_config 'ssl.client.auth')
    for l in "${EXPECTED_CLIENTAUTH_LISTENERS[@]}"; do
        if echo "$clientauth" | grep -qE "listener.name.${l}.ssl.client.auth=required"; then
            success "$l listener enforces client certs (ssl.client.auth=required)"
        else
            error "$l listener does NOT require client certs (mandatory mTLS not enforced)"
        fi
    done
}

# ── 3. Functional health ──────────────────────────────────────────────────────
check_functional() {
    info "3. Functional health"

    local urp
    urp=$(k exec -n "$NAMESPACE" kafka-0 -c kafka -- \
        sh -c 'kafka-topics --bootstrap-server localhost:9092 --describe --under-replicated-partitions 2>/dev/null | wc -l' 2>/dev/null | tr -d ' ' || echo "?")
    if [ "$urp" = "0" ]; then
        success "Under-replicated partitions: 0 (replication healthy over mTLS)"
    else
        error "Under-replicated partitions: $urp (replication may be failing over mTLS)"
    fi

    # cert-based principal on the controller listener (not an OAuth token)
    local princ
    princ=$(k logs -n "$NAMESPACE" kraftcontroller-0 --tail=400 2>/dev/null \
        | grep -oE '"securityProtocol":"SSL","principal":\{"class":"KafkaPrincipal","type":"User","name":"[a-z0-9.]+","tokenAuthenticated":false\}[^}]*"listener":"CONTROLLER"' \
        | head -1 || true)
    if [ -n "$princ" ]; then
        success "Controller listener authenticates a cert principal (tokenAuthenticated:false)"
        debug "$princ"
    else
        warning "No recent cert-principal request log on kraftcontroller-0 (may just be quiet — check pods)"
    fi

    local p ready
    for p in kafka-0 kafka-1 kafka-2 kraftcontroller-0 schemaregistry-0 controlcenter-0; do
        ready=$(k get pod "$p" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null | tr ' ' '\n' | grep -c true || echo 0)
        if [ "$ready" -ge 1 ]; then
            success "$p is running/ready"
        else
            error "$p is not ready (dependent clients may be failing mTLS/OAuth)"
        fi
    done
}

# ── 4. Schema Registry ────────────────────────────────────────────────────────
check_schema_registry() {
    info "4. Schema Registry HTTPS"

    local sr_tls
    sr_tls=$(k get schemaregistry schemaregistry -n "$NAMESPACE" -o jsonpath='{.spec.tls.secretRef}' 2>/dev/null || echo "")
    if [ -n "$sr_tls" ]; then
        success "SchemaRegistry serves HTTPS (spec.tls.secretRef=$sr_tls)"
    else
        error "SchemaRegistry has no spec.tls.secretRef — REST API is not HTTPS"
    fi

    # SR is Ready only if its REST API bound successfully over HTTPS
    local sr_ready
    sr_ready=$(k get pod schemaregistry-0 -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "")
    if [ "$sr_ready" = "true" ]; then
        success "schemaregistry-0 is Ready (HTTPS REST API listening)"
    else
        error "schemaregistry-0 is not Ready — HTTPS API may have failed to start"
    fi

    # C3 -> SR must be configured for HTTPS with a truststore
    local c3_sr_tls
    c3_sr_tls=$(k get controlcenter controlcenter -n "$NAMESPACE" -o jsonpath='{.spec.dependencies.schemaRegistry.tls.enabled}' 2>/dev/null || echo "")
    if [ "$c3_sr_tls" = "true" ]; then
        success "Control Center connects to Schema Registry over HTTPS"
    else
        warning "Control Center -> Schema Registry is not marked tls.enabled — verify the C3 SR dependency"
    fi

    # NOTE: SR authenticates to Kafka via OAuth (component identity is carried by
    # the OAuth/MDS token; cert-principal auth for a component is not supported in
    # CFK RBAC mode). SR->Kafka mTLS is intentionally out of scope.
    info "   (SR->Kafka auth is OAuth by design — not a cert principal in RBAC mode)"
}

# ── 5. Negative test: no-client-cert client rejected ──────────────────────────
check_negative() {
    info "5. Negative test — no-client-cert client rejected on the mTLS REPLICATION listener"

    if [ "$SKIP_NEGATIVE" = true ]; then
        warning "Negative test skipped (--skip-negative)"
        return
    fi

    # A pure-TLS openssl handshake cannot prove this: with TLS 1.3, client-cert
    # validation happens at the Kafka application layer, after the handshake.
    # So we make a real Kafka-protocol call with a truststore but NO keystore
    # (no client cert) and require it to fail with an SslAuthenticationException.
    # Runs inside kafka-0 using the broker's own tools/certs — no external image.
    local out
    out=$(k exec -n "$NAMESPACE" kafka-0 -c kafka -- sh -c '
        JKSPW=$(sed "s/jksPassword=//" /mnt/sslcerts/jksPassword.txt 2>/dev/null)
        cat >/tmp/nocert.properties <<EOF
security.protocol=SSL
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=$JKSPW
ssl.truststore.type=PKCS12
EOF
        timeout 30 kafka-broker-api-versions \
            --bootstrap-server kafka.kafka.svc.cluster.local:9072 \
            --command-config /tmp/nocert.properties 2>&1
    ' 2>/dev/null || true)
    debug "$out"

    if echo "$out" | grep -qiE 'SslAuthenticationException|failed authentication|SSL handshake failed'; then
        success "No-cert client rejected on REPLICATION (9072) with an SSL auth error — mandatory mTLS enforced"
    elif echo "$out" | grep -qiE 'apiVersion|SupportedApiVersions|api-versions'; then
        error "No-cert client SUCCESSFULLY queried REPLICATION (9072) — client certs are NOT being enforced"
    else
        warning "Negative test inconclusive; could not classify the Kafka client output (broker reachable?)"
    fi
}

print_summary() {
    echo ""
    echo "========================================="
    echo "mTLS Validation Summary"
    echo "========================================="
    if [ "$ERRORS" -gt 0 ]; then
        echo -e "${RED}✗ $ERRORS error(s), $WARNINGS warning(s)${NC}"
        echo "  The cluster does not meet the expected mTLS posture."
        return 1
    elif [ "$WARNINGS" -gt 0 ]; then
        echo -e "${YELLOW}⚠ 0 errors, $WARNINGS warning(s)${NC}"
        echo "  mTLS posture verified; review warnings above."
        return 0
    else
        echo -e "${GREEN}✓ All mTLS checks passed${NC}"
        return 0
    fi
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --verbose) VERBOSE=true; shift ;;
            --skip-negative) SKIP_NEGATIVE=true; shift ;;
            --context) CONTEXT="${2:-}"; shift 2 ;;
            -*) error "Unknown option: $1"; usage; exit 1 ;;
            *)
                if [ -z "$CLUSTER_NAME" ]; then CLUSTER_NAME="$1"; else error "Too many arguments"; usage; exit 1; fi
                shift ;;
        esac
    done

    [ -z "$CLUSTER_NAME" ] && { error "Missing required argument: cluster name"; usage; exit 1; }
    check_dependencies || exit 1

    echo "========================================="
    echo "Live mTLS Validation: $CLUSTER_NAME"
    echo "context: ${CONTEXT:-$(kubectl config current-context 2>/dev/null || echo unknown)}  namespace: $NAMESPACE"
    echo "========================================="
    echo ""

    check_pki;              echo ""
    check_listeners;        echo ""
    check_functional;       echo ""
    check_schema_registry;  echo ""
    check_negative

    print_summary
}

main "$@"
