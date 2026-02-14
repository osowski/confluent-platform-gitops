#!/usr/bin/env bash
#
# prepare-release.sh - Prepare a release by pinning targetRevision in all
# ArgoCD Application manifests that reference this repository.
#
# Usage: ./scripts/prepare-release.sh <version>
# Example: ./scripts/prepare-release.sh v0.2.0
#
# This script:
#   1. Validates the version format, clean working tree, and release branch
#   2. Updates docs/changelog.md with the new version header
#   3. Pins targetRevision to the version tag in all Application manifests
#      that reference this repository (clusters/ and bootstrap/values.yaml)
#   4. Prints a summary and next-step instructions
#
# See docs/release-process.md for the full release workflow.

set -euo pipefail

# --- Configuration ---
REPO_URL_PATTERN="confluent-platform-gitops"

# --- Helpers ---
die() {
  echo "ERROR: $*" >&2
  exit 1
}

# --- Input validation ---
[[ $# -eq 1 ]] || die "Usage: $0 <version>  (e.g., v0.2.0)"

VERSION="$1"

[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "Version must match v<major>.<minor>.<patch> (e.g., v0.2.0)"

# --- Repository state validation ---
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "Not inside a Git repository"

[[ -z "$(git status --porcelain)" ]] \
  || die "Git working tree is not clean. Commit or stash changes first."

BRANCH="$(git branch --show-current)"
[[ "$BRANCH" =~ ^release/ ]] \
  || die "Must be on a release/* branch (current: $BRANCH)"

# Check that the tag does not already exist
if git rev-parse "$VERSION" >/dev/null 2>&1; then
  die "Tag $VERSION already exists"
fi

# --- Step 1: Update changelog ---
CHANGELOG="$REPO_ROOT/docs/changelog.md"

if [[ ! -f "$CHANGELOG" ]]; then
  die "Changelog not found at $CHANGELOG"
fi

TODAY="$(date +%Y-%m-%d)"
BARE_VERSION="${VERSION#v}"  # e.g., "0.2.0" from "v0.2.0"

# Insert new version header after ## [Unreleased]
if ! grep -q '## \[Unreleased\]' "$CHANGELOG"; then
  die "Changelog is missing '## [Unreleased]' header"
fi

sed -i "s/^## \[Unreleased\]/## [Unreleased]\n\n## [$BARE_VERSION] - $TODAY/" "$CHANGELOG"

# Add version comparison link at bottom of file
# Find the [Unreleased] link and update it, then add the new version link
sed -i "s|\[Unreleased\]: \(.*\)/compare/\(.*\)\.\.\.HEAD|[Unreleased]: \1/compare/$VERSION...HEAD\n[$BARE_VERSION]: \1/compare/\2...$VERSION|" "$CHANGELOG"

echo "Updated changelog: $CHANGELOG"
echo "  Added version header: ## [$BARE_VERSION] - $TODAY"

# --- Step 2: Pin targetRevision in cluster Application manifests ---
echo ""
echo "Pinning targetRevision to $VERSION in cluster Application manifests..."

CLUSTER_FILES_CHANGED=0
while IFS= read -r -d '' file; do
  # Check if this file has a repoURL matching our repo followed by targetRevision: HEAD
  if sed -n "/${REPO_URL_PATTERN}/{n;/targetRevision: HEAD/p;}" "$file" | grep -q .; then
    sed -i "/${REPO_URL_PATTERN}/{n;s/targetRevision: HEAD/targetRevision: ${VERSION}/;}" "$file"
    echo "  Pinned: $file"
    CLUSTER_FILES_CHANGED=$((CLUSTER_FILES_CHANGED + 1))
  fi
done < <(find "$REPO_ROOT/clusters" -name "*.yaml" -not -name "kustomization.yaml" -not -name "kind-config.yaml" -print0)

echo "  $CLUSTER_FILES_CHANGED cluster files updated"

# --- Step 3: Pin bootstrap default ---
echo ""
echo "Pinning targetRevision in bootstrap/values.yaml..."

BOOTSTRAP_VALUES="$REPO_ROOT/bootstrap/values.yaml"

if [[ ! -f "$BOOTSTRAP_VALUES" ]]; then
  die "bootstrap/values.yaml not found at $BOOTSTRAP_VALUES"
fi

if sed -n "/${REPO_URL_PATTERN}/{n;/targetRevision: \"HEAD\"/p;}" "$BOOTSTRAP_VALUES" | grep -q .; then
  sed -i "/${REPO_URL_PATTERN}/{n;s/targetRevision: \"HEAD\"/targetRevision: \"${VERSION}\"/;}" "$BOOTSTRAP_VALUES"
  echo "  Pinned: $BOOTSTRAP_VALUES"
else
  echo "  WARNING: No targetRevision: \"HEAD\" found after $REPO_URL_PATTERN in bootstrap/values.yaml"
fi

# --- Summary ---
TOTAL_CHANGES=$((CLUSTER_FILES_CHANGED + 1))  # +1 for bootstrap/values.yaml
echo ""
echo "========================================="
echo "  Release preparation complete: $VERSION"
echo "========================================="
echo ""
echo "Files changed:"
echo "  - docs/changelog.md (version header added)"
echo "  - $CLUSTER_FILES_CHANGED cluster Application manifests (targetRevision pinned)"
echo "  - bootstrap/values.yaml (targetRevision pinned)"
echo "  Total targetRevision updates: $TOTAL_CHANGES"
echo ""
echo "Next steps:"
echo "  1. Review the changes:  git diff"
echo "  2. Commit changelog:    git add docs/changelog.md && git commit -m 'Update changelog for $VERSION'"
echo "  3. Commit pinning:      git add -A && git commit -m 'Pin targetRevision to $VERSION'"
echo "  4. Tag the release:     git tag $VERSION"
echo "  5. Revert pinning:      git revert HEAD --no-edit"
echo "  6. Merge to main:       git checkout main && git merge $BRANCH"
echo "  7. Delete branch:       git branch -d $BRANCH"
echo "  8. Push:                git push origin main --tags"
