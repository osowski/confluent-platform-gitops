---
name: cp-flink-validation
description: Use specifically for testing or validating Confluent Platform (CP) Flink stacks deployed by this repository (confluent-platform-gitops) — not general-purpose testing of unrelated systems. Triggers on requests like "test that this Flink SQL job aggregates correctly," "validate my CMF Helm change took effect," "check that this FlinkApplication comes up healthy." Runs a conversational interview to define the CP Flink test case, then executes it via either a GitOps flow (fork, branch, ArgoCD sync) or a Manual flow (direct kubectl/CFK/CMF-REST), as the user chooses.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
metadata:
  version: "0.1.0"
  maturity: team
---

# CP Flink Validation

Conversationally define and run a test case against a CP Flink stack deployed
by **this repository**. The user describes what they want validated in plain
language; this skill interviews them to pin down specifics, generates the
needed manifests, executes the test through one of two explicit paths, and
reports PASS/FAIL with evidence.

This skill is **repo-scoped** — it depends on this repo's own scripts
(`scripts/update-target-revision.sh`, `scripts/update-repo-urls.sh`) and
cluster layout (`clusters/flink-demo/`). It only works inside a checkout of
this repository or a fork of it. It is not portable to other projects the way
a personal skill would be.

## When to use

- "Test that this Flink SQL job produces the right output"
- "Validate my CMF/Flink Helm chart change actually took effect"
- "Check that this FlinkApplication comes up healthy under these resource limits"
- "I want to run some test cases against the flink-demo cluster"

**Not for:** deploying real, permanent workloads (use the normal `workloads/`
convention and `docs/adding-applications.md` for that) or anything on a
cluster other than `flink-demo` — see [Scope](#scope-v1) below.

## Scope (v1)

- **Cluster:** `flink-demo` only (plaintext/anonymous auth). Do not attempt
  this against `flink-demo-rbac`, `flink-demo-rbac-mtls`, or `eks-demo` —
  those need OAuth/mTLS credential plumbing this skill doesn't have yet. If
  the user asks for one of those, say so plainly and stop rather than
  improvising credentials.
- **No automated teardown.** Every run ends with the exact manual teardown
  commands. Never delete test resources without being asked.
- **No CI integration.** This is an interactive, conversational flow.
- **Test cases are generated fresh each conversation** — there is no fixed
  catalog of canned tests to pick from.

## Test cases are not one shape

Resist the pull to assume every test case is "deploy a Flink job, check its
output." Real test cases in this repo's history include Flink SQL data-flow
validation, CMF Helm-chart config verification (did a resource limit or
`mdsRestConfig` setting actually apply?), and plain health/smoke checks. A
test case is **setup + one or more assertions**, and setup can be empty (a
test that only inspects already-deployed state needs no new resources at
all). Read [references/test-case-schema.md](references/test-case-schema.md)
before generating anything — it defines the four assertion kinds
(`health`, `data-flow`, `resource-state`, `rest-response`) and shows that
they compose freely in one test case.

## Step 1: Environment preamble (once per environment)

Skip this whole step if already satisfied — check before doing anything:

```bash
git remote get-url origin                       # compare to upstream below
grep -rF "https://github.com/osowski/confluent-platform-gitops.git" clusters/ bootstrap/values.yaml
```

Upstream URL: `https://github.com/osowski/confluent-platform-gitops.git`. If
`origin` already points elsewhere **and** the grep finds nothing, the fork is
already set up — go to Step 2.

Otherwise, walk the user through:

1. **Fork on GitHub** if they don't have one yet: `gh repo fork
   osowski/confluent-platform-gitops --clone=false` (or the GitHub UI).
2. **Point local git at the fork** — repoint `origin`, or have them clone
   fresh from the fork and reopen the skill there.
3. **Run the URL-rewrite script**:
   ```bash
   ./scripts/update-repo-urls.sh <fork-url>
   git add clusters/ bootstrap/values.yaml
   git commit -m "chore: update repository URLs to fork"
   git push origin main
   ```
4. **Bootstrap `flink-demo`** from the fork if it isn't already running —
   follow `docs/bootstrap-procedure.md` in full; don't summarize it from
   memory, read it.

Do not proceed to the interview until this is confirmed complete.

## Step 2: The interview

Ask, one topic at a time (don't dump every question at once):

1. **What is being validated?** Get them to describe it in their own words
   first, then classify it against the assertion kinds in
   [references/test-case-schema.md](references/test-case-schema.md) —
   health-only, data-flow, resource-state, REST-response, or some
   combination. Don't force it into "deploy + check output" if that's not
   what they described.
2. **What setup does this need, if any?** A brand-new FlinkApplication/JAR? A
   Flink SQL statement (default to a `FlinkStatement` CR)? Topics/schemas?
   Or nothing new — just asserting against state that's already deployed?
3. **For each assertion**, get the concrete expected value/condition — exact
   SQL text or JAR URI, exact input messages and exact expected output, the
   exact `kubectl` field to check and what it should read, or the exact REST
   endpoint and expected response shape.
4. **Execution mode: GitOps or Manual?** State the trade-off briefly and let
   them choose — don't default silently:
   - *GitOps* exercises the real fork→branch→sync adoption path but is
     slower (branch, retarget, wait for ArgoCD).
   - *Manual* applies directly via `kubectl`/CFK CRs (or CMF REST, only when
     they say they prefer it or a CR can't express what's needed) — faster
     iteration, but bypasses git/ArgoCD entirely for the test's own
     resources. Requires the base `flink-demo` platform already at `HEAD`.

From the answers, derive `<test-name>` (see
[references/naming-rules.md](references/naming-rules.md) — validate it
**immediately**, before generating anything else) and write
`tests/<test-name>/test-case.yaml` following the schema reference. This file
is the record of the interview, not something the user hand-writes.

## Step 3: Generate resources

Using `test-case.yaml` as the source of truth, generate whatever
`setup.resources` calls for — real manifests, following this repo's existing
shapes. Don't invent new conventions; match what's already here:

- **Topics** → `KafkaTopic` CR, shaped like
  `workloads/flink-secure-sql-mtls/base/topics.yaml`.
- **Flink SQL** → `FlinkStatement` CR, shaped like
  `workloads/flink-secure-sql-mtls/base/flink-statement.yaml`.
- **FlinkApplication (JAR)** → shaped like
  `workloads/colors-and-shapes/base/flink-application-colors.yaml`.
- **Config/Helm-value assertions with no new resource** → generate nothing
  here; the assertion checks existing state in Step 5.

Read the referenced example file before generating its analog — don't
generate from memory of the shape above.

Where everything lands depends on the mode chosen in Step 2:

### If GitOps mode

1. **Branch:** `test/<test-name>-<timestamp>` (e.g.
   `test/orders-aggregation-20260917143000`). This is **explicitly exempt**
   from this repo's `feature-<issue>/`/`fix-<issue>/` GitHub Issue
   requirement — it's a throwaway validation run, not deliverable feature
   work. The `test/` prefix keeps it visually distinct; don't use
   `feature-`/`fix-` for these.
   ```bash
   git checkout -b test/<test-name>-<timestamp>
   ```
2. **Place resources** in `tests/<test-name>/` with its own
   `kustomization.yaml` listing everything generated. Exception: if the test
   case's setup is a Helm-values change to an *existing* chart (e.g. CMF),
   generate that overlay/patch in the normal
   `workloads/<app>/overlays/flink-demo/` location instead — it's
   cluster-scoped configuration, not a new standalone resource, and
   `tests/` isn't the place for it.
3. **Wire it in:** add `clusters/flink-demo/workloads/test-<test-name>.yaml`
   — an ArgoCD `Application` with `path: tests/<test-name>`, same shape as
   `clusters/flink-demo/workloads/flink-resources.yaml` (read that file for
   the exact fields: `project: workloads`, `destination.namespace: flink`,
   sync-wave annotation, automated sync/prune/selfHeal). Add the new
   filename to `clusters/flink-demo/workloads/kustomization.yaml`'s
   `resources:` list.
4. **Commit and push** the branch.
5. **Retarget the cluster:**
   ```bash
   ./scripts/update-target-revision.sh flink-demo test/<test-name>-<timestamp> --yes
   git commit -am "chore: point flink-demo at test/<test-name>-<timestamp> for live testing"
   git push
   ```
   This is the existing "Live-Testing an Unmerged Branch on a Cluster"
   procedure — read `docs/bootstrap-procedure.md`'s section of that name if
   any step here is unclear; don't improvise around it.
6. **Apply bootstrap twice:**
   ```bash
   kubectl apply -f clusters/flink-demo/bootstrap.yaml
   kubectl apply -f clusters/flink-demo/bootstrap.yaml   # confirm this one reports "configured"
   ```
7. **Poll** the new Application until `sync=Synced health=Healthy`:
   ```bash
   kubectl get application test-<test-name> -n argocd -o jsonpath='sync={.status.sync.status} health={.status.health.status}{"\n"}'
   ```
   Do not manually `kubectl patch`/force-sync — it has `automated` sync, let
   it converge on its own; just poll.

### If Manual mode

1. **Confirm the base platform is at `HEAD`** and healthy before doing
   anything (`kubectl get applications -n argocd` — Kafka, Schema Registry,
   CFK operator, Flink Kubernetes Operator, CMF, `flink-resources` should
   already be `Synced`/`Healthy`). This mode never touches those.
2. **Still write the manifests to `tests/<test-name>/`** locally, for
   reproducibility — but apply them directly, no commit, no ArgoCD:
   ```bash
   kubectl apply -f tests/<test-name>/ -n flink
   ```
   CFK CRs by default for anything they can express. Use CMF's REST API
   (via `scripts/rest-call.sh`, see below) **only** when the user stated a
   preference for it, or the CR genuinely can't express what the test needs
   — never default to REST silently.
3. Every REST call made this way is logged automatically by
   `scripts/rest-call.sh` to `tests/<test-name>/rest-commands.md` — the
   exact `curl` invoked (real values, never placeholders) and a response
   summary, in execution order. This file is evidence and a reusable
   runbook; it is never itself applied to anything.

## Step 4: Run assertions

For each assertion in `test-case.yaml`, dispatch by `kind` using the scripts
in `scripts/` (see each script's `--help` for exact args — don't guess flags):

| kind | script | what it does |
|---|---|---|
| `health` | `scripts/poll-health.sh` | Polls a `kubectl get ... -o jsonpath=` until the expected value or timeout. |
| `data-flow` | `scripts/data-flow-check.sh` | Disposable producer pod feeds input messages into the source topic; disposable consumer pod reads the sink topic with a timeout; compares against `expect` (`exact`/`count`/`contains`). |
| `resource-state` | `scripts/resource-state-check.sh` | Runs a `kubectl get`/`describe` check command, compares output to `expect`. |
| `rest-response` | `scripts/rest-call.sh` | Issues the REST call, logs it to `rest-commands.md`, evaluates `expect` (a `jq` expression or literal) against the response body. |

Run assertions in the order they appear in `test-case.yaml` (a `health` check
before a `data-flow` check on the same job is the common ordering, since
there's no point feeding data to a job that never came up). Stop and report
FAIL on the first assertion that fails — don't keep running assertions
against a stack that's already known broken, unless the user asked for a
full report regardless.

## Step 5: Report

End every run with:

1. **PASS/FAIL per assertion**, actual vs. expected shown inline.
2. **Pointer** to `tests/<test-name>/` (and `rest-commands.md` if it exists)
   for full detail.
3. **Exact teardown commands** for whichever mode was used — never leave the
   user to figure this out themselves:

   *GitOps mode:*
   ```bash
   ./scripts/update-target-revision.sh flink-demo HEAD --yes
   git commit -am "chore: revert flink-demo targetRevision to HEAD"
   git push
   kubectl apply -f clusters/flink-demo/bootstrap.yaml
   kubectl apply -f clusters/flink-demo/bootstrap.yaml
   # then delete the test branch once you're satisfied:
   git push origin --delete test/<test-name>-<timestamp>
   git branch -D test/<test-name>-<timestamp>
   ```

   *Manual mode:*
   ```bash
   kubectl delete -f tests/<test-name>/ -n flink
   ```

Never run these teardown commands yourself unless the user explicitly asks —
report them and stop.

## Prerequisites

`gh`, `yq`, `kubectl`, `jq` (for `rest-response` assertions), and a
`flink-demo` cluster reachable per `docs/getting-started-for-the-uninitiated.md`
(local KIND) or `docs/bootstrap-procedure.md` (real cluster). Check for these
before starting the interview; tell the user what's missing rather than
failing partway through.

## Reference files

- [references/test-case-schema.md](references/test-case-schema.md) — the
  `test-case.yaml` shape and all four assertion kinds, with real examples.
- [references/naming-rules.md](references/naming-rules.md) — how
  `<test-name>` is derived and validated.

## Future extensions (not in v1 — do not attempt these)

- OAuth/mTLS cluster variants (`flink-demo-rbac`, `flink-demo-rbac-mtls`,
  `eks-demo`).
- Optional automated teardown gated behind explicit confirmation.
- New assertion `kind`s beyond the four above (log-content, Prometheus
  queries). The schema's `kind`-dispatch accepts these later without
  breaking existing test cases, but don't invent one ad hoc mid-run — flag
  it as out of scope and fall back to the closest existing kind, or ask the
  user how they'd like to proceed.
