# Release Process

This document describes how to create and publish versioned releases for the confluent-platform-gitops repository, and how to deploy specific versions. This serves both as a skill guide for Claude Code automation and as human-readable documentation.

## When to Use This Process

**For Claude Code:** Use this skill when the user requests:
- "Create a release"
- "Tag a new version"
- "Publish version X.Y.Z"
- "Cut a release"
- Any similar release-related request

**For humans:** Follow this process when you're ready to publish a new stable version with all changes merged to `main`.

## Version Scheme

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **Major** (`vX.0.0`): Breaking changes to repository structure, bootstrap pattern, or deployment workflow
- **Minor** (`v0.X.0`): New applications, features, or non-breaking configuration changes
- **Patch** (`v0.0.X`): Bug fixes, documentation corrections, minor configuration tweaks

Versions are tracked as Git tags (e.g., `v0.2.0`). There are no GitHub Releases.

## Why Version Pinning Matters

This repository uses the [App of Apps pattern](../adrs/0001-app-of-apps-pattern.md), which means version pinning operates at three levels:

1. **Bootstrap source level**: Each `clusters/<cluster>/bootstrap.yaml` has a `spec.source.targetRevision` that controls which revision of the bootstrap Helm chart ArgoCD renders
2. **Bootstrap values level**: The `git.targetRevision` value (set in `bootstrap/values.yaml` defaults and overridden per-cluster via `valuesObject` in `bootstrap.yaml`) controls which revision the rendered parent Applications (infrastructure, workloads) use
3. **Child Application level**: Each Application manifest in `clusters/` has its own `targetRevision` field for sources pointing to this repository

All three levels must be pinned for a fully version-locked deployment. The release script handles this automatically — it pins `spec.source.targetRevision` on all Application manifests, injects `git.targetRevision` into the bootstrap `valuesObject`, and updates the `bootstrap/values.yaml` default.

## Creating a Release

### Prerequisites

Before running the release:

1. **All changes merged**: Ensure all changes for the release are merged to `main`
2. **Local `main` up-to-date**: Local `main` branch must be up-to-date with `origin/main`
3. **Clean working tree**: Git working tree must be clean (no uncommitted changes)
   - If there are untracked files: Create a temporary directory and move them aside before starting (see Step 1 in workflow below)
4. **`yq` installed**: [`yq`](https://github.com/mikefarah/yq) is required for structured YAML editing

### Release Workflow

The release process consists of five steps. For most cases, you can skip to "Quick Start" below to run the automated script. For Claude Code automation or manual execution, follow these detailed steps:

#### Step 1: Handle Untracked Files

If there are untracked files in the working directory:

1. Create a temporary directory:
   ```bash
   mkdir -p /tmp/release-stash-v{VERSION}
   ```
2. Move all untracked files to this directory
3. Verify working tree is clean:
   ```bash
   git status --porcelain
   ```

#### Step 2: Determine Version Number

If the version hasn't been specified:

- Check `docs/changelog.md` for the latest released version
- Examine the "Unreleased" section to determine the appropriate version bump
- Suggest the version following [Semantic Versioning](https://semver.org/):
  - **Major** (`vX.0.0`): Breaking changes to repository structure, bootstrap pattern, or deployment workflow
  - **Minor** (`v0.X.0`): New applications, features, or non-breaking configuration changes
  - **Patch** (`v0.0.X`): Bug fixes, documentation corrections, minor configuration tweaks

#### Step 3: Run Release Script

Execute the release automation:

```bash
./scripts/release.sh v{VERSION}
```

The script performs these steps automatically:

1. Validates prerequisites (version format, clean tree, on `main`, tag doesn't exist, remote is current)
2. Creates a `release/v0.2.0` branch from `main`
3. Updates `docs/changelog.md` with a version header and date
4. Pins `targetRevision` to `v0.2.0` in all Application manifests referencing this repository, including `git.targetRevision` in bootstrap `valuesObject`
5. Commits changelog and pinning as separate commits
6. Tags the pinning commit as `v0.2.0`
7. Reverts the pinning commit (restores `HEAD` on branch)
8. Merges the release branch into `main` with `--no-ff`
9. Deletes the release branch
10. Prompts for confirmation before pushing

**Note:** The script will prompt for confirmation before pushing. In non-interactive mode (like Claude Code's Bash tool), this prompt will cause the script to exit before pushing, requiring manual push in Step 4.

#### Step 4: Push to Origin

After the release script completes, manually push the changes:

```bash
git push-external origin main && git push-external origin v{VERSION}
```

**Important:** Always use `git push-external` instead of `git push` for external repositories due to Confluent's Airlock security controls.

#### Step 5: Restore Untracked Files

If files were moved aside in Step 1:

1. Move them back to their original locations
2. Verify with:
   ```bash
   git status
   ```

### Quick Start

For manual execution with interactive prompts:

```bash
./scripts/release.sh v0.2.0
```

This single command executes the entire release workflow (steps 1-10 listed above) and prompts for confirmation before pushing.

### Dry Run

To preview what would happen without making any changes:

```bash
./scripts/release.sh --dry-run v0.2.0
```

This validates prerequisites, runs `prepare-release.sh --verify` to list which files would be modified, and exits.

### Using prepare-release.sh Directly

The `prepare-release.sh` script handles changelog updates and version pinning. It can be used standalone or is called automatically by `release.sh`:

```bash
# Verify mode — list files that would be changed
./scripts/prepare-release.sh --verify v0.2.0

# Direct execution (requires clean working tree, manual git steps after)
./scripts/prepare-release.sh v0.2.0
```

### Example: Complete Release

**User request:** "Create a release for v0.4.0"

**Actions performed:**

1. Check for untracked files, move them aside if present:
   ```bash
   mkdir -p /tmp/release-stash-v0.4.0
   mv docs/release-skill.md rules.md /tmp/release-stash-v0.4.0/
   ```

2. Run the release script:
   ```bash
   ./scripts/release.sh v0.4.0
   ```

3. Push the release:
   ```bash
   git push-external origin main && git push-external origin v0.4.0
   ```

4. Restore untracked files:
   ```bash
   mv /tmp/release-stash-v0.4.0/* .
   git status  # verify files are back
   ```

5. Confirm completion with summary

### Error Recovery

If `release.sh` fails mid-workflow, it prints recovery instructions. Since the push step requires explicit confirmation, all prior steps are local and reversible:

```bash
# Return to main and clean up
git checkout main
git branch -D release/v0.2.0    # delete the release branch
git tag -d v0.2.0               # delete the tag if it was created
```

If you moved untracked files aside in Step 1, restore them:

```bash
mv /tmp/release-stash-v0.2.0/* .
```

No remote changes are made until the push step, so all operations are reversible.

<details>
<summary>What happens under the hood (step-by-step detail)</summary>

| Step | Command | Purpose |
|------|---------|---------|
| 1 | Validation checks | Version format, `yq` installed, clean tree, on `main`, tag doesn't exist, remote up-to-date |
| 2 | `git checkout -b release/v0.2.0 main` | Create release branch |
| 3 | `prepare-release.sh v0.2.0` | Update changelog header; pin `targetRevision` in all cluster manifests, bootstrap `valuesObject`, and `bootstrap/values.yaml` using `yq` |
| 4 | `git add docs/changelog.md && git commit` | Commit changelog separately |
| 5 | `git add -A && git commit` | Commit all version pinning changes |
| 6 | `git tag v0.2.0` | Tag points to the fully-pinned commit |
| 7 | `git revert HEAD --no-edit` | Revert pinning, restoring `targetRevision: HEAD` |
| 8 | `git checkout main && git merge release/v0.2.0 --no-ff` | Merge release into main |
| 9 | `git branch -d release/v0.2.0` | Clean up release branch |
| 10 | `git push origin main --tags` | Push (with confirmation prompt) |

After the merge, `main` contains:
- The changelog update (preserved)
- `targetRevision` values back to `HEAD` (the pin and revert cancel out)

At the `v0.2.0` tag, all `targetRevision` values point to `v0.2.0`, creating a fully self-consistent snapshot.

</details>

## Deploying a Specific Version

### Tracking HEAD (default)

By default, the bootstrap Application in `clusters/<cluster>/bootstrap.yaml` tracks `HEAD`:

```yaml
spec:
  source:
    repoURL: https://github.com/osowski/confluent-platform-gitops.git
    targetRevision: HEAD
    path: bootstrap
    helm:
      valuesObject:
        cluster:
          name: flink-demo
          domain: confluentdemo.local
        git:
          targetRevision: "HEAD"
```

The `spec.source.targetRevision` controls which revision of the bootstrap Helm chart ArgoCD renders. The `git.targetRevision` in `valuesObject` overrides the chart default and flows into the rendered parent Applications (infrastructure, workloads) via `{{ .Values.git.targetRevision }}`. At `HEAD`, all child Application manifests also reference `HEAD`, so the entire stack tracks the latest code.

### Pinning to a release tag

To deploy a known-good version, update both `targetRevision` fields in the bootstrap Application:

```yaml
spec:
  source:
    repoURL: https://github.com/osowski/confluent-platform-gitops.git
    targetRevision: v0.2.0
    path: bootstrap
    helm:
      valuesObject:
        cluster:
          name: flink-demo
          domain: confluentdemo.local
        git:
          targetRevision: "v0.2.0"
```

At that tag, ArgoCD renders the bootstrap chart from the tagged commit. The `git.targetRevision` value ensures the parent Applications create child Applications that all reference `v0.2.0`. The entire deployment stack is pinned.

> **Note:** The release script automatically pins both fields. When pinning manually, ensure both `spec.source.targetRevision` and `valuesObject.git.targetRevision` are set to the same version.

### Upgrading between versions

To upgrade from one version to another:

1. Update both `targetRevision` fields in `clusters/<cluster>/bootstrap.yaml` to the new tag:
   ```yaml
   spec:
     source:
       targetRevision: v0.3.0
       helm:
         valuesObject:
           git:
             targetRevision: "v0.3.0"
   ```

2. Apply the updated manifest:
   ```bash
   kubectl apply -f clusters/<cluster>/bootstrap.yaml
   ```

3. ArgoCD will detect the change and sync all Applications to the new version.

To roll back, set both `targetRevision` values back to the previous tag and re-apply.

### Switching from HEAD to a tagged version

1. Edit `clusters/<cluster>/bootstrap.yaml` and change both `spec.source.targetRevision` and `valuesObject.git.targetRevision` from `HEAD` to `v0.2.0`
2. Commit and push to `main` (or apply directly with `kubectl apply`)
3. ArgoCD syncs the bootstrap, which updates parent Applications to track `v0.2.0`
4. Parent Applications recreate child Applications from the tagged revision

### Switching from a tagged version back to HEAD

1. Edit `clusters/<cluster>/bootstrap.yaml` and change both `spec.source.targetRevision` and `valuesObject.git.targetRevision` back to `HEAD`
2. Commit and push (or apply directly)
3. The cluster resumes tracking the latest code

## Related Documentation

- [Bootstrap Procedure](bootstrap-procedure.md) - How bootstrap deployment works
- [Cluster Onboarding](cluster-onboarding.md) - Setting up a new cluster
- [ADR-0003: Release Versioning Strategy](../adrs/0003-release-versioning-strategy.md) - Architecture decision record
