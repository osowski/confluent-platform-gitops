#!/usr/bin/env bash
#
# release.sh - End-to-end release orchestrator for confluent-platform-gitops.
#
# Automates the full release workflow: branch creation, changelog update,
# version pinning, tagging, revert, merge, and push.
#
# Usage: ./scripts/release.sh [--dry-run] <version>
# Example: ./scripts/release.sh v0.2.0
#         ./scripts/release.sh --dry-run v0.2.0
#
# Flags:
#   --dry-run  Run prepare-release.sh --verify and print what would happen
#              without making any changes.
#
# See docs/release-process.md for details.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Helpers ---
die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo ">>> $*"
}

step() {
  echo ""
  echo "=== Step $1: $2 ==="
}

print_recovery() {
  local version="$1"
  local branch="release/$version"
  echo ""
  echo "========================================="
  echo "  Release failed — recovery instructions"
  echo "========================================="
  echo ""
  echo "Current state: you may be on branch '$branch'."
  echo ""
  echo "To recover:"
  echo "  git checkout main"
  echo "  git branch -D $branch    # delete the release branch"
  echo "  git tag -d $version      # delete the tag if it was created"
  echo ""
  echo "No remote changes were made (push had not occurred)."
}

# --- Parse flags ---
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -*)
      die "Unknown flag: $1"
      ;;
    *)
      break
      ;;
  esac
done

# --- Input validation ---
[[ $# -eq 1 ]] || die "Usage: $0 [--dry-run] <version>  (e.g., v0.2.0)"

VERSION="$1"

[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "Version must match v<major>.<minor>.<patch> (e.g., v0.2.0)"

# --- Prerequisite checks ---
step 1 "Validate prerequisites"

command -v yq >/dev/null 2>&1 \
  || die "yq is required but not installed. See https://github.com/mikefarah/yq"

command -v git >/dev/null 2>&1 \
  || die "git is required but not installed"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "Not inside a Git repository"

# Verify clean working tree
[[ -z "$(git status --porcelain)" ]] \
  || die "Git working tree is not clean. Commit or stash changes first."

# Verify on main branch
CURRENT_BRANCH="$(git branch --show-current)"
[[ "$CURRENT_BRANCH" = "main" ]] \
  || die "Must be on 'main' branch (current: $CURRENT_BRANCH)"

# Verify tag does not exist
if git rev-parse "$VERSION" >/dev/null 2>&1; then
  die "Tag $VERSION already exists"
fi

# Verify remote is reachable and main is up-to-date
info "Fetching from origin..."
git fetch origin main --quiet 2>/dev/null \
  || die "Could not fetch from origin. Check your network connection."

LOCAL_HEAD="$(git rev-parse main)"
REMOTE_HEAD="$(git rev-parse origin/main)"
[[ "$LOCAL_HEAD" = "$REMOTE_HEAD" ]] \
  || die "Local main ($LOCAL_HEAD) is not up-to-date with origin/main ($REMOTE_HEAD). Run 'git pull' first."

info "All prerequisites passed"

# --- Dry-run mode ---
if [[ "$DRY_RUN" = true ]]; then
  echo ""
  echo "=== Dry-run mode: no changes will be made ==="
  echo ""
  echo "Would perform the following steps for $VERSION:"
  echo "  1. Create branch: release/$VERSION"
  echo "  2. Run prepare-release.sh to update changelog and pin versions"
  echo "  3. Commit changelog update"
  echo "  4. Commit version pinning"
  echo "  5. Tag: $VERSION"
  echo "  6. Revert pinning commit"
  echo "  7. Merge release/$VERSION into main (--no-ff)"
  echo "  8. Delete branch: release/$VERSION"
  echo "  9. Push main and tags to origin"
  echo ""
  echo "--- prepare-release.sh --verify output ---"
  echo ""
  "$SCRIPT_DIR/prepare-release.sh" --verify "$VERSION"
  exit 0
fi

# --- Set trap for error recovery ---
RELEASE_BRANCH="release/$VERSION"
trap 'print_recovery "$VERSION"' ERR

# --- Step 2: Create release branch ---
step 2 "Create release branch"
git checkout -b "$RELEASE_BRANCH" main
info "Created branch: $RELEASE_BRANCH"

# --- Step 3: Run prepare-release.sh ---
step 3 "Run prepare-release.sh"
"$SCRIPT_DIR/prepare-release.sh" "$VERSION"

# --- Step 4: Commit changelog ---
step 4 "Commit changelog update"
git add docs/changelog.md
git commit -m "Update changelog for $VERSION"
info "Committed changelog update"

# --- Step 5: Commit version pinning ---
step 5 "Commit version pinning"
git add -A
git commit -m "Pin targetRevision to $VERSION"
info "Committed version pinning"

# --- Step 6: Tag the pinning commit ---
step 6 "Tag release"
git tag "$VERSION"
info "Created tag: $VERSION"

# --- Step 7: Revert pinning commit ---
step 7 "Revert version pinning"
git revert HEAD --no-edit
info "Reverted pinning commit (targetRevision back to HEAD)"

# --- Step 8: Merge to main ---
step 8 "Merge to main"
git checkout main
git merge "$RELEASE_BRANCH" --no-ff -m "Merge release $VERSION into main"
info "Merged $RELEASE_BRANCH into main"

# --- Step 9: Delete release branch ---
step 9 "Clean up release branch"
git branch -d "$RELEASE_BRANCH"
info "Deleted branch: $RELEASE_BRANCH"

# --- Step 10: Push ---
step 10 "Push to origin"

echo ""
echo "Ready to push the following to origin:"
echo "  - main branch (with release commits)"
echo "  - Tag: $VERSION"
echo ""
read -r -p "Push to origin? [y/N] " confirm
case "$confirm" in
  [yY]|[yY][eE][sS])
    git push-external origin main --tags
    info "Pushed main and tags to origin"
    ;;
  *)
    echo ""
    echo "Push skipped. To push manually:"
    echo "  git push-external origin main --tags"
    exit 0
    ;;
esac

# --- Done ---
# Clear ERR trap on success
trap - ERR

echo ""
echo "========================================="
echo "  Release $VERSION complete!"
echo "========================================="
echo ""
echo "Summary:"
echo "  - Tag $VERSION points to the fully-pinned commit"
echo "  - main branch has changelog update and reverted pinning"
echo "  - All changes pushed to origin"
