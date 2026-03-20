# Gateway Testing Strategy - Executive Summary

## Overview

Three-test progression validating Confluent Private Cloud Gateway (CPC Gateway) with Flink applications. Tests will be contributed upstream to [cp-flink-cmf](https://github.com/confluentinc/cp-flink-cmf/tree/main/ci/e2e/tests).

## Test Scenarios

### 1. Happy Path (`gateway_stateful`)
**Validates:** Stateful operations and recovery through Gateway

- Single Kafka cluster, stateful_flink pattern app
- Port-based broker identification (no TLS)
- Checkpoint completion and state restoration
- **Key validations:** Job running, State persistence, checkpoint recovery, data correctness (N in = N out)
- **CMF:** Catalog/database metadata persists in CMF SQL database
- **Schema Registry:** No SchemaRegistry migration concerns for this test case

### 2. Live Reconfiguration (`gateway_live_reconfig`)
**Validates:** Live backend switching between Kafka clusters with FlinkApplication

- **Kafka:** Two distinct Kafka clusters (namespace `kafka`, `kafka2`)
- **Flink:** A single Transactional (EOS) FlinkApplication, with continuous data producer during backend switch
- **Switch mechanism:** Update Gateway `streamingDomains` (kafka → kafka2)
- **Key validations:**
  - FlinkApplication deploys and runs through Gateway
  - Zero duplication (hard requirement), in-flight txns fail gracefully
  - Jobs recover automatically, no manual intervention
- **CMF Critical:** Metadata does NOT need migration (SQL-backed, not Kafka-backed)
- **Schema Registry:** Both clusters point to common SchemaRegistry instance

### 3. Live Reconfiguration with FlinkStatement (`gateway_live_reconfig_statement`)
**Validates:** Live backend switching with SQL-based FlinkStatement jobs

- **Kafka:** Two distinct Kafka clusters (namespace `kafka`, `kafka2`)
- **Flink:** A single Transactional (EOS) FlinkStatement, with continuous data producer during backend switch
- **Switch mechanism:** Update Gateway `streamingDomains` (kafka → kafka2)
- **Key validations:**
  - FlinkStatement deploys and runs through Gateway
  - SQL catalog integration works (CMF KafkaCatalog references tables)
  - Zero duplication (hard requirement), in-flight txns fail gracefully
  - Statement recovers automatically, no manual intervention
- **CMF Critical:** Metadata does NOT need migration (SQL-backed, not Kafka-backed)
- **Schema Registry:** Both clusters point to common SchemaRegistry instance

## Key Technical Decisions

- **Broker Identification:** Port-based (9092/9093/9094/9095) - no TLS/SNI complexity
- **Security:** Passthrough authentication
- **Applications:** Bounded datasets for deterministic validation
- **Validation Scope:** Simple metrics (checkpoint success, record counts, duplication checks)
- **Data Flow:** Continuous producer during switch

## CMF Integration Architecture

**Gateway Configuration Points:**
- **FlinkApplications:** Kafka connection in `FlinkApplication.spec` (directly specified)
- **FlinkStatements:** `KafkaDatabase.spec.kafkaCluster.connectionConfig.bootstrap.servers`

### FlinkApplications (Tests #1, #2)

```
FlinkEnvironment (defines Flink configuration)
      │
      └─ Referenced by FlinkApplication
              ↓
      FlinkApplication (JAR-based deployment)
              ↓
      Flink Job connects to Kafka
              ↓
      Gateway (gateway-demo.kafka.svc.cluster.local:9092)
              ↓
      Kafka Cluster (kafka.kafka.svc.cluster.local:9071)
```

**Key Insight:** FlinkApplications use FlinkEnvironments only. No CMF Catalogs, Databases, or ComputePools needed. Kafka connection configured directly in FlinkApplication spec.

### FlinkStatements (Test #3)

```
CMF Operator (operator namespace)
  ├─ SQL Database (catalogs, databases, compute pools, table definitions)
  │  ├─ KafkaDatabase: stores "bootstrap.servers" config
  │  └─ KafkaCatalog: stores Schema Registry URL
  ├─ REST API (manages FlinkDeployments, SQL statements)
  └─ Kubernetes Controller (watches Flink CRDs)
      │
      └─ Creates FlinkDeployments from SQL statements
              ↓
      FlinkStatement → Flink SQL Job
              ↓
      Queries Kafka topics via catalog/database config
              ↓
      Gateway (gateway-demo.kafka.svc.cluster.local:9092)
              ↓
      Kafka Cluster (kafka.kafka.svc.cluster.local:9071)
```

**Key Insight:** SQL catalog metadata (table definitions) stored in CMF SQL database. Schema Registry schemas stored in `_schemas` Kafka topic.

## Success Criteria Summary

| Test | Application Recovery | Data Guarantees | CMF Metadata Impacts |
|------|---------------------|-----------------|-----------------|
| Stateful (#1) | Checkpoint restore | N in = N out | No metadata migration needed |
| Live Reconfig App (#2) | Automatic recovery | Zero duplication (txn) | No metadata migration needed |
| Live Reconfig Statement (#3) | Automatic recovery | Zero duplication (txn) | SQL catalog metadata persists |
