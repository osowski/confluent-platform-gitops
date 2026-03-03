#!/usr/bin/env bash
#
# update-repo-urls.sh - Update repository URLs after forking
#
# Usage: ./scripts/update-repo-urls.sh <new-repo-url> [--dry-run]
#
# Example: ./scripts/update-repo-urls.sh https://github.com/myorg/confluent-platform-gitops.git
#

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
UPSTREAM_URL="https://github.com/osowski/confluent-platform-gitops.git"
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
Usage: $0 <new-repo-url> [--dry-run]

Update repository URLs in all ArgoCD Application manifests and bootstrap
configuration after forking this repository.

Arguments:
  new-repo-url  The new repository URL (your fork)
                Example: https://github.com/myorg/confluent-platform-gitops.git

Options:
  --dry-run     Preview changes without modifying files

Examples:
  # Update URLs to your fork
  $0 https://github.com/myorg/confluent-platform-gitops.git

  # Preview changes without applying
  $0 https://github.com/myorg/confluent-platform-gitops.git --dry-run

Note: This script only replaces the upstream repository URL:
  $UPSTREAM_URL

External Helm repository URLs (e.g., packages.confluent.io) are not modified.

EOF
}

# Validate repository URL format
validate_url() {
    local url="$1"

    # Check if URL matches expected GitHub HTTPS format
    if ! [[ "$url" =~ ^https://github\.com/[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+\.git$ ]]; then
        error "Invalid repository URL format"
        echo "Expected format: https://github.com/<org>/<repo>.git" >&2
        return 1
    fi

    # Check if it's different from upstream
    if [ "$url" = "$UPSTREAM_URL" ]; then
        error "New URL is the same as upstream URL"
        echo "No changes needed. Already pointing to: $UPSTREAM_URL" >&2
        return 1
    fi

    return 0
}

# Find all files that need updating
find_target_files() {
    # Find all YAML files in clusters/ directory and bootstrap/values.yaml
    {
        find clusters/ -type f -name "*.yaml" 2>/dev/null || true
        echo "bootstrap/values.yaml"
    } | sort
}

# Count occurrences of old URL
count_occurrences() {
    local old_url="$1"
    local files
    files=$(find_target_files)

    # Use grep to count, or return 0 if no matches
    echo "$files" | xargs grep -F "$old_url" 2>/dev/null | wc -l | tr -d ' '
}

# Preview changes
preview_changes() {
    local old_url="$1"
    local new_url="$2"
    local files
    files=$(find_target_files)

    info "Files that will be modified:"
    echo ""

    local file
    while IFS= read -r file; do
        if grep -qF "$old_url" "$file" 2>/dev/null; then
            local count
            count=$(grep -cF "$old_url" "$file" 2>/dev/null || echo "0")
            echo "  $file ($count occurrence(s))"

            # Show context for each match
            debug "Preview of changes:"
            grep -n --color=always -F "$old_url" "$file" | sed 's/^/    /' || true
            echo ""
        fi
    done <<< "$files"
}

# Update URLs in files
update_files() {
    local old_url="$1"
    local new_url="$2"
    local files
    files=$(find_target_files)

    local modified_count=0
    local file

    while IFS= read -r file; do
        if grep -qF "$old_url" "$file" 2>/dev/null; then
            if [ "$DRY_RUN" = true ]; then
                debug "Would update: $file"
            else
                # Create backup
                cp "$file" "$file.bak"

                # Replace URL (using different delimiter to avoid escaping issues)
                sed -i '' "s|${old_url}|${new_url}|g" "$file"

                # Verify the file is still valid YAML
                if ! python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>/dev/null; then
                    error "YAML validation failed for $file - restoring backup"
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
        info "Modified $modified_count file(s)"
    fi

    return 0
}

# Verify no old URLs remain
verify_replacement() {
    local old_url="$1"
    local remaining
    remaining=$(count_occurrences "$old_url")

    if [ "$remaining" -gt 0 ]; then
        error "Found $remaining remaining occurrence(s) of old URL:"
        find_target_files | xargs grep -n --color=always -F "$old_url" 2>/dev/null || true
        return 1
    fi

    success "Verification passed - no old URLs remaining"
    return 0
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
        error "Missing required argument: new repository URL"
        echo ""
        usage
        exit 1
    fi

    NEW_URL=""
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
                if [ -z "$NEW_URL" ]; then
                    NEW_URL="$1"
                else
                    error "Too many arguments"
                    usage
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [ -z "$NEW_URL" ]; then
        error "Missing required argument: new repository URL"
        usage
        exit 1
    fi

    # Validate new URL
    if ! validate_url "$NEW_URL"; then
        exit 1
    fi

    # Count current occurrences
    OCCURRENCE_COUNT=$(count_occurrences "$UPSTREAM_URL")

    echo "========================================="
    echo "Repository URL Update"
    echo "========================================="
    echo ""
    echo "Old URL: $UPSTREAM_URL"
    echo "New URL: $NEW_URL"
    echo ""
    echo "Found $OCCURRENCE_COUNT occurrence(s) to update"
    echo ""

    if [ "$OCCURRENCE_COUNT" -eq 0 ]; then
        info "No occurrences of upstream URL found"
        info "Repository may already be updated or using a different URL"
        exit 0
    fi

    if [ "$DRY_RUN" = true ]; then
        info "DRY RUN MODE - No files will be modified"
        echo ""
    fi

    # Preview changes
    preview_changes "$UPSTREAM_URL" "$NEW_URL"

    if [ "$DRY_RUN" = true ]; then
        echo ""
        info "Dry run complete. No files were modified."
        info "Run without --dry-run to apply changes"
        exit 0
    fi

    # Confirm with user
    echo ""
    echo "This will update $OCCURRENCE_COUNT occurrence(s) in $(find_target_files | wc -l | tr -d ' ') file(s)"
    read -rp "Proceed with update? [y/N] " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Cancelled"
        exit 0
    fi

    echo ""

    # Update files
    info "Updating files..."
    if ! update_files "$UPSTREAM_URL" "$NEW_URL"; then
        error "Update failed"
        exit 1
    fi

    echo ""

    # Verify replacement
    info "Verifying replacement..."
    if ! verify_replacement "$UPSTREAM_URL"; then
        error "Verification failed"
        exit 1
    fi

    echo ""
    success "Repository URLs updated successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Review changes: git status"
    echo "  2. Stage changes: git add clusters/ bootstrap/values.yaml"
    echo "  3. Commit changes: git commit -m 'chore: update repository URLs to fork'"
    echo "  4. Push changes: git push origin \$(git branch --show-current)"
    echo "  5. Deploy to cluster: kubectl apply -f clusters/<cluster>/bootstrap.yaml"
}

main "$@"
