# 3. Release Versioning Strategy

Date: 2026-02-14

## Status

Accepted

## Context

All ArgoCD Application manifests in this repository use `targetRevision: HEAD`, meaning every deployment tracks the latest commit on `main`. This creates several problems:

- **No stable deployment targets**: Users cannot deploy a known-good version while development continues
- **No rollback capability**: There is no way to revert to a previous working state without identifying the exact commit
- **No version communication**: There is no clear way to communicate which set of changes constitutes a "release"

The App of Apps pattern adds complexity because version pinning must happen at two levels:
1. The bootstrap `git.targetRevision` (controls parent Applications)
2. Each child Application manifest's `targetRevision` (controls individual workloads)

Both levels must reference the same revision for a consistent deployment.

### Alternatives Considered

1. **GitHub Releases**: Adds UI and release notes on GitHub
   - Rejected: Unnecessary overhead for this project's scale; tags are sufficient

2. **Long-running version branches** (e.g., `v0.2.x`): Maintain branches per release for hotfixes
   - Rejected: Adds maintenance burden; hotfix strategy deferred to a future decision

3. **ApplicationSets with revision overrides**: Use ArgoCD ApplicationSets to parameterize the revision
   - Rejected: Would require migrating from App of Apps pattern (see [ADR-0001](0001-app-of-apps-pattern.md))

## Decision

We will use **Git tags** for release versioning with the following approach:

### Version scheme
- Semantic Versioning: `v<major>.<minor>.<patch>` (e.g., `v0.2.0`)

### Release mechanism
- **Short-lived release branches**: `release/v<version>` branched from `main`, merged back, then deleted
- **Automated release script** (`scripts/prepare-release.sh`): Pins all `targetRevision` fields and updates the changelog
- **Two-commit workflow**: Separate commits for changelog and version pinning, allowing the pinning commit to be reverted before merge so `main` stays on `HEAD`
- **Tag placement**: The Git tag points to the pinning commit where all `targetRevision` fields reference the tag itself

### Version-pinned deployments
- Users set `targetRevision` in their `clusters/<cluster>/bootstrap.yaml` to a release tag
- At the tagged commit, all child Application manifests also reference that tag
- The entire deployment stack is self-consistently pinned

### What we are NOT doing
- No GitHub Releases (tags only)
- No long-running version branches
- No hotfix branches (deferred to a future decision)

## Consequences

### Positive

- **Stable deployment targets**: Users can deploy any tagged version with confidence
- **Simple rollback**: Change `targetRevision` back to a previous tag
- **Clean main branch**: Version pinning is reverted before merge, so `main` always tracks `HEAD`
- **Automated and repeatable**: The release script eliminates manual errors in version pinning
- **Self-consistent snapshots**: At any tag, all Application manifests reference that same tag

### Negative

- **Two-commit workflow complexity**: The pin-then-revert pattern requires understanding to avoid mistakes
- **No hotfix path** (yet): If a critical fix is needed for an older version, there is no established process
- **Script dependency**: The release process depends on `scripts/prepare-release.sh` working correctly

### Neutral

- **No GitHub Releases**: Users must look at Git tags directly rather than a GitHub Releases page
- **Changelog driven**: Release notes live in `docs/changelog.md` rather than GitHub Release descriptions

## References

- [Release Process Documentation](../docs/release-process.md)
- [GitHub Issue #7](https://github.com/osowski/confluent-platform-gitops/issues/7)
- [ADR-0001: App of Apps Pattern](0001-app-of-apps-pattern.md)
- [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
- [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
