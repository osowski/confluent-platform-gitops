# CLAUDE.md — Project Context & Workflow

## Project Overview

This file exists to **onboard Claude into this codebase** at the start of every session. Only essential, universal context is included here.

- **Name:** Confluent Platform GitOps Automation
- **Purpose:** Automate the management of Confluent Platform deployments on Kubernetes clusters using GitOps practices.
- **Tech stack:** Argo CD, Kustomize, Helm, Kubernetes, Confluent for Kubernetes (CFK), Confluent Manager for Apache Flink (CMF)

## How Claude Should Work in This Project
Before doing work, Claude should follow this **standard workflow**:

### 1) Explore & Plan
- Investigate the relevant area of the codebase.
- Ask clarifying questions before writing or modifying code.
- Construct a short plan with steps before coding anything.
- **Review the [Code Review Checklist](./docs/code_review_checklist.md) during planning** to anticipate common issues.

### 2) Code with Verification
- Implement minimal, necessary changes to solve the task.
- Ensure changes have associated tests.
- Run tests and validation checks locally or via CLI commands as specified in `/docs/testing.md`.
- **Apply security and defensive programming practices** from the checklist.

### 3) Pre-PR Review
- **MANDATORY: Review [Code Review Checklist](./docs/code_review_checklist.md) before creating PR**
- Verify all documentation in `/docs` has been updated (architecture.md, project_spec.md, changelog.md)
- Ensure PR description is accurate and includes explicit GitHub issue link
- Confirm branch naming follows `feature-<id>/` or `fix-<id>/` format

### 4) Commit & Document
- Write a commit message that clearly states intent and outcome.
- Update any reference docs if you add new relevant context or conventions.

## Documentation

Refer to these documentation files for details. Claude may read them as needed:

- [Project Spec](./docs/project_spec.md) - Full requirements, scope, and technical details
- [Architecture](./docs/architecture.md) - System design and data flow
- [Changelog](./docs/changelog.md) - Version history
   - TODO needs more detail/attention
- [Code Review Checklist](./docs/code_review_checklist.md) - **MANDATORY checklist before creating PRs**
- [Architecture Decision Records](./adrs/) - Sub-directory containing all architecture decision records

### Documentation Maintenance Principles

**Avoid Duplication - Use Cross-References:**
- Each piece of information should live in ONE authoritative location
- When related information exists in multiple docs, use cross-references instead of duplicating content
- Link to the canonical source with clear context about what the reader will find
- Example: "For detailed bootstrap procedures, see [Bootstrap Procedure](bootstrap-procedure.md)"

**Clear Document Boundaries:**
- **adding-applications.md** - How to add individual applications to existing clusters
- **bootstrap-procedure.md** - Bootstrap deployment and operations on existing ArgoCD installations
- **cluster-onboarding.md** - Complete new cluster setup (references the above for specific steps)
- **architecture.md** - System design and patterns (canonical source for architectural decisions)

**When Updating Documentation:**
1. Identify the canonical location for each piece of information
2. Remove duplicate content from other files
3. Replace duplicates with cross-references to the canonical source
4. Ensure "Next Steps" sections provide clear navigation between related docs

## Constraints and Policies

These rules apply *in every session*:

### Progressive Disclosure Policy
Only load task-specific docs when needed. This file is intentionally concise — do not dump entire workflows here; instead, link to the named doc files above.

### Universal Work Rules

- Ask for clarification if requirements are unclear.
- Avoid doing anything that requires guessing missing context.
- If you need more context, ask for the relevant doc to read.
- Optimize for long-term maintainability over short-term ingenuity.
- Log architecture decision records in the `./adrs/` sub-directory when an architecture decision has been made that could impact future feature implementation, evolution, or refactoring.
   - Follow guidance and formatting from https://adr.github.io/ for structure of ADRs.

### Security - MUST FOLLOW

Security rules are detailed in the [Code Review Checklist](./docs/code_review_checklist.md) and [confluent-platform-gitops security guidelines](https://github.com/osowski/confluent-platform-gitops/blob/main/docs/guides/code-review-checklist.md). Key principles:

- NEVER expose API keys or tokens
- ALWAYS manage secrets externally (not committed to this repository)
- NEVER commit `.env.local` or credential files
- NEVER store Kubernetes Secrets in plain text in manifests

### Code Quality

- Apply defensive programming practices (see [Code Review Checklist](./docs/code_review_checklist.md))
- Ensure idempotency - manifests must be safe to re-apply
- Validate YAML syntax and Kustomize/Helm rendering before committing
- Verify sync wave ordering for deployment dependencies

### Dependencies

- Minimize external dependencies where it makes sense
- Always ask me before importing any new external dependencies

## Repository Etiquette

### Branching
- Always create a feature branch before starting major changes
- A branch should always be associated with a GitHub Issue
- Never commit directly to `main`
- Branch names should be in the format of `feature-<github-issue-id>/<description>` or `fix-<github-issue-id>/<description>`

### Git workflow for major changes
1. Create a new branch: `git checkout -b feature-<github-issue-id>/<feature-name>`
2. Develop and commit on the feature branch
3. **MANDATORY: Update relevant documentation in `/docs`** (see checklist for which files)
4. **MANDATORY: Review [Code Review Checklist](./docs/code_review_checklist.md)** before creating PR
5. Push the branch: `git push -u origin feature-<github-issue-id>/<feature-name>`
6. Create a PR to merge into `main`

### Commits
- Write clear commit messages describing the changes
- Keep commits focused on single changes.
- Avoid bleeding multiple streams of changes into a single commit.

### Pull Requests
- Create PRs for all changes to `main`
- NEVER force push to `main`
- PR description must accurately reflect implementation
- Include description of WHAT changed and WHY
- Include explicit markdown link to GitHub Issue
- **MANDATORY: Review [Code Review Checklist](./docs/code_review_checklist.md)** before creating PR

### GitHub Issues

Project status is tracked through GitHub Issues.
- Issues labeled `prd` should be referenced as top-level product requirment documents
  - Issues of this type should only be created by myself.
- Issues labeled `enhancement` or `feature` should be used for tracking feature implementations, based on PRD analysis.
   - Issues of this type can be created by Claude or myself.
- Issues labeled `manual` should be ignored by Claude, as these are only meant for human interaction.

Interaction with GitHub Issues locally can be performed via the GitHub CLI.
