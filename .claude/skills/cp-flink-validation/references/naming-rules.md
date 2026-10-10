# Naming Rules

`<test-name>` is derived once, from the interview's description, and then
reused everywhere — the `tests/<test-name>/` directory, the branch suffix,
the ArgoCD Application name, CR names, topic names. Validate it
**immediately** after deriving it, before generating any file or resource —
a bad name should fail fast, not mid-apply.

## Deriving the slug

1. Lowercase the description.
2. Replace every run of non-`[a-z0-9]` characters with a single hyphen.
3. Trim leading/trailing hyphens.
4. Truncate to **40 characters**, then trim any trailing hyphen left by the
   truncation.

```bash
./scripts/slugify.sh "Verify Orders Aggregation SQL Job"
# orders-aggregation-sql-job
```

40 characters (not Kubernetes' full 63-character object-name limit) is the
cap deliberately, to leave headroom for suffixes appended when deriving
related resource names — e.g. `<test-name>-src-topic`, `<test-name>-app`,
`<test-name>-consumer` — so those composite names still fit under 63
characters.

## Validating the slug

Must match Kubernetes' DNS-1123 label rule:

```
^[a-z0-9]([-a-z0-9]*[a-z0-9])?$
```

`scripts/slugify.sh` validates this itself and exits non-zero with an error
if the derived slug is empty or somehow still invalid (e.g. the description
was made entirely of characters that collapse to nothing). If that happens,
ask the user for a short, plain-words name instead of trying to fix the
slugification.

## Where the slug is reused

| Use | Example (for slug `orders-aggregation-sql-job`) |
|---|---|
| Fixture directory | `tests/orders-aggregation-sql-job/` |
| Branch suffix (GitOps mode) | `test/orders-aggregation-sql-job-20260917143000` |
| ArgoCD Application name (GitOps mode) | `test-orders-aggregation-sql-job` |
| FlinkStatement/FlinkApplication CR name | `orders-aggregation-sql-job` |
| Topic names, if generated | `orders-aggregation-sql-job-src`, `orders-aggregation-sql-job-sink` |

Keep the same slug consistent across all of these within one test run —
don't re-derive it partway through.
