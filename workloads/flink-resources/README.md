# Flink Resources

Core Confluent for Kubernetes (CFK) / Confluent Manager for Apache Flink (CMF)
integration, plus a generic, single-tenant Flink SQL demo. Deployed on every
cluster.

## What's Included

- **CMFRestClass** (`cmf-rest-class`) — the CFK-operator-to-CMF communication
  bridge. `flink-demo` uses no authentication; the RBAC clusters patch in
  OAuth (see [architecture.md](../../docs/architecture.md)).
- **FlinkEnvironment** (`default`) — the single environment for both native
  `FlinkApplication`s and Flink SQL (Compute Pools/Statements). Replaces the
  earlier `env1`/`default-flink-env` split.
- **Reference FlinkApplication** (`default-flink-app`) — an optional
  `StateMachineExample` JAR job demonstrating native Kubernetes deployment
  against the `default` environment. Not required for Flink SQL usage.
- **Generic Flink SQL demo** for the [cp-flink-sql](https://github.com/rjmfernandes/cp-flink-sql)
  repository — `myevent`/`myaggregated` topics and Avro schemas, a
  `FlinkKafkaCatalog` (`kafka-cat`) bound to Schema Registry, a
  `FlinkKafkaDatabase` (`main-kafka-cluster`) bound to the Kafka cluster, and a
  `FlinkComputePool` (`pool`, DEDICATED) with S3 checkpoint/savepoint storage.

The Flink SQL resources are declarative CFK custom resources (CFK 3.3.0+),
not imperative CMF API calls. They form a dependency chain that must be
applied in order and deleted in reverse; sync waves 5/10/30/35/40/45/50
enforce both directions. See
[architecture.md](../../docs/architecture.md#intra-application-sync-waves-flink-sql-resources)
for the constraints that apply to the whole chain.

## Prerequisites

The following must be deployed before this application:
- Confluent for Kubernetes (CFK) operator
- Confluent Manager for Apache Flink (CMF) operator
- Kafka cluster with Schema Registry
- MinIO for object storage (deployed as infrastructure application)

## Getting Started (Flink SQL demo)

Once this application is synced in ArgoCD, you can proceed directly to the
"Let's Play" section of the
[cp-flink-sql repository](https://github.com/rjmfernandes/cp-flink-sql?tab=readme-ov-file#lets-play).

On `flink-demo`, access CMF via the Ingress endpoint (not port-forward):
`http://cmf.flink-demo.confluentdemo.local`.

## Reference

For detailed setup instructions and examples, see the parent repository:
https://github.com/rjmfernandes/cp-flink-sql
