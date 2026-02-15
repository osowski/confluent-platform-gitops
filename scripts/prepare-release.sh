#!/usr/bin/env bash
#
# prepare-release.sh - Prepare a release by pinning targetRevision in all
# ArgoCD Application manifests that reference this repository.
#
# Usage: ./scripts/prepare-release.sh [--verify] <version>
# Example: ./scripts/prepare-release.sh v0.2.0
#         ./scripts/prepare-release.sh --verify v0.2.0
#
# This script:
#   1. Validates the version format and clean working tree
#   2. Updates docs/changelog.md with the new version header
#   3. Pins targetRevision to the version tag in all Application manifests
#      that reference this repository (clusters/ and bootstrap/values.yaml)
#   4. Prints a summary of changes
#
# Flags:
#   --verify  Dry-run mode: scan manifests and report which files would be
#             changed without modifying anything.
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

# --- Parse flags ---
VERIFY_MODE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify)
      VERIFY_MODE=true
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
[[ $# -eq 1 ]] || die "Usage: $0 [--verify] <version>  (e.g., v0.2.0)"

VERSION="$1"
export VERSION

[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "Version must match v<major>.<minor>.<patch> (e.g., v0.2.0)"

# --- Prerequisite checks ---
command -v yq >/dev/null 2>&1 \
  || die "yq is required but not installed. See https://github.com/mikefarah/yq"

# --- Repository state validation ---
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "Not inside a Git repository"

if [[ "$VERIFY_MODE" = false ]]; then
  [[ -z "$(git status --porcelain)" ]] \
    || die "Git working tree is not clean. Commit or stash changes first."
fi

# Check that the tag does not already exist
if git rev-parse "$VERSION" >/dev/null 2>&1; then
  die "Tag $VERSION already exists"
fi

# --- Verify mode header ---
if [[ "$VERIFY_MODE" = true ]]; then
  echo "=== Verify mode: no files will be modified ==="
  echo ""
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

if [[ "$VERIFY_MODE" = true ]]; then
  echo "Would update: $CHANGELOG"
  echo "  Add version header: ## [$BARE_VERSION] - $TODAY"
else
  sed -i "s/^## \[Unreleased\]/## [Unreleased]\n\n## [$BARE_VERSION] - $TODAY/" "$CHANGELOG"

  # Add version comparison link at bottom of file
  # Find the [Unreleased] link and update it, then add the new version link
  sed -i "s|\[Unreleased\]: \(.*\)/compare/\(.*\)\.\.\.HEAD|[Unreleased]: \1/compare/$VERSION...HEAD\n[$BARE_VERSION]: \1/compare/\2...$VERSION|" "$CHANGELOG"

  echo "Updated changelog: $CHANGELOG"
  echo "  Added version header: ## [$BARE_VERSION] - $TODAY"
fi

# --- Step 2: Pin targetRevision in cluster Application manifests ---
echo ""
echo "Pinning targetRevision to $VERSION in cluster Application manifests..."

CLUSTER_FILES_CHANGED=0
while IFS= read -r -d '' file; do
  changed=false

  # Check for single-source Applications (spec.source)
  if yq -e '.spec.source | select(.repoURL | test("'"$REPO_URL_PATTERN"'"))' "$file" >/dev/null 2>&1; then
    current=$(yq '.spec.source.targetRevision' "$file")
    if [[ "$current" = "HEAD" ]]; then
      if [[ "$VERIFY_MODE" = true ]]; then
        echo "  Would pin (single-source): $file"
      else
        yq -i '(.spec.source | select(.repoURL | test("'"$REPO_URL_PATTERN"'"))).targetRevision = env(VERSION)' "$file"
        echo "  Pinned (single-source): $file"
      fi
      changed=true

      # Bootstrap Applications (path: bootstrap) need git.targetRevision in valuesObject
      # so the rendered parent Applications use the pinned version
      source_path=$(yq '.spec.source.path' "$file")
      if [[ "$source_path" = "bootstrap" ]]; then
        if [[ "$VERIFY_MODE" = true ]]; then
          echo "  Would pin (bootstrap valuesObject): $file"
        else
          yq -i '.spec.source.helm.valuesObject.git.targetRevision = env(VERSION)' "$file"
          echo "  Pinned (bootstrap valuesObject): $file"
        fi
      fi
    fi
  fi

  # Check for multi-source Applications (spec.sources[])
  if yq -e '.spec.sources[] | select(.repoURL | test("'"$REPO_URL_PATTERN"'"))' "$file" >/dev/null 2>&1; then
    # Only pin sources that currently target HEAD
    matching_head=$(yq '.spec.sources[] | select(.repoURL | test("'"$REPO_URL_PATTERN"'")) | select(.targetRevision == "HEAD") | .repoURL' "$file" 2>/dev/null || true)
    if [[ -n "$matching_head" ]]; then
      if [[ "$VERIFY_MODE" = true ]]; then
        echo "  Would pin (multi-source): $file"
      else
        yq -i '(.spec.sources[] | select(.repoURL | test("'"$REPO_URL_PATTERN"'")) | select(.targetRevision == "HEAD")).targetRevision = env(VERSION)' "$file"
        echo "  Pinned (multi-source): $file"
      fi
      changed=true
    fi
  fi

  if [[ "$changed" = true ]]; then
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

CURRENT_BOOTSTRAP=$(yq '.git.targetRevision' "$BOOTSTRAP_VALUES")
if [[ "$CURRENT_BOOTSTRAP" = "HEAD" ]]; then
  if [[ "$VERIFY_MODE" = true ]]; then
    echo "  Would pin: $BOOTSTRAP_VALUES"
  else
    yq -i '.git.targetRevision = env(VERSION)' "$BOOTSTRAP_VALUES"
    echo "  Pinned: $BOOTSTRAP_VALUES"
  fi
else
  echo "  WARNING: git.targetRevision is not \"HEAD\" in bootstrap/values.yaml (current: $CURRENT_BOOTSTRAP)"
fi

# --- Summary ---
TOTAL_CHANGES=$((CLUSTER_FILES_CHANGED + 1))  # +1 for bootstrap/values.yaml
echo ""
echo "========================================="
if [[ "$VERIFY_MODE" = true ]]; then
  echo "  Verify complete: $VERSION"
else
  echo "  Release preparation complete: $VERSION"
fi
echo "========================================="
echo ""
echo "Files changed:"
echo "  - docs/changelog.md (version header added)"
echo "  - $CLUSTER_FILES_CHANGED cluster Application manifests (targetRevision pinned)"
echo "  - bootstrap/values.yaml (targetRevision pinned)"
echo "  Total targetRevision updates: $TOTAL_CHANGES"

if [[ "$VERIFY_MODE" = false ]]; then
  echo ""
  echo "Next steps:"
  echo "  1. Review the changes:  git diff"
  echo "  2. Commit changelog:    git add docs/changelog.md && git commit -m 'Update changelog for $VERSION'"
  echo "  3. Commit pinning:      git add -A && git commit -m 'Pin targetRevision to $VERSION'"
  echo "  4. Tag the release:     git tag $VERSION"
  echo "  5. Revert pinning:      git revert HEAD --no-edit"
  echo "  6. Merge to main:       git checkout main && git merge <release-branch>"
  echo "  7. Delete branch:       git branch -d <release-branch>"
  echo "  8. Push:                git push origin main --tags"
fi
