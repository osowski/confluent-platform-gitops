# Release Process

This document describes how to create versioned releases and how users deploy specific versions.

## Version Scheme

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **Major** (`vX.0.0`): Breaking changes to repository structure, bootstrap pattern, or deployment workflow
- **Minor** (`v0.X.0`): New applications, features, or non-breaking configuration changes
- **Patch** (`v0.0.X`): Bug fixes, documentation corrections, minor configuration tweaks

Versions are tracked as Git tags (e.g., `v0.2.0`). There are no GitHub Releases.

## Why Version Pinning Matters

This repository uses the [App of Apps pattern](../adrs/0001-app-of-apps-pattern.md), which means version pinning operates at two levels:

1. **Bootstrap level**: The `bootstrap/values.yaml` `git.targetRevision` controls which revision the parent Applications (infrastructure, workloads) use
2. **Child Application level**: Each Application manifest in `clusters/` has its own `targetRevision` field for sources pointing to this repository

Both levels must be pinned for a fully version-locked deployment. The release script handles this automatically.

## Creating a Release

### Prerequisites

- Clean Git working tree (no uncommitted changes)
- All changes for the release already merged to `main`

### Step-by-Step Workflow

#### 1. Create a release branch

```bash
git checkout -b release/v0.2.0 main
```

#### 2. Run the release preparation script

```bash
./scripts/prepare-release.sh v0.2.0
```

The script will:
- Validate the version format, clean working tree, and branch name
- Update `docs/changelog.md` with a new version header and date
- Pin `targetRevision` to `v0.2.0` in all cluster Application manifests that reference this repository
- Pin `targetRevision` in `bootstrap/values.yaml`
- Print a summary of changes and next steps

#### 3. Commit the changelog update

```bash
git add docs/changelog.md
git commit -m "Update changelog for v0.2.0"
```

#### 4. Commit the version pinning

```bash
git add -A
git commit -m "Pin targetRevision to v0.2.0"
```

#### 5. Tag the release

```bash
git tag v0.2.0
```

The tag points to the commit where all `targetRevision` fields are pinned to `v0.2.0`.

#### 6. Revert the version pinning

```bash
git revert HEAD --no-edit
```

This reverts only the pinning commit (step 4), restoring `targetRevision` back to `HEAD` on the branch. The changelog update (step 3) is preserved.

#### 7. Merge to main and clean up

```bash
git checkout main
git merge release/v0.2.0
git branch -d release/v0.2.0
git push origin main --tags
```

### What happens after the merge

On `main`, the merge result contains:
- The changelog update (preserved)
- `targetRevision` values back to `HEAD` (the pin and revert cancel out)

At the `v0.2.0` tag, all `targetRevision` values point to `v0.2.0`, creating a fully self-consistent snapshot.

## Deploying a Specific Version

### Tracking HEAD (default)

By default, the bootstrap Application in `clusters/<cluster>/bootstrap.yaml` tracks `HEAD`:

```yaml
spec:
  source:
    repoURL: https://github.com/osowski/confluent-platform-gitops.git
    targetRevision: HEAD
    path: bootstrap
```

This means the cluster always deploys the latest commit on `main`. At `HEAD`, all child Application manifests also reference `HEAD`, so the entire stack tracks the latest code.

### Pinning to a release tag

To deploy a known-good version, update the bootstrap Application's `targetRevision` to a release tag:

```yaml
spec:
  source:
    repoURL: https://github.com/osowski/confluent-platform-gitops.git
    targetRevision: v0.2.0
    path: bootstrap
```

At that tag, the bootstrap chart's `git.targetRevision` is also set to `v0.2.0`, so the parent Applications will create child Applications that all reference `v0.2.0`. The entire deployment stack is pinned.

### Upgrading between versions

To upgrade from one version to another:

1. Update `targetRevision` in `clusters/<cluster>/bootstrap.yaml` to the new tag:
   ```yaml
   targetRevision: v0.3.0
   ```

2. Apply the updated manifest:
   ```bash
   kubectl apply -f clusters/<cluster>/bootstrap.yaml
   ```

3. ArgoCD will detect the change and sync all Applications to the new version.

To roll back, set `targetRevision` back to the previous tag and re-apply.

### Switching from HEAD to a tagged version

1. Edit `clusters/<cluster>/bootstrap.yaml` and change `targetRevision: HEAD` to `targetRevision: v0.2.0`
2. Commit and push to `main` (or apply directly with `kubectl apply`)
3. ArgoCD syncs the bootstrap, which updates parent Applications to track `v0.2.0`
4. Parent Applications recreate child Applications from the tagged revision

### Switching from a tagged version back to HEAD

1. Edit `clusters/<cluster>/bootstrap.yaml` and change `targetRevision: v0.2.0` to `targetRevision: HEAD`
2. Commit and push (or apply directly)
3. The cluster resumes tracking the latest code

## Related Documentation

- [Bootstrap Procedure](bootstrap-procedure.md) - How bootstrap deployment works
- [Cluster Onboarding](cluster-onboarding.md) - Setting up a new cluster
- [ADR-0003: Release Versioning Strategy](../adrs/0003-release-versioning-strategy.md) - Architecture decision record
