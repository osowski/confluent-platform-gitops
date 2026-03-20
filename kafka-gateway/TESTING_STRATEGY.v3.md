# Gateway Testing Strategy

## Overview

This document outlines the testing strategy for Confluent Private Cloud Gateway (CPC Gateway) integration with Confluent Manager for Apache Flink (CMF). Tests will be contributed upstream to the [cp-flink-cmf repository](https://github.com/confluentinc/cp-flink-cmf/tree/main/ci/e2e/tests).

## Goals

Validate that Flink applications can:
1. Successfully read/write Kafka data through the Gateway
2. Maintain stateful operations (checkpoints, savepoints) through Gateway
3. Handle Kafka backend cluster switching with different consistency guarantees

## Test Suite Structure

Tests will follow the cp-flink-cmf pattern with separate directories:

```
ci/e2e/tests/
├── gateway_stateful/            # Stateful operations through Gateway
│   ├── run.sh
│   └── definitions/
│       ├── gateway.yaml
│       ├── gateway-services.yaml
│       └── stateful-app.yaml
├── gateway_live_reconfig/       # Live backend switching with FlinkApplication
│   ├── run.sh
│   └── definitions/
│       ├── kafka-cluster-2.yaml
│       ├── gateway.yaml
│       ├── gateway-services-kafka.yaml
│       ├── gateway-services-kafka2.yaml
│       └── stateful-transactional.yaml
└── gateway_live_reconfig_statement/  # Live backend switching with FlinkStatement
    ├── run.sh
    └── definitions/
        ├── kafka-cluster-2.yaml
        ├── gateway.yaml
        ├── gateway-services-kafka.yaml
        ├── gateway-services-kafka2.yaml
        └── sql-statement.yaml
```

## Test Scenarios

### 1. Stateful Operations (`gateway_stateful`)

**Purpose:** Validate stateful operations and recovery through Gateway.

**Application:**
- Based on `stateful_flink` test pattern
- Includes state, checkpoints, potential savepoint operations
- Bounded dataset

**Infrastructure:**
- Single Kafka cluster (namespace: `kafka`)
- Gateway with port-based broker identification
- Gateway services for Kafka cluster

**Validation (Robust):**
- ✅ Deployment reaches "running" state
- ✅ CLI proxy can connect to Flink job
- ✅ Job is active (jobs-running > 0)
- ✅ State size increases (stateful operations working)
- ✅ Checkpoint completion (not just attempted)
- ✅ Recovery from checkpoint (restart job, verify state restored)
- ✅ Data correctness (consume N messages, produce N messages)

**CMF Integration Validation:**
- ✅ FlinkEnvironment configuration works
- ✅ FlinkApplication receives correct Kafka bootstrap.servers
- ✅ Flink job connects to Kafka **through Gateway** (not directly)
- ✅ No errors in Gateway or Flink logs

**Schema Registry:**
- No SchemaRegistry migration concerns for this test case

**Success Criteria:**
- Stateful job runs successfully
- Checkpoints complete and can be used for recovery
- State persists correctly through Gateway
- CMF catalog/database operations remain consistent through job lifecycle

---

### 2. Live Reconfiguration with FlinkApplication (`gateway_live_reconfig`)

**Purpose:** Validate live backend switching from Kafka cluster 1 to cluster 2 using FlinkApplication.

**Scenario:** Live reconfiguration of Gateway `streamingDomains`

**Kafka:**
- Two distinct Kafka clusters:
  - Namespace `kafka` - Cluster 1 (initial backend)
  - Namespace `kafka2` - Cluster 2 (switch target)
- Single Gateway instance
- Gateway services in both namespaces:
  - `kafka-gateway-bootstrap.kafka.svc.cluster.local:9092`
  - `kafka-gateway-bootstrap.kafka2.svc.cluster.local:9092`

**Flink:**
- A single Transactional (EOS) FlinkApplication
  - `execution.checkpointing.mode: EXACTLY_ONCE`
  - `sink.delivery-guarantee: exactly-once`
  - Kafka transactions enabled
  - Topics: `test-input-txn`, `test-output-txn`
  - Bounded dataset
- Continuous data producer during backend switch

**Test Flow:**
1. Deploy both Kafka clusters
2. Deploy Gateway pointing to `kafka` cluster
3. Deploy Flink application
4. Start continuous data producer
5. Validate app processing data
6. **Switch Gateway backend:** Update `streamingDomains` to point to `kafka2`
7. Continue producing data during switch
8. Validate post-switch behavior

**Validation:**

*Key Validations:*
- ✅ FlinkApplication deploys and runs through Gateway
- ✅ Zero duplication (hard requirement), in-flight txns fail gracefully
- ✅ Jobs recover automatically, no manual intervention

*Detailed Checks:*
- ✅ In-flight transactions fail (expected during switch)
- ✅ New transactions succeed on kafka2 without intervention
- ✅ Zero duplicate messages in output (hard requirement)
- ✅ Transactions commit on cluster where they started
- ✅ Job recovers automatically

*CMF Integration:*
- ✅ **Key Insight:** Metadata does NOT need migration (SQL-backed, not Kafka-backed)
  - **Pre-switch:** Gateway backend points to kafka cluster
  - **During switch:** Gateway backend changes (kafka → kafka2), FlinkApplication config UNCHANGED
  - **Post-switch:** Gateway now routes to kafka2
- ✅ FlinkEnvironment continues to work
- ⚠️ **Schema Registry:** Both clusters point to common SchemaRegistry instance

**Success Criteria:**
- App continues processing after switch
- Zero duplication guaranteed (transactional semantics)
- No manual intervention required for recovery
- Schema availability maintained through common SR instance

---

### 3. Live Reconfiguration with FlinkStatement (`gateway_live_reconfig_statement`)

**Purpose:** Validate live backend switching with SQL-based Flink jobs (FlinkStatement).

**Scenario:** Same as Test #2 but using FlinkStatement instead of FlinkApplication

**Kafka:**
- Two distinct Kafka clusters:
  - Namespace `kafka` - Cluster 1 (initial backend)
  - Namespace `kafka2` - Cluster 2 (switch target)
- Single Gateway instance
- Gateway services in both namespaces

**Flink:**
- A single Transactional (EOS) FlinkStatement
  - Simple SQL query pattern (e.g., `INSERT INTO output_table SELECT * FROM input_table`)
  - Uses CMF KafkaCatalog for table definitions
  - Tables reference topics on Kafka cluster via Gateway
  - `execution.checkpointing.mode: EXACTLY_ONCE`
  - `sink.delivery-guarantee: exactly-once`
  - Bounded dataset
- Continuous data producer during backend switch

**Test Flow:**
1. Deploy both Kafka clusters
2. Deploy Gateway pointing to `kafka` cluster
3. Create KafkaCatalog and KafkaDatabase in CMF
4. Create Kafka topics for input/output tables
5. Register table schemas in Schema Registry (if schema-aware)
6. Deploy FlinkStatement with SQL query
7. Start continuous data producer
8. Validate FlinkStatement processing data
9. **Switch Gateway backend:** Update `streamingDomains` to point to `kafka2`
10. Continue producing data during switch
11. Validate post-switch behavior

**Validation:**

*Key Validations:*
- ✅ FlinkStatement deploys and runs through Gateway
- ✅ SQL catalog integration works (CMF KafkaCatalog references tables)
- ✅ Zero duplication (hard requirement), in-flight txns fail gracefully
- ✅ Statement recovers automatically, no manual intervention

*Detailed Checks:*
- ✅ Statement deploys successfully through CMF
- ✅ SQL query executes against Kafka topics via Gateway
- ✅ Catalog resolves table definitions correctly
- ✅ Schema Registry integration works (schema-aware tables)
- ✅ Records processing (numRecordsIn/Out > 0)
- ✅ Statement continues running (may restart from checkpoint)
- ✅ Records processing resumes on kafka2
- ✅ Zero duplicate messages in output (transactional semantics)

*CMF Integration:*
- ✅ **Key Insight:** Metadata does NOT need migration (SQL-backed, not Kafka-backed)
  - **Pre-switch:** KafkaDatabase points to `gateway-demo.kafka.svc.cluster.local:9092`
  - **During switch:** Gateway backend changes (kafka → kafka2), KafkaDatabase config UNCHANGED
  - **Post-switch:** Same KafkaDatabase, Gateway now routes to kafka2
- ✅ CMF catalog/database operations work after Gateway backend switch (SQL operations, unaffected)
- ✅ KafkaCatalog table definitions remain accessible (stored in CMF SQL database)
- ✅ FlinkStatement continues to reference same catalog/database (no reconfiguration)
- ✅ SQL queries work against new backend transparently
- ⚠️ **Schema Registry:** Both clusters point to common SchemaRegistry instance

**Success Criteria:**
- FlinkStatement runs successfully through Gateway
- SQL catalog integration works seamlessly
- Statement continues processing after backend switch
- Zero duplication guaranteed (transactional semantics)
- No manual intervention required for recovery
- SQL catalog metadata persists (SQL-backed, unaffected by Kafka switch)
- Schema availability maintained through common SR instance

---

## Future Test Cases (Documented, Not Implemented Initially)

### Additional Scenarios
- Gateway failure/recovery
- Network partition between Gateway and Kafka
- Multi-tenant Gateway (multiple routes)
- External access via NodePort
- Pre-seeded data migration
- Consumer offset migration
- Blue/green deployment with dual Gateway instances

---

## Technical Requirements

### Gateway Configuration

**Image:** `confluentinc/cpc-gateway:1.1.2`

**Key Settings:**
- Broker identification: `type: port` (no TLS required)
- Security: `auth: passthrough`
- Backend: Port-mapped services (9092, 9093, 9094, 9095)

### Port-Mapped Services (per cluster)

Required for port-based broker identification:

```yaml
# Bootstrap (headless)
kafka-gateway-bootstrap.<namespace>.svc.cluster.local:9092

# Individual brokers
kafka-gateway-0.<namespace>.svc.cluster.local:9093  → kafka-0:9092
kafka-gateway-1.<namespace>.svc.cluster.local:9094  → kafka-1:9092
kafka-gateway-2.<namespace>.svc.cluster.local:9095  → kafka-2:9092
```

### Kafka Clusters

- 3 brokers per cluster
- Standard CFK deployment (`definitions/cp-kafka.yaml` pattern)
- Internal listener on port 9092
- No TLS (PLAINTEXT)

### Test Utilities

Leverage existing cp-flink-cmf utilities:
- `includes/utils.sh` - Deployment helpers, wait functions
- `includes/test_reporting.sh` - Test output formatting
- `includes/create_kafka_topics.sh` - Topic management
- `includes/savepoint_utils.sh` - Savepoint operations (if needed)

---

## CMF Integration - Cross-Cutting Concerns

**Critical Architectural Finding:** CMF (Confluent Manager for Apache Flink) uses a **SQL database backend** (SQLite/PostgreSQL/SQL Server) for metadata storage, **NOT Kafka topics**.

### CMF Architecture with Gateway

**Gateway Configuration Points:**
- **FlinkApplications:** Kafka connection in `FlinkApplication.spec` (directly specified)
- **FlinkStatements:** `KafkaDatabase.spec.kafkaCluster.connectionConfig.bootstrap.servers`

#### FlinkApplications (Tests #1, #2)

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

#### FlinkStatements (Test #3)

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

### CMF Components and Gateway Interaction

1. **Catalog Metadata (KafkaCatalog)**
   - **Stored in:** CMF SQL database
   - **Contains:** Schema Registry URL
   - **Gateway involvement:** None (CMF just stores the URL)
   - **Operations:** create, list, describe catalogs (SQL operations)

2. **Database Metadata (KafkaDatabase)**
   - **Stored in:** CMF SQL database
   - **Contains:** Kafka `bootstrap.servers` configuration
   - **Gateway involvement:** **Critical - this is where Gateway endpoint is configured**
   - **Operations:** create, list, describe databases (SQL operations)
   - **Example:**
     ```yaml
     kind: KafkaDatabase
     spec:
       kafkaCluster:
         connectionConfig:
           bootstrap.servers: "gateway-demo.kafka.svc.cluster.local:9092"
     ```

3. **Schema Registry Integration**
   - **Schemas stored in:** `_schemas` Kafka topic
   - **Schema Registry connects to:** Kafka cluster (may or may not use Gateway)
   - **CMF stores:** Schema Registry URL in KafkaCatalog (not a Kafka connection)
   - **Gateway consideration:** Decide if SR should connect through Gateway

4. **FlinkEnvironment Configuration**
   - **References:** CMF REST API endpoint (not Kafka)
   - **CMF uses:** Kubernetes API and SQL database
   - **Gateway involvement:** None at FlinkEnvironment level

### Test Implementation Guidelines

**For All Tests:**
1. Create FlinkEnvironment (references CMF REST API, no Kafka dependency)
2. Create KafkaDatabase with **Gateway endpoint** as bootstrap.servers
3. Validate CMF catalog/database creation (SQL operations, verify via CMF REST API)
4. Deploy FlinkApplication referencing the KafkaDatabase
5. Verify Flink job connects to Kafka **through Gateway** (check job logs)
6. Monitor Gateway logs for Kafka traffic from Flink jobs

**For Backend Switching Tests:**

**Live Reconfiguration (Scenario A):**
1. **Pre-switch:**
   - KafkaDatabase configured with Gateway endpoint: `gateway-demo.kafka.svc.cluster.local:9092`
   - Gateway backend points to kafka1: `kafka.kafka.svc.cluster.local:9071`
2. **Switch:**
   - Update Gateway `streamingDomains` to kafka2: `kafka.kafka2.svc.cluster.local:9071`
   - KafkaDatabase config **remains unchanged** (still points to same Gateway endpoint)
3. **Post-switch:**
   - Validate Flink jobs connect through Gateway to kafka2
   - CMF catalog/database operations unchanged (SQL-backed)

**Blue/Green (Scenario C):**
1. **Setup:**
   - Create two KafkaDatabase objects in CMF SQL database:
     - `blue-database`: Gateway endpoint `gateway-kafka.kafka.svc.cluster.local:9092`
     - `green-database`: Gateway endpoint `gateway-kafka2.kafka2.svc.cluster.local:9092`
2. **Migration:**
   - Update FlinkApplications to reference `green-database`
   - Redeploy applications
3. **Validation:**
   - Verify apps now connect through gateway-kafka2 to kafka2

**Validation Commands:**
```bash
# List catalogs through CMF (SQL operation, not Kafka)
confluent flink catalog list --url ${CMF_URL}

# List databases (SQL operation, not Kafka)
curl ${CMF_URL}/cmf/api/v1/catalogs/kafka/kafka-cat/databases

# Verify KafkaDatabase bootstrap.servers points to Gateway
curl ${CMF_URL}/cmf/api/v1/catalogs/kafka/kafka-cat/databases/main-kafka-cluster | jq '.spec.kafkaCluster.connectionConfig'

# Check Flink job connects through Gateway (from job logs)
kubectl logs -n flink <flink-job-pod> | grep "bootstrap.servers"

# Verify Gateway routes traffic (from Gateway logs)
kubectl logs -n kafka <gateway-pod> | grep "kafka-0\|kafka-1\|kafka-2"

# Check Schema Registry topics (if SR uses Kafka)
kafka-topics --list --bootstrap-server kafka.kafka.svc.cluster.local:9071 | grep _schemas
```

### Schema Registry Configuration

**Answer: Use common Schema Registry for both Kafka clusters**

- CPC Gateway does not currently support SR proxying
- Guidance: Do not try to run SR through CPC Gateway or assume it can front SR REST calls today
- For this test suite: Deploy a single common Schema Registry instance that both Kafka clusters share
- The `_schemas` topic will exist on both clusters (SR writes to both)
- This approach simplifies testing while validating Gateway behavior with schema-aware applications

### Known Considerations

- **CMF Metadata:** Stored in SQL database, not Kafka - no migration needed for backend switching
- **Schema Registry:** Common SR for both clusters - no migration needed during Gateway backend switch
- **KafkaDatabase Config:** Gateway endpoint stays constant during live reconfiguration
- **Catalog IDs:** Managed by CMF SQL database, independent of Kafka cluster

---

## Validation Metrics (Simple)

### Deployment Health
- Pod status (Running)
- Job status (Running)
- CLI proxy connectivity

### Data Flow
- Checkpoint success count
- Records in vs records out (equality check)
- Message count validation (produce N, consume N)

### Transactional Guarantees
- No duplicate messages in output topic
- Transaction success/failure counts
- Commit/abort counts

### Gateway Health
- Gateway pod running
- No errors in Gateway logs
- Service endpoints reachable

### CMF Integration
- Catalog list operations succeed (SQL-based, via CMF REST API)
- Database list/describe operations succeed (SQL-based, via CMF REST API)
- KafkaDatabase contains correct Gateway bootstrap.servers
- FlinkApplication receives Gateway endpoint from KafkaDatabase
- Flink job connects to Kafka through Gateway (verify in job manager logs)
- Schema Registry operations work (separate from CMF - SR may connect directly to Kafka)
- No CMF errors in operator logs
- FlinkEnvironment references resolve correctly (CMF REST API endpoint)

---

## Test Execution

### Prerequisites
- Minikube/Kind cluster (cp-flink-cmf test environment)
- CFK operator installed
- CMF operator installed
- Confluent CLI available

### Running Tests

```bash
# Individual test
cd ci/e2e/tests/gateway_stateful
./run.sh

# Via test suite (if integrated)
./ci/e2e/run_tests.sh gateway_stateful
./ci/e2e/run_tests.sh gateway_live_reconfig
./ci/e2e/run_tests.sh gateway_live_reconfig_statement
```

### Test Reporting

Follow cp-flink-cmf pattern:
- Use `test_suite_start`, `test_start`, `test_end`
- Output: `print_green` for success, `print_red` for failure
- Exit code: 0 for success, non-zero for failure

---

## Contribution Guidelines

### Code Style
- Match existing cp-flink-cmf bash conventions
- Use their utility functions (don't reinvent)
- Follow their YAML formatting for definitions
- Include comments explaining Gateway-specific config

### Documentation
- Update cp-flink-cmf README with Gateway test info
- Document any new test utilities added
- Provide clear failure messages

### CI Integration
- Tests should work in their CI environment
- Handle their environment variables (`FLINK_VERSIONS`, `CPU_CONFIG_TYPE`, etc.)
- Clean up resources after test completion

### Pull Request Checklist
- [ ] Tests follow existing patterns
- [ ] All tests pass locally
- [ ] Documentation updated
- [ ] No hardcoded values (use variables)
- [ ] Resource cleanup implemented
- [ ] Test reporting follows conventions

---

## Open Questions / TODOs

1. **Schema migration:** How to handle `_schemas` topic during backend switching? (Answer: Use common SR for both clusters)
2. **FlinkStatement SQL patterns:** What SQL queries best validate Gateway behavior (simple passthrough vs aggregations)?
3. **Gateway Admin Endpoint:** Investigate if Gateway exposes metrics/health endpoints we should validate
4. **Resource Cleanup:** Determine if we need explicit Gateway cleanup or if Kubernetes GC handles it
5. **Test Duration:** Estimate runtime for bounded datasets (should be < 5 minutes per test ideally)
6. **Failure Scenarios:** Should we add explicit failure injection tests (Gateway pod restart, network partition)?

---

## References

- [CPC Gateway Documentation](https://docs.confluent.io/cloud/current/networking/private-link/private-cloud-gateway.html)
- [cp-flink-cmf Tests](https://github.com/confluentinc/cp-flink-cmf/tree/main/ci/e2e/tests)
- [Flink Exactly-Once Semantics](https://nightlies.apache.org/flink/flink-docs-release-1.20/docs/connectors/datastream/kafka/#kafka-producers-and-fault-tolerance)
- [Gateway Configuration](../gateway.yaml)
- [Gateway Services](../kafka-services.yaml)
- [CMF and Kafka Dependency Analysis](./CMF-KAFKA-DEPENDENCY-ANALYSIS.md) - **Critical reading for understanding CMF architecture**

---

## Version History

- **2026-03-13:** Initial strategy document
  - Happy path, stateful, live reconfig, blue/green tests defined
  - Contribution target: cp-flink-cmf upstream
  - Focus: Option C (continuous producer) for backend switching
