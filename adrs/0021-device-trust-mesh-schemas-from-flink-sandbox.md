# 21. Device Trust Mesh Schemas Come From flink-sandbox

Date: 2026-11-12

## Status

Accepted.

## Context

The Device Trust Mesh registers 23 Schema Registry subjects: Avro records for the business and derived topics, and A2A JSON Schemas for the agent topics. The agents, the simulator and `context-mcp` in [osowski/flink-sandbox `device-trust-mesh/`](https://github.com/osowski/flink-sandbox/tree/main/device-trust-mesh) validate against the same schemas, which they ship as package data. The schemas are business logic, so they belong with that code, and one repo has to be the only place they are edited.

This repo registers them through CFK `Schema` CRs, and each CR reads its schema from a ConfigMap. A Kustomize `configMapGenerator` can only read files inside its own kustomization root. A URL in `files:` doesn't work, and neither does a second Argo CD source: multi-source `ref` sources only feed Helm value files.

## Decision

- **flink-sandbox owns the schemas.** It holds the sources, the pinned A2A v1.0.1 bundle and the generator (`device-trust-mesh/scripts/generate_schemas.py`). The generator writes the registered schemas to `dtm/schemas/{avro,a2a}/`, and also writes `dtm/schemas/kustomization.yaml`, with one ConfigMap per schema named `dtm-schema-<subject>` in `device-trust-mesh`.
- **This repo references that directory as a Kustomize remote base** in `workloads/device-trust-mesh/base/kustomization.yaml`, pinned with `?ref=<commit>` to a `device-trust-mesh-v*` release. The pin is the commit, not the tag, so moving the tag can't change what renders. A comment names the tag.
- **This repo keeps every other Kubernetes resource**, including the `Schema` CRs in `base/schemas.yaml`, their Schema Registry reference and their sync wave.
- **The ref and the eks-demo image tags move together**, so the code, the schemas and the images share one release.

## Consequences

**Positive:**

- Schemas are edited in one place. The images and the registered subjects come from the same release commit.
- Changing an existing schema in this repo is one `ref` change.
- A new schema gets its ConfigMap from the flink-sandbox generator, without a hand edit.

**Negative / constraints:**

- A new subject still needs its `Schema` CR here, matching the ConfigMap name.
- A schema change shows here only as a new `ref`. Review the schema diff in flink-sandbox, or in Argo CD's diff before syncing.
- `kustomize build` of `device-trust-mesh` and Argo CD's render fetch flink-sandbox from GitHub. flink-sandbox is public, so no credentials are needed.
