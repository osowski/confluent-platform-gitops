# 24. CMF SQL Assistant: a Hand-Set Gemini Key Behind a Placeholder Secret

Date: 2026-11-17

## Status

Accepted.

## Context

CMF 2.5 adds the SQL Assistant, a preview page in the CMF UI that turns natural-language questions into Flink SQL with an LLM. Every cluster here uses Gemini through the `google-genai` provider, with an API key from Google AI Studio.

How CMF loads the key (`cp-flink-cmf` at `release-2.5.0`, `SqlAssistantModelConfiguration.java`):

- With `cmf.sql.assistant.enabled` false or `cmf.sql.assistant.model` unset, CMF never reads a key (:57-62).
- Otherwise CMF reads the key once, at startup, through the Kubernetes API, from the Secret named in `cmf.ai.models.<entry>.apiKey` (:226-237). Its own ServiceAccount can already `get` Secrets.
- A missing Secret, a missing key or a blank value fails startup, and CMF crash-loops (:238-271). There is no optional flag.
- A non-blank key isn't checked until the first AI request (:133-143).

The requirements:

- The key must not spread into more systems: no Git, no Secrets Manager entry, no Terraform state or IRSA role.
- A deploy without a key, such as another user bringing up the repo, must not be blocked.
- Turning the assistant on or off must not need a Git change.

Argo CD renders the chart with `helm template`, so the chart can't check whether the Secret exists (`lookup` always returns nothing).

## Decision

- **The base CMF values turn the assistant on for every cluster**: model entry `gemini-flash` (`google-genai`, `gemini-3.8-flash`), with its key in Secret `cmf-sql-assistant-llm`, key `api-key`, namespace `operator`.
- **A Job creates that Secret with the placeholder `not-configured`, only when the Secret is absent.** It never reads, compares or overwrites an existing Secret. It ships as the Kustomize component `workloads/cmf-operator/components/sql-assistant-key`, which every cluster's `cmf-operator-secrets` overlay includes (wave 117; `cmf-operator` is 118); flink-demo has a `cmf-operator-secrets` Application for this alone. The Job uses the pinned `bitnami/kubectl` image and pattern of the `cmf-compile-tls` keygen Job ([ADR-0023](0023-cmf-2-5-flink-2-3-sql-compilation.md)). It runs as a `Sync` hook at wave -1, with its RBAC at wave -2, so it runs before any wave-0 resources (PostgreSQL, on the RBAC clusters) instead of waiting for them to become healthy, as a `PostSync` hook would.
- **The real key is set by hand** with `kubectl create --dry-run=client -o yaml | kubectl replace -f -`, then a CMF restart. Turning the assistant off puts the placeholder back the same way. The runbook is in the [CMF README](../workloads/cmf-operator/README.md#sql-assistant-api-key).

The Secret is created with `kubectl create`, so it carries no Argo tracking label or annotation and no `last-applied-configuration`. Argo CD never prunes it or overwrites a real key.

## Consequences

**Positive:**

- A deploy with no key starts CMF and the rest of the cluster normally.
- The key lives only in the cluster's Secret: nothing in Git, Secrets Manager or Terraform state.
- Switching the assistant on, off, or to a new key needs no commit.
- A fresh bootstrap re-creates the placeholder. After a recreated `operator` namespace, one sync of `cmf-operator-secrets` does; the Application doesn't self-heal.

**Negative / constraints:**

- Without a real key the SQL Assistant tab still shows, and every AI request fails with Gemini's invalid-key error. SQL mode still works.
- The sync waves set the order in which the parent applies the two Applications, not the order in which they finish. These clusters' Argo CD has no health check for Applications, so the parent doesn't wait for `cmf-operator-secrets` to be healthy before it applies `cmf-operator`. Wherever the Secret is absent (a cluster's first rollout, a fresh bootstrap, a recreated `operator` namespace), CMF crash-loops until the Job creates it, then starts on its own. On flink-demo's first rollout that took 4 restarts over about 90 seconds.
- Every switch restarts CMF. Its Deployment uses the `Recreate` strategy, so the CMF API and UI are briefly down.
- Deleting the Secret by hand crash-loops CMF until the next `cmf-operator-secrets` sync re-creates the placeholder. The runbook turns the assistant off by replacing the value, never by deleting the Secret.
- Anything that deletes the `operator` namespace also deletes the real key, which then has to be set again.
- Each cluster has its own Secret, so the key is set once per cluster that should have the assistant on.
- A new cluster with CMF must include the component in its `cmf-operator-secrets` app, or CMF never starts there.
- The Job's Role can `create` any Secret in `operator`, because `create` can't be limited by `resourceNames`.

## Alternatives considered

- **External Secrets Operator, AWS Secrets Manager and an IRSA role** (the original design). Rejected: it copies the key into Secrets Manager and adds Terraform state and IAM for one demo key.
- **Helm `lookup` to keep an existing Secret.** Doesn't work under Argo CD's `helm template`.
- **Argo CD `--helm-set` overrides to switch the assistant.** The parent Application's sync reverts them, and re-applying `bootstrap.yaml` drops them.
- **A placeholder Secret committed to Git.** Argo CD would overwrite a real key on every sync unless `ignoreDifferences` was also set. It also breaks the repo's rule against plaintext Secret manifests.
- **The Job as a `PreSync` hook of the `cmf-operator` Application**, so that Argo CD creates the Secret before it applies the Deployment. That would remove the first-rollout crash-loop, but it needs a third source on that multi-source Application and a separate kustomization. Rejected because the crash-loop is short and fixes itself.
- **An Argo CD health check for Applications, so that later waves wait for earlier ones to become healthy.** That would change ordering for every Application on every cluster, and manual-sync Applications left OutOfSync or Missing would block later waves.
- **A Git toggle, with the model unset by default.** Every switch needs a commit.
- **`apiKey.value` from an environment variable set with `extraEnv` and `secretKeyRef`.** A missing Secret still blocks startup, and the key ends up in the pod environment.
