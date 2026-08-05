# CP Flink SQL Sandbox

## Overview

This workload deploys all necessary resources to enable the [cp-flink-sql demo](https://github.com/rjmfernandes/cp-flink-sql) out of the box.

## What's Included

- **Kafka Topics**: `myevent` (source) and `myaggregated` (sink)
- **Schemas**: Avro schemas registered in Schema Registry for both topics
- **Flink Catalog**: `FlinkKafkaCatalog` `kafka-cat`, bound to Schema Registry so topics surface as tables
- **Flink Database**: `FlinkKafkaDatabase` `main-kafka-cluster`, bound to the Kafka cluster
- **Compute Pool**: `FlinkComputePool` `pool` (DEDICATED) with S3 checkpoint/savepoint storage

The Flink resources are declarative CFK custom resources (CFK 3.3.0+), not
imperative CMF API calls. They form a dependency chain that must be applied in
order and deleted in reverse; sync waves 40/45/50 enforce both directions. See
[architecture.md](../../docs/architecture.md) for the constraints that apply to
the whole chain.

## Prerequisites

The following must be deployed before this application:
- Confluent for Kubernetes (CFK) operator
- Confluent Manager for Apache Flink (CMF) operator
- Kafka cluster with Schema Registry
- MinIO for object storage (deployed as infrastructure application)

## Getting Started

Once this application is synced in ArgoCD, you can proceed directly to the "Let's Play" section of the [cp-flink-sql repository](https://github.com/rjmfernandes/cp-flink-sql?tab=readme-ov-file#lets-play).

### Endpoints

Access the following services via Ingress (not port-forward; when deployed in the `flink-demo` cluster):

- **CMF API**: `http://cmf.flink-demo.confluentdemo.local`
- **MinIO API**: `http://s3.flink-demo.confluentdemo.local`
- **MinIO Console**: `http://s3-console.flink-demo.confluentdemo.local`
- **Control Center**: `http://controlcenter.flink-demo.confluentdemo.local`

### Running Flink SQL Queries

Use the CMF API endpoint to execute Flink SQL statements as documented in the parent repository.

> [!TIP] **Important differences from the upstream repo:**
> - Use Ingress endpoints instead of port-forwarding
> - CMF API: `http://cmf.flink-demo.confluentdemo.local`
> - MinIO API: `http://s3.flink-demo.confluentdemo.local`
> - Kafka bootstrap: `kafka.flink-demo.confluentdemo.local:31000`

## Reference

For detailed setup instructions and examples, see the parent repository:
https://github.com/rjmfernandes/cp-flink-sql
