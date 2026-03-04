# CP Flink SQL Sandbox

## Overview

This workload deploys all necessary resources to enable the [cp-flink-sql demo](https://github.com/rjmfernandes/cp-flink-sql) out of the box.

## What's Included

- **Kafka Topics**: `myevent` (source) and `myaggregated` (sink)
- **Schemas**: Avro schemas registered in Schema Registry for both topics
- **Flink Catalog**: Kafka catalog configured to recognize topics and schemas
- **Flink Database**: Connection to Kafka cluster
- **Compute Pool**: Flink compute pool with S3 checkpoint/savepoint storage

## Prerequisites

The following must be deployed before this application:
- Confluent for Kubernetes (CFK) operator
- Confluent Manager for Apache Flink (CMF) operator
- Kafka cluster with Schema Registry
- S3proxy for object storage

## Getting Started

Once this application is synced in ArgoCD, you can proceed directly to the "Let's Play" section of the [cp-flink-sql repository](https://github.com/rjmfernandes/cp-flink-sql?tab=readme-ov-file#lets-play).

### Endpoints

Access the following services via Ingress (not port-forward):

- **CMF API**: `http://cmf.flink-demo.confluentdemo.local`
- **S3proxy**: `http://s3proxy.flink-demo.confluentdemo.local`
- **Control Center**: `http://controlcenter.flink-demo.confluentdemo.local`

### Running Flink SQL Queries

Use the CMF API endpoint to execute Flink SQL statements as documented in the parent repository.

## Reference

For detailed setup instructions and examples, see the parent repository:
https://github.com/rjmfernandes/cp-flink-sql
