#!/usr/bin/env bash
#
# new-cluster.sh - Scaffold new cluster directory structure
#
# Usage: ./scripts/new-cluster.sh <cluster-name> <domain>
#   or: ./scripts/new-cluster.sh (interactive mode)
#
# Example: ./scripts/new-cluster.sh prod-us-east kafka.example.com
#

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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

usage() {
    cat <<EOF
Usage: $0 <cluster-name> <domain>
   or: $0 (interactive mode)

Scaffold a new cluster directory structure for GitOps deployment.

Arguments:
  cluster-name  Name of the cluster (e.g., prod-us-east, staging, dev)
  domain        Base domain for the cluster (e.g., kafka.example.com)

Example:
  $0 prod-us-east kafka.example.com

EOF
}

# Validate cluster name
validate_cluster_name() {
    local name="$1"

    # Check format (alphanumeric, hyphens only)
    if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]]; then
        error "Cluster name must contain only lowercase letters, numbers, and hyphens"
        error "Must start and end with alphanumeric character"
        return 1
    fi

    # Check length
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

# Validate domain
validate_domain() {
    local domain="$1"

    # Basic domain format check
    if ! [[ "$domain" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]]; then
        error "Domain must contain only lowercase letters, numbers, hyphens, and dots"
        return 1
    fi

    return 0
}

# Check if cluster already exists
check_cluster_exists() {
    local cluster_name="$1"
    local cluster_dir="clusters/$cluster_name"

    if [ -d "$cluster_dir" ]; then
        error "Cluster directory already exists: $cluster_dir"
        return 1
    fi

    return 0
}

# Get repository URL from git config
get_repo_url() {
    local url
    url=$(git config --get remote.origin.url 2>/dev/null || echo "")

    if [ -z "$url" ]; then
        # Default to upstream if no origin
        echo "https://github.com/osowski/confluent-platform-gitops.git"
    else
        # Convert SSH URL to HTTPS if needed
        if [[ "$url" =~ ^git@github.com:(.+)\.git$ ]]; then
            echo "https://github.com/${BASH_REMATCH[1]}.git"
        else
            echo "$url"
        fi
    fi
}

# Replace template placeholders in a file using envsubst
replace_placeholders() {
    local file="$1"
    local cluster_name="$2"
    local domain="$3"
    local repo_url="$4"

    # Validate inputs
    if [ ! -f "$file" ]; then
        error "File not found: $file"
        return 1
    fi

    # Use envsubst to replace placeholders
    # Create temp file, replace placeholders, then move to original
    local temp_file="${file}.tmp"
    CLUSTER_NAME="$cluster_name" DOMAIN="$domain" REPO_URL="$repo_url" \
        envsubst < "$file" > "$temp_file"
    mv "$temp_file" "$file"
}

# Create cluster files from templates
create_from_templates() {
    local cluster_name="$1"
    local domain="$2"
    local repo_url="$3"
    local template_dir="templates/new-cluster"
    local target_dir="clusters/$cluster_name"

    # Check template directory exists
    if [ ! -d "$template_dir" ]; then
        error "Template directory not found: $template_dir"
        return 1
    fi

    # Copy bootstrap.yaml template
    cp "$template_dir/bootstrap.yaml.template" "$target_dir/bootstrap.yaml"
    replace_placeholders "$target_dir/bootstrap.yaml" "$cluster_name" "$domain" "$repo_url"
    success "Created $target_dir/bootstrap.yaml"

    # Copy all infrastructure application templates
    local infra_count=0
    for template in "$template_dir/infrastructure"/*.yaml.template; do
        if [ -f "$template" ]; then
            local basename=$(basename "$template" .template)
            cp "$template" "$target_dir/infrastructure/$basename"
            # Only replace placeholders in files that need it (Application manifests)
            if grep -q '\$CLUSTER_NAME\|\$DOMAIN\|\$REPO_URL' "$target_dir/infrastructure/$basename"; then
                replace_placeholders "$target_dir/infrastructure/$basename" "$cluster_name" "$domain" "$repo_url"
            fi
            infra_count=$((infra_count + 1))
        fi
    done
    success "Created $infra_count infrastructure applications"

    # Copy infrastructure kustomization template
    cp "$template_dir/infrastructure/kustomization.yaml.template" "$target_dir/infrastructure/kustomization.yaml"

    # Copy all workload application templates
    local workload_count=0
    for template in "$template_dir/workloads"/*.yaml.template; do
        if [ -f "$template" ]; then
            local basename=$(basename "$template" .template)
            cp "$template" "$target_dir/workloads/$basename"
            # Only replace placeholders in files that need it
            if grep -q '\$CLUSTER_NAME\|\$DOMAIN\|\$REPO_URL' "$target_dir/workloads/$basename"; then
                replace_placeholders "$target_dir/workloads/$basename" "$cluster_name" "$domain" "$repo_url"
            fi
            workload_count=$((workload_count + 1))
        fi
    done
    success "Created $workload_count workload applications"

    # Copy workloads kustomization template
    cp "$template_dir/workloads/kustomization.yaml.template" "$target_dir/workloads/kustomization.yaml"

    # Scaffold infrastructure ingresses overlay stub
    local infra_ingresses_dir="infrastructure/ingresses/overlays/$cluster_name"
    mkdir -p "$infra_ingresses_dir"
    cat > "$infra_ingresses_dir/kustomization.yaml" <<EOF
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

patches:
  - path: argocd-ingressroute-patch.yaml
    target:
      kind: IngressRoute
      name: argocd-server

  - path: argocd-certificate-patch.yaml
    target:
      kind: Certificate
      name: argocd-server-tls

# Cluster-specific labels
labels:
- includeSelectors: false
  includeTemplates: true
  pairs:
    cluster: $cluster_name
EOF
    cat > "$infra_ingresses_dir/argocd-ingressroute-patch.yaml" <<EOF
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-server
  namespace: argocd
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(\`argocd.$cluster_name.$domain\`)
      kind: Rule
      services:
        - name: argocd-server
          port: 443
          scheme: https
          serversTransport: argocd-server-insecure-transport
  tls:
    secretName: argocd-server-tls
EOF
    cat > "$infra_ingresses_dir/argocd-certificate-patch.yaml" <<EOF
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-server-tls
  namespace: argocd
spec:
  dnsNames:
    - argocd.$cluster_name.$domain
EOF
    success "Created $infra_ingresses_dir/ (argocd patches for $cluster_name.$domain)"

    # Scaffold workload ingresses overlay stub
    local workload_ingresses_dir="workloads/ingresses/overlays/$cluster_name"
    mkdir -p "$workload_ingresses_dir"
    cat > "$workload_ingresses_dir/kustomization.yaml" <<EOF
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

patches:
  - path: cmf-ingressroute-patch.yaml
    target:
      kind: IngressRoute
      name: cmf

  - path: controlcenter-ingressroute-patch.yaml
    target:
      kind: IngressRoute
      name: controlcenter

  - path: controlcenter-certificate-patch.yaml
    target:
      kind: Certificate
      name: controlcenter-tls

  - path: schema-registry-ingressroute-patch.yaml
    target:
      kind: IngressRoute
      name: schema-registry

# Cluster-specific labels
labels:
- includeSelectors: false
  includeTemplates: true
  pairs:
    cluster: $cluster_name
EOF
    cat > "$workload_ingresses_dir/cmf-ingressroute-patch.yaml" <<EOF
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: cmf
  namespace: operator
spec:
  routes:
    - match: Host(\`cmf.$cluster_name.$domain\`)
      kind: Rule
      services:
        - name: cmf-service
          port: 80
          scheme: http
EOF
    cat > "$workload_ingresses_dir/controlcenter-ingressroute-patch.yaml" <<EOF
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: controlcenter
  namespace: kafka
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(\`controlcenter.$cluster_name.$domain\`)
      kind: Rule
      services:
        - name: controlcenter
          port: 9021
          scheme: http
  tls:
    secretName: controlcenter-tls
EOF
    cat > "$workload_ingresses_dir/controlcenter-certificate-patch.yaml" <<EOF
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: controlcenter-tls
  namespace: kafka
spec:
  dnsNames:
    - controlcenter.$cluster_name.$domain
EOF
    cat > "$workload_ingresses_dir/schema-registry-ingressroute-patch.yaml" <<EOF
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: schema-registry
  namespace: kafka
spec:
  routes:
    - kind: Rule
      match: Host(\`schema-registry.$cluster_name.$domain\`)
      services:
        - name: schemaregistry
          port: 8081
          scheme: http
EOF
    success "Created $workload_ingresses_dir/ (cmf, controlcenter, schema-registry patches for $cluster_name.$domain)"

    # Copy README template
    cp "$template_dir/README.md.template" "$target_dir/README.md"
    replace_placeholders "$target_dir/README.md" "$cluster_name" "$domain" "$repo_url"
    success "Created $target_dir/README.md"
}

# Interactive mode
interactive_mode() {
    echo "=== New Cluster Setup (Interactive Mode) ==="
    echo ""

    # Get cluster name
    while true; do
        read -rp "Enter cluster name (e.g., prod-us-east): " cluster_name
        if [ -z "$cluster_name" ]; then
            error "Cluster name cannot be empty"
            continue
        fi
        if validate_cluster_name "$cluster_name"; then
            if check_cluster_exists "$cluster_name"; then
                break
            fi
        fi
    done

    # Get domain
    while true; do
        read -rp "Enter domain (e.g., kafka.example.com): " domain
        if [ -z "$domain" ]; then
            error "Domain cannot be empty"
            continue
        fi
        if validate_domain "$domain"; then
            break
        fi
    done

    echo ""
    echo "Summary:"
    echo "  Cluster Name: $cluster_name"
    echo "  Domain:       $domain"
    echo ""
    read -rp "Create cluster? [y/N] " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Cancelled"
        exit 0
    fi

    CLUSTER_NAME="$cluster_name"
    DOMAIN="$domain"
}

# Main function
main() {
    # Check if running from repository root (handles both normal repos and worktrees)
    if [ ! -e ".git" ] || [ ! -f "bootstrap/Chart.yaml" ]; then
        error "Must run from repository root"
        exit 1
    fi

    # Parse arguments or run interactive mode
    if [ $# -eq 0 ]; then
        interactive_mode
    elif [ $# -eq 2 ]; then
        CLUSTER_NAME="$1"
        DOMAIN="$2"

        # Validate inputs
        if ! validate_cluster_name "$CLUSTER_NAME"; then
            exit 1
        fi

        if ! validate_domain "$DOMAIN"; then
            exit 1
        fi

        if ! check_cluster_exists "$CLUSTER_NAME"; then
            exit 1
        fi
    elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        usage
        exit 0
    else
        error "Invalid arguments"
        echo ""
        usage
        exit 1
    fi

    # Get repository URL
    REPO_URL=$(get_repo_url)

    info "Creating cluster directory structure for: $CLUSTER_NAME"
    info "Domain: $DOMAIN"
    info "Repository: $REPO_URL"
    echo ""

    # Create directories
    mkdir -p "clusters/$CLUSTER_NAME/infrastructure"
    mkdir -p "clusters/$CLUSTER_NAME/workloads"
    success "Created directories"

    # Create files from templates
    if ! create_from_templates "$CLUSTER_NAME" "$DOMAIN" "$REPO_URL"; then
        error "Failed to create files from templates"
        exit 1
    fi

    echo ""
    success "Cluster $CLUSTER_NAME created successfully!"
    echo ""
    echo "Generated cluster with full application stack:"
    echo "  - Bootstrap configuration"
    echo "  - 14 infrastructure applications (ingress, monitoring, secrets, TLS, storage)"
    echo "  - 8 workload applications (Confluent Platform, Flink, observability)"
    echo ""
    echo "Next steps:"
    echo "  1. Review generated files in clusters/$CLUSTER_NAME/"
    echo "  2. Remove any applications you don't need from:"
    echo "     - clusters/$CLUSTER_NAME/infrastructure/kustomization.yaml"
    echo "     - clusters/$CLUSTER_NAME/workloads/kustomization.yaml"
    echo "  3. Create cluster-specific overlays as needed (see clusters/$CLUSTER_NAME/README.md)"
    echo "     - Required: Ingress overlays (argocd, vault, controlcenter)"
    echo "     - Required: MinIO overlay (infrastructure/minio/overlays/$CLUSTER_NAME/)"
    echo "     - Required: Populate ingress overlay stubs:"
    echo "         infrastructure/ingresses/overlays/\$CLUSTER_NAME/ (ArgoCD, Vault, etc.)"
    echo "         workloads/ingresses/overlays/\$CLUSTER_NAME/ (CMF, ControlCenter, etc.)"
    echo "     - Optional: Environment-specific settings (traefik, metrics-server)"
    echo "  4. Commit changes: git add clusters/$CLUSTER_NAME/ && git commit -m 'Add $CLUSTER_NAME cluster'"
    echo "  5. Deploy bootstrap: kubectl apply -f clusters/$CLUSTER_NAME/bootstrap.yaml"
    echo ""
    echo "Note: All applications from flink-demo cluster are included by default."
    echo "      It's easier to remove what you don't need than to add from scratch."
    echo ""
    echo "For detailed guidance, see:"
    echo "  - docs/cluster-onboarding.md"
    echo "  - docs/adoption-guide.md"
}

main "$@"
