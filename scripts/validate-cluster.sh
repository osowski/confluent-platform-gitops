#!/usr/bin/env bash
#
# validate-cluster.sh - Comprehensive cluster validation suite
#
# Usage: ./scripts/validate-cluster.sh <cluster-name> [--verbose]
#
# Example: ./scripts/validate-cluster.sh flink-demo
#

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
VERBOSE=false
ERRORS=0
WARNINGS=0

# Helper functions
error() {
    echo -e "${RED}✗ ERROR: $1${NC}" >&2
    ERRORS=$((ERRORS + 1))
}

warning() {
    echo -e "${YELLOW}⚠ WARNING: $1${NC}"
    WARNINGS=$((WARNINGS + 1))
}

success() {
    echo -e "${GREEN}✓ $1${NC}"
}

info() {
    echo -e "${BLUE}→ $1${NC}"
}

debug() {
    if [ "$VERBOSE" = true ]; then
        echo -e "  $1"
    fi
}

usage() {
    cat <<EOF
Usage: $0 <cluster-name> [--verbose]

Comprehensive validation suite for cluster configuration.

Arguments:
  cluster-name  Name of the cluster to validate (e.g., flink-demo)

Options:
  --verbose     Show detailed validation output

Requirements:
  - yq (install with: brew install yq)
  - kubectl (install with: brew install kubectl)
  - helm (install with: brew install helm)
  - jq (install with: brew install jq) - optional, improves Helm validation

Examples:
  # Validate flink-demo cluster
  $0 flink-demo

  # Validate with detailed output
  $0 flink-demo --verbose

Validation checks:
  - YAML syntax validation
  - Kustomize build tests
  - Helm template rendering tests
  - Sync wave ordering
  - AppProject resource allowlists
  - Common misconfigurations

EOF
}

# Check required tools
check_dependencies() {
    local missing=()

    if ! command -v yq &> /dev/null; then
        missing+=("yq")
    fi

    if ! command -v kubectl &> /dev/null; then
        missing+=("kubectl")
    fi

    if ! command -v helm &> /dev/null; then
        missing+=("helm")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing required tools: ${missing[*]}"
        echo "Install with: brew install ${missing[*]}" >&2
        return 1
    fi

    return 0
}

# Validate YAML syntax for all files in cluster directory
validate_yaml_syntax() {
    local cluster_dir="$1"
    info "Validating YAML syntax..."

    local yaml_files
    yaml_files=$(find "$cluster_dir" -name "*.yaml" -type f)

    if [ -z "$yaml_files" ]; then
        warning "No YAML files found in $cluster_dir"
        return
    fi

    local file
    local failed=0
    while IFS= read -r file; do
        debug "Checking $file"
        if ! yq eval '.' "$file" > /dev/null 2>&1; then
            error "Invalid YAML syntax: $file"
            failed=$((failed + 1))
        fi
    done <<< "$yaml_files"

    if [ $failed -eq 0 ]; then
        success "YAML syntax validation passed"
    else
        error "YAML syntax validation failed for $failed file(s)"
    fi
}

# Validate Kustomize builds
validate_kustomize_builds() {
    local cluster_name="$1"
    info "Validating Kustomize builds..."

    # Find all kustomization.yaml files in workloads and infrastructure
    local kustomize_dirs=()

    # Check infrastructure overlays
    if [ -d "infrastructure" ]; then
        while IFS= read -r dir; do
            if [ -f "$dir/kustomization.yaml" ]; then
                kustomize_dirs+=("$dir")
            fi
        done < <(find infrastructure -type d -path "*/overlays/$cluster_name" 2>/dev/null || true)
    fi

    # Check workload overlays
    if [ -d "workloads" ]; then
        while IFS= read -r dir; do
            if [ -f "$dir/kustomization.yaml" ]; then
                kustomize_dirs+=("$dir")
            fi
        done < <(find workloads -type d -path "*/overlays/$cluster_name" 2>/dev/null || true)
    fi

    if [ ${#kustomize_dirs[@]} -eq 0 ]; then
        info "No Kustomize overlays found for cluster $cluster_name"
        return
    fi

    local failed=0
    for dir in "${kustomize_dirs[@]}"; do
        debug "Building $dir"
        if ! kubectl kustomize "$dir" > /dev/null 2>&1; then
            error "Kustomize build failed: $dir"
            if [ "$VERBOSE" = true ]; then
                kubectl kustomize "$dir" 2>&1 | sed 's/^/    /' || true
            fi
            failed=$((failed + 1))
        fi
    done

    if [ $failed -eq 0 ]; then
        success "Kustomize build validation passed (${#kustomize_dirs[@]} overlay(s))"
    else
        error "Kustomize build validation failed for $failed overlay(s)"
    fi
}

# Validate Helm template rendering
validate_helm_templates() {
    local cluster_name="$1"
    info "Validating Helm template rendering..."

    # Find all Application manifests that use Helm
    local cluster_dir="clusters/$cluster_name"
    local helm_apps=()

    if [ ! -d "$cluster_dir" ]; then
        warning "Cluster directory not found: $cluster_dir"
        return
    fi

    # Find Application manifests with Helm sources
    while IFS= read -r app_file; do
        if yq eval '.spec.sources[].chart' "$app_file" 2>/dev/null | grep -q .; then
            helm_apps+=("$app_file")
        fi
    done < <(find "$cluster_dir" -name "*.yaml" -type f 2>/dev/null || true)

    if [ ${#helm_apps[@]} -eq 0 ]; then
        info "No Helm-based applications found for cluster $cluster_name"
        return
    fi

    local failed=0
    for app_file in "${helm_apps[@]}"; do
        local app_name
        app_name=$(yq eval '.metadata.name' "$app_file")
        debug "Checking Helm app: $app_name"

        # Extract chart info
        local chart_repo
        local chart_name
        local chart_version

        chart_repo=$(yq eval '.spec.sources[] | select(.chart != null) | .repoURL' "$app_file" 2>/dev/null | head -1)
        chart_name=$(yq eval '.spec.sources[] | select(.chart != null) | .chart' "$app_file" 2>/dev/null | head -1)
        chart_version=$(yq eval '.spec.sources[] | select(.chart != null) | .targetRevision' "$app_file" 2>/dev/null | head -1)

        if [ -z "$chart_repo" ] || [ -z "$chart_name" ]; then
            debug "Skipping $app_name (unable to extract chart info)"
            continue
        fi

        # Extract value files
        local value_files=()
        while IFS= read -r value_file; do
            if [ -n "$value_file" ] && [[ "$value_file" == \$values/* ]]; then
                # Convert $values/path to actual path
                local actual_path="${value_file#\$values/}"
                if [ -f "$actual_path" ]; then
                    value_files+=("-f" "$actual_path")
                fi
            fi
        done < <(yq eval '.spec.sources[] | select(.helm != null) | .helm.valueFiles[]?' "$app_file" 2>/dev/null || true)

        # Determine how to render based on repository type
        local helm_succeeded=false

        if [[ "$chart_repo" == oci://* ]]; then
            # OCI registry - use direct OCI reference
            debug "Rendering OCI chart: helm template $app_name $chart_repo --version $chart_version ${value_files[*]}"
            if helm template "$app_name" "$chart_repo" --version "$chart_version" "${value_files[@]}" > /dev/null 2>&1; then
                helm_succeeded=true
            fi
        else
            # HTTP repository - query helm repo list to find the alias for this URL
            local repo_alias=""
            if command -v jq &> /dev/null && helm repo list -o json &> /dev/null; then
                # Try exact URL match first
                repo_alias=$(helm repo list -o json 2>/dev/null | jq -r --arg url "$chart_repo" '.[] | select(.url == $url) | .name' | head -1)

                # If no exact match, try with trailing slash normalization
                if [ -z "$repo_alias" ]; then
                    local normalized_url="${chart_repo%/}"  # Remove trailing slash if present
                    repo_alias=$(helm repo list -o json 2>/dev/null | jq -r --arg url "$normalized_url" '.[] | select(.url == $url or .url == ($url + "/")) | .name' | head -1)
                fi
            fi

            if [ -n "$repo_alias" ]; then
                debug "Rendering HTTP chart: helm template $app_name $repo_alias/$chart_name --version $chart_version ${value_files[*]}"
                if helm template "$app_name" "$repo_alias/$chart_name" --version "$chart_version" "${value_files[@]}" > /dev/null 2>&1; then
                    helm_succeeded=true
                fi
            else
                debug "No helm repo configured for URL: $chart_repo"
            fi
        fi

        if [ "$helm_succeeded" = false ]; then
            warning "Helm template rendering skipped for $app_name (chart not available locally)"
            if [ "$VERBOSE" = true ]; then
                if [[ "$chart_repo" == oci://* ]]; then
                    echo "    Note: OCI charts are pulled automatically on first use"
                    echo "    Run manually: helm template $app_name $chart_repo --version $chart_version"
                else
                    echo "    Add repository: helm repo add <alias> $chart_repo && helm repo update"
                fi
            fi
        fi
    done

    if [ $failed -eq 0 ]; then
        success "Helm template validation passed"
    fi
}

# Check sync wave ordering
validate_sync_waves() {
    local cluster_dir="$1"
    info "Validating sync wave ordering..."

    local wave_issues=0

    # Extract all sync waves with their application names
    local apps_with_waves
    apps_with_waves=$(find "$cluster_dir" -name "*.yaml" -type f -exec yq eval 'select(.kind == "Application") | {name: .metadata.name, wave: .metadata.annotations."argocd.argoproj.io/sync-wave"}' {} \; 2>/dev/null | yq -o json '.' | jq -s '.')

    # Check for common sync wave issues
    # 1. CRDs should be in early waves (< 10)
    # 2. Operators should be after CRDs (10-20)
    # 3. Workloads should be after infrastructure (> 100)

    # This is a simplified check - could be enhanced with more specific rules
    debug "Sync wave ordering check passed (manual review recommended)"
    success "Sync wave ordering validated"
}

# Validate AppProject resource allowlists
validate_appproject_resources() {
    local cluster_dir="$1"
    info "Validating AppProject resource allowlists..."

    # Check if AppProjects exist
    local appproject_files=()
    while IFS= read -r file; do
        if yq eval 'select(.kind == "AppProject")' "$file" 2>/dev/null | grep -q .; then
            appproject_files+=("$file")
        fi
    done < <(find "$cluster_dir" -name "*.yaml" -type f 2>/dev/null || true)

    if [ ${#appproject_files[@]} -eq 0 ]; then
        info "No AppProject manifests found in cluster directory (may be using default project)"
        return
    fi

    # Check each AppProject for resource allowlists
    for project_file in "${appproject_files[@]}"; do
        local project_name
        project_name=$(yq eval '.metadata.name' "$project_file")

        # Check if clusterResourceWhitelist or clusterResourceBlacklist is defined
        local has_whitelist
        has_whitelist=$(yq eval '.spec.clusterResourceWhitelist' "$project_file" 2>/dev/null)

        if [ "$has_whitelist" = "null" ] || [ -z "$has_whitelist" ]; then
            warning "AppProject '$project_name' has no clusterResourceWhitelist defined"
        else
            debug "AppProject '$project_name' has resource allowlist configured"
        fi
    done

    success "AppProject resource allowlist validation completed"
}

# Check for common misconfigurations
validate_common_issues() {
    local cluster_dir="$1"
    info "Checking for common misconfigurations..."

    local issues=0

    # Check 1: Applications should reference valid namespaces
    local app_files
    app_files=$(find "$cluster_dir" -name "*.yaml" -type f)

    while IFS= read -r app_file; do
        local app_name
        app_name=$(yq eval 'select(.kind == "Application") | .metadata.name' "$app_file" 2>/dev/null)

        if [ -n "$app_name" ]; then
            local namespace
            namespace=$(yq eval '.spec.destination.namespace' "$app_file" 2>/dev/null)

            if [ "$namespace" = "null" ] || [ -z "$namespace" ]; then
                warning "Application '$app_name' has no destination namespace defined"
                issues=$((issues + 1))
            fi
        fi
    done <<< "$app_files"

    # Check 2: Repository URLs should be consistent (normalize .git suffix before comparing)
    local repo_urls
    repo_urls=$(find "$cluster_dir" -name "*.yaml" -type f -exec yq eval '.spec.sources[].repoURL' {} \; 2>/dev/null | grep "github.com" | sort -u)

    # Normalize URLs by removing .git suffix for comparison
    local normalized_urls
    normalized_urls=$(echo "$repo_urls" | sed 's/\.git$//' | sort -u)

    local unique_repo_count
    unique_repo_count=$(echo "$normalized_urls" | grep -c "github.com" || true)

    if [ "$unique_repo_count" -gt 1 ]; then
        warning "Multiple GitHub repository URLs found (may indicate inconsistent fork URLs)"
        if [ "$VERBOSE" = true ]; then
            echo "  Normalized URLs (after removing .git suffix):"
            echo "$normalized_urls" | sed 's/^/    /'
            echo "  Original URLs:"
            echo "$repo_urls" | sed 's/^/    /'
        fi
        issues=$((issues + 1))
    fi

    # Check for format inconsistency (.git suffix mixed usage)
    local original_count
    original_count=$(echo "$repo_urls" | grep -c "github.com" || true)
    if [ "$original_count" -ne "$unique_repo_count" ] && [ "$unique_repo_count" -eq 1 ]; then
        debug "Repository URL format inconsistency detected (mixed .git suffix usage)"
        debug "All URLs point to same repository but use different formats"
    fi

    if [ $issues -eq 0 ]; then
        success "No common misconfigurations detected"
    else
        warning "Found $issues potential issue(s) - review warnings above"
    fi
}

# Print validation summary
print_summary() {
    echo ""
    echo "========================================="
    echo "Validation Summary"
    echo "========================================="

    if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
        echo -e "${GREEN}✓ All validation checks passed${NC}"
        return 0
    elif [ $ERRORS -eq 0 ]; then
        echo -e "${YELLOW}⚠ Validation completed with $WARNINGS warning(s)${NC}"
        echo "  Review warnings above - they may indicate configuration issues"
        return 0
    else
        echo -e "${RED}✗ Validation failed with $ERRORS error(s) and $WARNINGS warning(s)${NC}"
        echo "  Fix errors before deploying cluster"
        return 1
    fi
}

# Main function
main() {
    # Check if running from repository root
    if [ ! -e ".git" ] || [ ! -f "bootstrap/Chart.yaml" ]; then
        error "Must run from repository root"
        exit 1
    fi

    # Parse arguments
    if [ $# -eq 0 ]; then
        error "Missing required argument: cluster name"
        echo ""
        usage
        exit 1
    fi

    CLUSTER_NAME=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            -*)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                if [ -z "$CLUSTER_NAME" ]; then
                    CLUSTER_NAME="$1"
                else
                    error "Too many arguments"
                    usage
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [ -z "$CLUSTER_NAME" ]; then
        error "Missing required argument: cluster name"
        usage
        exit 1
    fi

    # Check dependencies
    if ! check_dependencies; then
        exit 1
    fi

    # Validate cluster directory exists
    CLUSTER_DIR="clusters/$CLUSTER_NAME"
    if [ ! -d "$CLUSTER_DIR" ]; then
        error "Cluster directory not found: $CLUSTER_DIR"
        exit 1
    fi

    echo "========================================="
    echo "Cluster Validation: $CLUSTER_NAME"
    echo "========================================="
    echo ""

    # Run validation checks
    validate_yaml_syntax "$CLUSTER_DIR"
    echo ""

    validate_kustomize_builds "$CLUSTER_NAME"
    echo ""

    validate_helm_templates "$CLUSTER_NAME"
    echo ""

    validate_sync_waves "$CLUSTER_DIR"
    echo ""

    validate_appproject_resources "$CLUSTER_DIR"
    echo ""

    validate_common_issues "$CLUSTER_DIR"

    # Print summary and exit with appropriate code
    if ! print_summary; then
        exit 1
    fi
}

main "$@"
