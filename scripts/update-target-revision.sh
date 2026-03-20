#!/usr/bin/env bash
#
# update-target-revision.sh - Update ArgoCD Application target revisions
#
# Usage: ./scripts/update-target-revision.sh <cluster-name> <target-revision> [--dry-run]
#
# Example: ./scripts/update-target-revision.sh flink-demo-rbac feature-102/control-center-oidc-verification
#

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
DEFAULT_REVISION="HEAD"
DRY_RUN=false

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

debug() {
    echo -e "${BLUE}  $1${NC}"
}

usage() {
    cat <<EOF
Usage: $0 <cluster-name> <target-revision> [--dry-run]

Update ArgoCD Application targetRevision fields for a specific cluster.
Useful for testing feature branches before merging to main.

Arguments:
  cluster-name      Name of the cluster to update (e.g., flink-demo-rbac)
  target-revision   Git branch, tag, or commit to target
                    Examples: HEAD, main, feature-102/my-feature, v1.0.0

Options:
  --dry-run         Preview changes without modifying files

Requirements:
  - yq (install with: brew install yq)

Examples:
  # Point all applications to a feature branch
  $0 flink-demo-rbac feature-102/control-center-oidc-verification

  # Reset all applications to main branch
  $0 flink-demo-rbac HEAD

  # Preview changes without applying
  $0 flink-demo-rbac feature-102/my-feature --dry-run

Note: This script updates targetRevision in all Application manifests
for the specified cluster, including bootstrap.yaml and all applications
in infrastructure/ and workloads/ directories.

After updating to a feature branch, remember to revert to HEAD before
merging your PR to main.

EOF
}

# Validate cluster name
validate_cluster() {
    local cluster="$1"

    # Check if cluster directory exists
    if [ ! -d "clusters/$cluster" ]; then
        error "Cluster directory not found: clusters/$cluster"
        echo "Available clusters:" >&2
        find clusters/ -maxdepth 1 -type d ! -name clusters -exec basename {} \; 2>/dev/null | sed 's/^/  /' >&2
        return 1
    fi

    return 0
}

# Find all Application manifest files for a cluster
find_target_files() {
    local cluster="$1"

    find "clusters/$cluster" -type f -name "*.yaml" | sort
}

# Count current targetRevision values
count_revisions() {
    local cluster="$1"
    local files
    files=$(find_target_files "$cluster")

    echo "$files" | xargs grep -c "targetRevision:" 2>/dev/null | awk -F: '{sum+=$2} END {print sum}'
}

# Get unique current targetRevision values
get_current_revisions() {
    local cluster="$1"
    local files
    files=$(find_target_files "$cluster")

    {
        echo "$files" | xargs yq eval '.spec.source.targetRevision // ""' 2>/dev/null
        echo "$files" | xargs yq eval '.spec.source.helm.valuesObject.git.targetRevision // ""' 2>/dev/null
    } | grep -v "^$" | grep -v "^---$" | sort -u
}

# Preview changes
preview_changes() {
    local cluster="$1"
    local new_revision="$2"
    local files
    files=$(find_target_files "$cluster")

    info "Files that will be modified:"
    echo ""

    local file
    while IFS= read -r file; do
        # Check if file has targetRevision field
        if yq eval 'has("spec")' "$file" 2>/dev/null | grep -q "true"; then
            local current_revision
            local current_helm_revision
            current_revision=$(yq eval '.spec.source.targetRevision // ""' "$file" 2>/dev/null | head -1)
            current_helm_revision=$(yq eval '.spec.source.helm.valuesObject.git.targetRevision // ""' "$file" 2>/dev/null)

            local has_changes=false
            local changes=""

            if [ -n "$current_revision" ] && [ "$current_revision" != "$new_revision" ]; then
                has_changes=true
                changes="${changes}spec.source.targetRevision: $current_revision → $new_revision\n"
            fi

            if [ -n "$current_helm_revision" ] && [ "$current_helm_revision" != "$new_revision" ]; then
                has_changes=true
                changes="${changes}    helm.valuesObject.git.targetRevision: $current_helm_revision → $new_revision"
            fi

            if [ "$has_changes" = "true" ]; then
                echo "  $file"
                debug "$changes"
            fi
        fi
    done <<< "$files"
}

# Update targetRevision in files using yq
update_files() {
    local cluster="$1"
    local new_revision="$2"
    local files
    files=$(find_target_files "$cluster")

    local modified_count=0
    local skipped_count=0
    local file

    while IFS= read -r file; do
        # Check if file has spec.source, spec.sources, or helm.valuesObject.git.targetRevision
        local has_source
        local has_sources
        local has_helm_values
        has_source=$(yq eval 'has("spec") and .spec | has("source")' "$file" 2>/dev/null)
        has_sources=$(yq eval 'has("spec") and .spec | has("sources")' "$file" 2>/dev/null)
        has_helm_values=$(yq eval 'has("spec") and .spec | has("source") and .spec.source | has("helm") and .spec.source.helm | has("valuesObject") and .spec.source.helm.valuesObject | has("git")' "$file" 2>/dev/null)

        if [ "$has_source" = "true" ] || [ "$has_sources" = "true" ] || [ "$has_helm_values" = "true" ]; then
            # Get current revision(s)
            local current_revision
            local current_helm_revision
            current_revision=$(yq eval '.spec.source.targetRevision // ""' "$file" 2>/dev/null | head -1)
            current_helm_revision=$(yq eval '.spec.source.helm.valuesObject.git.targetRevision // ""' "$file" 2>/dev/null)

            # Skip if already at target revision for both fields
            local needs_update=false
            if [ -n "$current_revision" ] && [ "$current_revision" != "$new_revision" ]; then
                needs_update=true
            fi
            if [ -n "$current_helm_revision" ] && [ "$current_helm_revision" != "$new_revision" ]; then
                needs_update=true
            fi

            if [ "$needs_update" = "false" ]; then
                skipped_count=$((skipped_count + 1))
                continue
            fi

            if [ "$DRY_RUN" = true ]; then
                debug "Would update: $file"
                if [ -n "$current_revision" ] && [ "$current_revision" != "$new_revision" ]; then
                    debug "  spec.source.targetRevision: $current_revision → $new_revision"
                fi
                if [ -n "$current_helm_revision" ] && [ "$current_helm_revision" != "$new_revision" ]; then
                    debug "  helm.valuesObject.git.targetRevision: $current_helm_revision → $new_revision"
                fi
            else
                # Create backup
                cp "$file" "$file.bak"

                # Update spec.source.targetRevision if present
                if [ "$has_source" = "true" ]; then
                    # Single source Application
                    yq eval ".spec.source.targetRevision = \"${new_revision}\"" -i "$file"
                elif [ "$has_sources" = "true" ]; then
                    # Multi-source Application - update all sources that have targetRevision
                    yq eval "(.spec.sources[] | select(has(\"targetRevision\")).targetRevision) = \"${new_revision}\"" -i "$file"
                fi

                # Update helm.valuesObject.git.targetRevision if present
                if [ "$has_helm_values" = "true" ]; then
                    yq eval ".spec.source.helm.valuesObject.git.targetRevision = \"${new_revision}\"" -i "$file"
                fi

                # Check if yq succeeded
                if [ $? -ne 0 ]; then
                    error "YAML update failed for $file - restoring backup"
                    mv "$file.bak" "$file"
                    return 1
                fi

                # Remove backup on success
                rm "$file.bak"

                modified_count=$((modified_count + 1))
                success "Updated: $file"
            fi
        fi
    done <<< "$files"

    if [ "$DRY_RUN" = false ]; then
        info "Modified $modified_count file(s), skipped $skipped_count file(s) (already at target revision)"
    fi

    return 0
}

# Verify all targetRevisions are updated
verify_update() {
    local cluster="$1"
    local expected_revision="$2"
    local files
    files=$(find_target_files "$cluster")

    local mismatches=0
    local file

    while IFS= read -r file; do
        local current_revision
        local current_helm_revision
        current_revision=$(yq eval '.spec.source.targetRevision // ""' "$file" 2>/dev/null | head -1)
        current_helm_revision=$(yq eval '.spec.source.helm.valuesObject.git.targetRevision // ""' "$file" 2>/dev/null)

        if [ -n "$current_revision" ] && [ "$current_revision" != "$expected_revision" ]; then
            error "Mismatch in $file (spec.source.targetRevision): $current_revision (expected: $expected_revision)"
            mismatches=$((mismatches + 1))
        fi

        if [ -n "$current_helm_revision" ] && [ "$current_helm_revision" != "$expected_revision" ]; then
            error "Mismatch in $file (helm.valuesObject.git.targetRevision): $current_helm_revision (expected: $expected_revision)"
            mismatches=$((mismatches + 1))
        fi
    done <<< "$files"

    if [ $mismatches -gt 0 ]; then
        error "Found $mismatches file(s) with incorrect targetRevision"
        return 1
    fi

    success "Verification passed - all targetRevisions updated to: $expected_revision"
    return 0
}

# Main function
main() {
    # Check if running from repository root
    if [ ! -e ".git" ] || [ ! -d "clusters" ]; then
        error "Must run from repository root"
        exit 1
    fi

    # Check for required tools
    if ! command -v yq &> /dev/null; then
        error "yq is required but not installed"
        echo "Install with: brew install yq" >&2
        exit 1
    fi

    # Parse arguments
    if [ $# -eq 0 ]; then
        error "Missing required arguments"
        echo ""
        usage
        exit 1
    fi

    CLUSTER_NAME=""
    TARGET_REVISION=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --dry-run)
                DRY_RUN=true
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
                elif [ -z "$TARGET_REVISION" ]; then
                    TARGET_REVISION="$1"
                else
                    error "Too many arguments"
                    usage
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Validate required arguments
    if [ -z "$CLUSTER_NAME" ]; then
        error "Missing required argument: cluster-name"
        usage
        exit 1
    fi

    if [ -z "$TARGET_REVISION" ]; then
        error "Missing required argument: target-revision"
        usage
        exit 1
    fi

    # Validate cluster exists
    if ! validate_cluster "$CLUSTER_NAME"; then
        exit 1
    fi

    # Get current state
    CURRENT_REVISIONS=$(get_current_revisions "$CLUSTER_NAME")
    REVISION_COUNT=$(count_revisions "$CLUSTER_NAME")

    echo "========================================="
    echo "ArgoCD Application Target Revision Update"
    echo "========================================="
    echo ""
    echo "Cluster:         $CLUSTER_NAME"
    echo "New Revision:    $TARGET_REVISION"
    echo ""
    echo "Current revisions in use:"
    echo "$CURRENT_REVISIONS" | sed 's/^/  /'
    echo ""
    echo "Found $REVISION_COUNT targetRevision field(s) to update"
    echo ""

    if [ "$REVISION_COUNT" -eq 0 ]; then
        info "No targetRevision fields found in cluster Application manifests"
        exit 0
    fi

    if [ "$DRY_RUN" = true ]; then
        info "DRY RUN MODE - No files will be modified"
        echo ""
    fi

    # Preview changes
    preview_changes "$CLUSTER_NAME" "$TARGET_REVISION"

    if [ "$DRY_RUN" = true ]; then
        echo ""
        info "Dry run complete. No files were modified."
        info "Run without --dry-run to apply changes"
        exit 0
    fi

    # Confirm with user
    echo ""
    read -rp "Proceed with update? [y/N] " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Cancelled"
        exit 0
    fi

    echo ""

    # Update files
    info "Updating files..."
    if ! update_files "$CLUSTER_NAME" "$TARGET_REVISION"; then
        error "Update failed"
        exit 1
    fi

    echo ""

    # Verify update
    info "Verifying update..."
    if ! verify_update "$CLUSTER_NAME" "$TARGET_REVISION"; then
        error "Verification failed"
        exit 1
    fi

    echo ""
    success "Target revisions updated successfully!"
    echo ""

    if [ "$TARGET_REVISION" != "$DEFAULT_REVISION" ]; then
        echo "⚠️  WARNING: Applications are now pointing to: $TARGET_REVISION"
        echo ""
        echo "Remember to revert to HEAD before merging your PR:"
        echo "  $0 $CLUSTER_NAME HEAD"
        echo ""
    fi

    echo "Next steps:"
    echo "  1. Review changes: git diff clusters/$CLUSTER_NAME"
    echo "  2. Stage changes: git add clusters/$CLUSTER_NAME"
    echo "  3. Commit changes: git commit -m 'chore: update targetRevision to $TARGET_REVISION'"
    echo "  4. Push changes: git push origin \$(git branch --show-current)"
    echo "  5. ArgoCD will sync to the new target revision automatically"
}

main "$@"
