# Test Case Schema

A test case is **setup + one or more assertions**. It is written to
`tests/<test-name>/test-case.yaml` by the skill, from the interview — never
hand-authored by the user.

```yaml
name: <test-name>                # see naming-rules.md
description: <one-line human description from the interview>
mode: gitops | manual

setup:
  resources: []                  # zero or more — see "Setup resources" below

assertions: []                   # one or more — see "Assertion kinds" below
```

`setup.resources` is deliberately allowed to be **empty**. A test case that
only inspects state that's already deployed (e.g. "did the CMF resource
limit I already changed via ArgoCD actually apply?") needs no new resources
at all — it's assertions only.

## Setup resources

Each entry becomes one generated manifest, following this repo's existing
conventions exactly (read the referenced real file before generating its
analog — don't generate from memory):

```yaml
setup:
  resources:
    - kind: Topic
      name: <topic-name>
      # → KafkaTopic CR, shaped like workloads/flink-secure-sql-mtls/base/topics.yaml

    - kind: Schema
      name: <subject-name>
      # → Schema Registry subject registration, shaped like
      #   workloads/flink-secure-sql-mtls/base/schemas.yaml or
      #   workloads/colors-and-shapes/base/schemas.yaml

    - kind: FlinkStatement
      name: <statement-name>
      sql: |
        INSERT INTO ...
      # → FlinkStatement CR, shaped like
      #   workloads/flink-secure-sql-mtls/base/flink-statement.yaml

    - kind: FlinkApplication
      name: <app-name>
      jarImage: <image-ref-or-jarURI>
      # → FlinkApplication CR, shaped like
      #   workloads/colors-and-shapes/base/flink-application-colors.yaml

    - kind: HelmValuesOverlay
      app: <existing-app-name>       # e.g. "cmf-operator"
      values: { ... }
      # → NOT placed under tests/ — generated as a patch under
      #   workloads/<app>/overlays/flink-demo/ instead, since this is
      #   cluster-scoped configuration on an existing chart, not a new
      #   standalone test resource. See SKILL.md Step 3.
```

If the interview surfaces a resource kind not listed here, don't force it
into one of these — ask the user for the concrete manifest shape they want,
or point them at the closest existing workload in this repo as a template.

## Assertion kinds

Assertions compose freely — one test case can mix kinds, and
`setup.resources` can be empty while `assertions` still has entries.

### `health`

Poll a Kubernetes resource's status field until it reaches an expected value
or times out. The most common assertion — almost every test case that
deploys something new should have one of these before any `data-flow`
assertion on the same resource.

```yaml
- kind: health
  check: kubectl get flinkstatement orders-agg -n flink -o jsonpath='{.status.jobStatus.state}'
  expect: RUNNING          # or STABLE, depending on resource type
  timeout: 120s
```

### `data-flow`

Produce known input into a source topic, consume the sink topic, compare
against an expected outcome. Use for anything that checks *what data* a job
produces, not just whether it's alive.

```yaml
- kind: data-flow
  produce:
    topic: orders-input
    bootstrapServers: kafka.confluent.svc.cluster.local:9092
    messages:
      - '{"order_id":"1","product_id":"a","quantity":2,"price":10.00}'
      - '{"order_id":"2","product_id":"a","quantity":3,"price":10.00}'
  consume:
    topic: orders-output
    bootstrapServers: kafka.confluent.svc.cluster.local:9092
    timeout: 60s
  expect:
    mode: contains     # exact | count | contains
    value: '"total_quantity":5'
```

- `exact` — trimmed consumer output must equal `value` exactly.
- `count` — number of messages consumed must equal `value`.
- `contains` — consumer output must contain `value` as a substring.

### `resource-state`

Check any Kubernetes-visible field — not limited to Flink CRs. This is the
one that covers config/Helm-chart verification (e.g. "did this CMF resource
limit change actually apply to the running Deployment?").

```yaml
- kind: resource-state
  check: kubectl get deployment cmf -n confluent -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
  expect: "2Gi"
```

`expect` is an exact string match against the command's stdout by default.
Prefix `expect` with `regex:` to match as a regular expression instead (e.g.
`expect: "regex:^v1\\.19-cp\\d+$"`).

### `rest-response`

Issue a REST call (typically against CMF) and check the response. Always
logged to `tests/<test-name>/rest-commands.md`, in both modes — this is the
one assertion kind that always leaves a REST audit trail.

```yaml
- kind: rest-response
  request:
    method: GET
    url: http://cmf.confluent.svc.cluster.local:80/cmf/api/v1/environments/default/statements/orders-agg
  expect:
    jq: '.status.phase'
    value: RUNNING
```

`expect.jq` is a `jq` filter applied to the response body; the result must
equal `expect.value`.

## Worked example: a config-only test case (no new resources)

```yaml
name: cmf-memory-limit-2gi
description: Verify the CMF memory limit change in workloads/cmf-operator/overlays/flink-demo applied to the running Deployment
mode: manual

setup:
  resources: []

assertions:
  - kind: resource-state
    check: kubectl get deployment cmf -n confluent -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
    expect: "2Gi"
```

No topics, no Flink job, no producer/consumer pods — just one check against
already-deployed state. This is exactly as valid a test case as a full
data-flow test; don't over-scaffold it.
