#!/usr/bin/env bash
#
# clone-cluster.sh - Clone an existing cluster configuration with a new name
#
# Usage: ./scripts/clone-cluster.sh <source-cluster> <new-cluster> [new-domain]
#   or:  ./scripts/clone-cluster.sh --help
#
# Example: ./scripts/clone-cluster.sh eks-demo acme-customer
#          ./scripts/clone-cluster.sh eks-demo acme-customer customer.example.com
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

error()   { echo -e "${RED}ERROR: $1${NC}" >&2; }
success() { echo -e "${GREEN}✓ $1${NC}"; }
info()    { echo -e "${YELLOW}→ $1${NC}"; }
audit()   { echo -e "${CYAN}  $1${NC}"; }

usage() {
    cat <<EOF
Usage: $0 <source-cluster> <new-cluster> [new-domain]

Clone an existing cluster configuration with a new name, including all
infrastructure and workload overlays associated with the source cluster.

Arguments:
  source-cluster  Name of the existing cluster to clone (e.g., eks-demo)
  new-cluster     Name for the new cluster (e.g., acme-customer)
  new-domain      Optional: New base domain. Defaults to the source cluster's domain.

Examples:
  $0 eks-demo acme-customer
  $0 eks-demo acme-customer customer.example.com

EOF
}

validate_cluster_name() {
    local name="$1"
    if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]]; then
        error "Cluster name must contain only lowercase letters, numbers, and hyphens"
        error "Must start and end with an alphanumeric character"
        return 1
    fi
    if [ ${#name} -lt 3 ]; then
        error "Cluster name must be at least 3 characters"
        return 1
    fi
    if [ ${#name} -gt 63 ]; then
        error "Cluster name must be less than 63 characters"
        return 1
    fi
    return 0
}

validate_domain() {
    local domain="$1"
    if ! [[ "$domain" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]]; then
        error "Domain must contain only lowercase letters, numbers, hyphens, and dots"
        return 1
    fi
    return 0
}

# Extract domain from an existing cluster's bootstrap.yaml
get_cluster_domain() {
    local cluster_name="$1"
    local bootstrap="clusters/$cluster_name/bootstrap.yaml"
    if [ ! -f "$bootstrap" ]; then
        error "Bootstrap file not found: $bootstrap"
        return 1
    fi
    grep 'domain:' "$bootstrap" | head -1 | awk '{print $2}' | tr -d '"'
}

# Replace all occurrences of a string in a single file (macOS + Linux compatible)
replace_in_file() {
    local file="$1"
    local source="$2"
    local target="$3"
    perl -pi -e "s|\Q${source}\E|${target}|g" "$file"
}

# Replace all occurrences of a string across every file in a directory tree
replace_in_dir() {
    local dir="$1"
    local source="$2"
    local target="$3"
    while IFS= read -r file; do
        if grep -qF "$source" "$file" 2>/dev/null; then
            replace_in_file "$file" "$source" "$target"
        fi
    done < <(find "$dir" -type f)
}

# ── Post-clone audit ──────────────────────────────────────────────────────────
# Scans all cloned files for values that were mechanically renamed but still
# carry source-cluster-specific AWS infrastructure semantics.
print_post_clone_audit() {
    local new_cluster="$1"
    local source_cluster="$2"

    # Build a sorted, deduplicated list of all cloned files
    local file_list
    file_list=$(mktemp)
    find "clusters/$new_cluster" -type f 2>/dev/null >> "$file_list"
    find infrastructure workloads -maxdepth 4 -type f \
        -path "*/overlays/$new_cluster/*" 2>/dev/null >> "$file_list"
    sort -u "$file_list" -o "$file_list"

    # Helper: grep across all cloned files; silently returns empty on no match
    grep_cloned() { grep -lF "$1" $(cat "$file_list") 2>/dev/null || true; }
    grep_cloned_e() { grep -lE "$1" $(cat "$file_list") 2>/dev/null || true; }

    # Helper: print matching lines from a file; safe under pipefail
    show_lines()   {
        local pattern="$1" file="$2"
        local hits
        hits=$(grep -n "$pattern" "$file" 2>/dev/null || true)
        [ -z "$hits" ] && return
        while IFS=: read -r lineno content; do
            content=$(echo "$content" | sed 's/^[[:space:]]*//')
            echo "  │    line $lineno: $content"
        done <<< "$hits"
    }
    show_lines_e() {
        local pattern="$1" file="$2"
        local hits
        hits=$(grep -nE "$pattern" "$file" 2>/dev/null || true)
        [ -z "$hits" ] && return
        while IFS=: read -r lineno content; do
            content=$(echo "$content" | sed 's/^[[:space:]]*//')
            echo "  │    line $lineno: $content"
        done <<< "$hits"
    }
    show_hints() {
        local file="$1"
        local hints
        hints=$(grep 'terraform.*output' "$file" 2>/dev/null | head -3 || true)
        [ -z "$hints" ] && return
        while IFS= read -r hint; do
            hint=$(echo "$hint" | sed 's/^[[:space:]#]*//')
            echo "  │    hint: $hint"
        done <<< "$hints"
    }

    local found_any=0

    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  AUDIT REQUIRED — Infrastructure-Specific Values             ${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo "  The following cloned files contain values that were renamed"
    echo "  from '$source_cluster' but still reference source-cluster"
    echo "  AWS infrastructure. Each must be updated before deploying."

    # ── 1. IAM Role ARNs ─────────────────────────────────────────────────────
    local iam_files
    iam_files=$(grep_cloned 'arn:aws:iam::')
    if [ -n "$iam_files" ]; then
        found_any=1
        echo ""
        echo -e "${YELLOW}  ┌─ IAM Role ARNs${NC}"
        echo "  │  These roles do not exist yet for the new cluster."
        echo "  │  Provision via Terraform and replace the ARN values below."
        echo "  │"
        while IFS= read -r f; do
            echo "  │  $f"
            show_lines 'arn:aws:iam::' "$f"
            show_hints "$f"
        done <<< "$iam_files"
        echo -e "${YELLOW}  └─ → Provision AWS IAM roles for '$new_cluster' before applying${NC}"
    fi

    # ── 2. VPC ID ────────────────────────────────────────────────────────────
    local vpc_files
    vpc_files=$(grep_cloned_e 'vpcId:|vpc-[0-9a-f]{8,}')
    if [ -n "$vpc_files" ]; then
        found_any=1
        echo ""
        echo -e "${YELLOW}  ┌─ VPC ID${NC}"
        echo "  │  References the source cluster's VPC, not the new cluster's."
        echo "  │"
        while IFS= read -r f; do
            echo "  │  $f"
            show_lines_e 'vpcId:|vpc-[0-9a-f]{8,}' "$f"
        done <<< "$vpc_files"
        echo -e "${YELLOW}  └─ → Set to the new cluster's VPC ID${NC}"
    fi

    # ── 3. Route53 Hosted Zone IDs ───────────────────────────────────────────
    local zone_files
    zone_files=$(grep_cloned_e 'hostedZoneID:|hostedZone:')
    if [ -n "$zone_files" ]; then
        found_any=1
        echo ""
        echo -e "${YELLOW}  ┌─ Route53 Hosted Zone ID${NC}"
        echo "  │  Required for ExternalDNS and Let's Encrypt DNS-01 cert issuance."
        echo "  │"
        while IFS= read -r f; do
            echo "  │  $f"
            show_lines_e 'hostedZoneID:|hostedZone:' "$f"
            show_hints "$f"
        done <<< "$zone_files"
        echo -e "${YELLOW}  └─ → Obtain zone ID from Route53 or Terraform DNS outputs if using a different root hosted zone${NC}"
    fi

    # ── 4. AWS Account ID ────────────────────────────────────────────────────
    # Only report standalone account ID references outside of ARN context
    local acct_files
    acct_files=$(grep_cloned_e 'aws_account_id:|account.?id:')
    if [ -n "$acct_files" ]; then
        found_any=1
        echo ""
        echo -e "${YELLOW}  ┌─ AWS Account ID (explicit references)${NC}"
        echo "  │  Note: Account IDs embedded in IAM ARNs are covered above."
        echo "  │"
        while IFS= read -r f; do
            echo "  │  $f"
            show_lines_e 'aws_account_id:|account.?id:' "$f"
        done <<< "$acct_files"
        echo -e "${YELLOW}  └─ → Update to the target AWS account ID${NC}"
    fi

    # ── 5. Keycloak / OAuth Issuer Endpoints ─────────────────────────────────
    # The cluster name in OIDC URLs is renamed, but the Keycloak realm and all
    # downstream token-validation endpoints must be reachable at the new domain.
    local oidc_files
    oidc_files=$(grep_cloned_e 'tokenEndpoint|jwksEndpoint|issuerUrl|oidcEndpoint|openid-connect')
    if [ -n "$oidc_files" ]; then
        found_any=1
        echo ""
        echo -e "${YELLOW}  ┌─ Keycloak / OAuth Issuer Endpoints${NC}"
        echo "  │  Cluster name in URLs was renamed. Verify the Keycloak realm"
        echo "  │  exists and is reachable at the new cluster's domain before"
        echo "  │  deploying Kafka, CMF, or ControlCenter."
        echo "  │"
        while IFS= read -r f; do
            echo "  │  $f"
        done <<< "$oidc_files"
        echo -e "${YELLOW}  └─ → Confirm Keycloak realm and client secrets match this cluster${NC}"
    fi

    # ── 6. Architecture-pinned container images ──────────────────────────────
    # Match lines that set an image or newTag to an arch-suffixed value,
    # e.g. "image: repo/name:v1.2.3-amd64" or "newTag: 1.0-arm64".
    # Restrict to YAML files to avoid false positives in markdown docs.
    local img_files
    img_files=$(grep -rlE '^\s*(image|newTag|newName):\s+\S+-(amd64|arm64|aarch64)' \
        $(cat "$file_list") 2>/dev/null | grep -E '\.ya?ml$' || true)
    if [ -n "$img_files" ]; then
        found_any=1
        echo ""
        echo -e "${YELLOW}  ┌─ Architecture-Specific Container Images${NC}"
        echo "  │  These images are pinned to a specific CPU architecture."
        echo "  │  Verify your new cluster's node architecture matches."
        echo "  │"
        while IFS= read -r f; do
            echo "  │  $f"
            show_lines_e '^\s*(image|newTag|newName):\s+\S+-(amd64|arm64|aarch64)' "$f"
        done <<< "$img_files"
        echo -e "${YELLOW}  └─ → Update image tags if node architecture differs from source cluster${NC}"
    fi

    # ── 7. Plain-text Kubernetes Secrets ─────────────────────────────────────
    # Match only actual Secret manifests (kind: Secret on its own line),
    # not ArgoCD Application files that happen to mention the word.
    local secret_files
    secret_files=$(grep -lE '^kind: Secret' $(cat "$file_list") 2>/dev/null || true)
    if [ -n "$secret_files" ]; then
        found_any=1
        echo ""
        echo -e "${YELLOW}  ┌─ Plain-Text Kubernetes Secrets${NC}"
        echo "  │  These files contain credentials cloned directly from the"
        echo "  │  source cluster. Rotate all secrets before deploying to any"
        echo "  │  non-demo environment."
        echo "  │"
        while IFS= read -r f; do
            echo "  │  $f"
        done <<< "$secret_files"
        echo -e "${YELLOW}  └─ → Rotate credentials; consider migrating to an external secrets manager${NC}"
    fi

    # ── 8. Load balancer cloud annotations ───────────────────────────────────
    local lb_files
    lb_files=$(grep_cloned_e 'cflt_service:|cflt_environment:|service\.beta\.kubernetes\.io/aws')
    if [ -n "$lb_files" ]; then
        found_any=1
        echo ""
        echo -e "${YELLOW}  ┌─ Load Balancer Annotations${NC}"
        echo "  │  Cloud-provider and Confluent infrastructure tags that may"
        echo "  │  be source-cluster-specific."
        echo "  │"
        while IFS= read -r f; do
            echo "  │  $f"
            show_lines_e 'cflt_service:|cflt_environment:|cflt_partition:' "$f"
        done <<< "$lb_files"
        echo -e "${YELLOW}  └─ → Review and update environment/partition tags for the new cluster${NC}"
    fi

    rm -f "$file_list"

    if [ "$found_any" -eq 0 ]; then
        echo ""
        echo "  No infrastructure-specific values detected in cloned files."
    fi

    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
}

main() {
    if [ ! -e ".git" ] || [ ! -f "bootstrap/Chart.yaml" ]; then
        error "Must run from the repository root"
        exit 1
    fi

    if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        usage
        exit 0
    fi

    if [ $# -lt 2 ] || [ $# -gt 3 ]; then
        error "Invalid arguments"
        echo ""
        usage
        exit 1
    fi

    local source_cluster="$1"
    local new_cluster="$2"
    local new_domain="${3:-}"

    # Validate source cluster exists
    if [ ! -d "clusters/$source_cluster" ]; then
        error "Source cluster not found: clusters/$source_cluster"
        exit 1
    fi

    # Validate new cluster name
    if ! validate_cluster_name "$new_cluster"; then
        exit 1
    fi

    # Prevent overwriting an existing cluster
    if [ -d "clusters/$new_cluster" ]; then
        error "Cluster already exists: clusters/$new_cluster"
        exit 1
    fi

    # Resolve source domain from bootstrap.yaml
    local source_domain
    source_domain=$(get_cluster_domain "$source_cluster")
    if [ -z "$source_domain" ]; then
        error "Could not determine domain from clusters/$source_cluster/bootstrap.yaml"
        exit 1
    fi

    # Default to source domain if none supplied
    if [ -z "$new_domain" ]; then
        new_domain="$source_domain"
    else
        if ! validate_domain "$new_domain"; then
            exit 1
        fi
    fi

    info "Source cluster : $source_cluster (domain: $source_domain)"
    info "Target cluster : $new_cluster (domain: $new_domain)"
    echo ""

    # ── Step 1: Clone the cluster directory ───────────────────────────────────
    info "Copying cluster configuration..."
    cp -r "clusters/$source_cluster" "clusters/$new_cluster"

    replace_in_dir "clusters/$new_cluster" "$source_cluster" "$new_cluster"
    if [ "$source_domain" != "$new_domain" ]; then
        replace_in_dir "clusters/$new_cluster" "$source_domain" "$new_domain"
    fi
    success "Created clusters/$new_cluster/"

    # ── Step 2: Clone every overlay that exists for the source cluster ────────
    info "Copying overlays..."
    local overlay_count=0

    while IFS= read -r overlay_dir; do
        local new_overlay_dir="${overlay_dir%/"$source_cluster"}/$new_cluster"

        if [ -d "$new_overlay_dir" ]; then
            info "Overlay already exists, skipping: $new_overlay_dir"
            continue
        fi

        cp -r "$overlay_dir" "$new_overlay_dir"
        replace_in_dir "$new_overlay_dir" "$source_cluster" "$new_cluster"
        if [ "$source_domain" != "$new_domain" ]; then
            replace_in_dir "$new_overlay_dir" "$source_domain" "$new_domain"
        fi
        success "Created $new_overlay_dir/"
        overlay_count=$((overlay_count + 1))
    done < <(find infrastructure workloads -maxdepth 3 -type d \
                -path "*/overlays/$source_cluster" 2>/dev/null | sort)

    echo ""
    success "Cluster '$new_cluster' cloned from '$source_cluster'!"
    echo ""
    echo "Cloned:"
    echo "  - clusters/$new_cluster/"
    echo "  - $overlay_count overlay director$([ "$overlay_count" -eq 1 ] && echo y || echo ies)"

    # ── Step 3: Audit report ──────────────────────────────────────────────────
    print_post_clone_audit "$new_cluster" "$source_cluster"

    echo "Next steps:"
    echo "  1. Address all AUDIT REQUIRED items listed above"
    echo "  2. Review clusters/$new_cluster/ and remove any applications you don't need:"
    echo "       clusters/$new_cluster/infrastructure/kustomization.yaml"
    echo "       clusters/$new_cluster/workloads/kustomization.yaml"
    echo "  3. Commit and push:"
    echo "       git add clusters/$new_cluster/"
    echo "       git add infrastructure/ workloads/"
    echo "       git commit -m 'Add $new_cluster cluster (cloned from $source_cluster)'"
    echo "  4. Deploy bootstrap: kubectl apply -f clusters/$new_cluster/bootstrap.yaml"
    echo ""
}

main "$@"
