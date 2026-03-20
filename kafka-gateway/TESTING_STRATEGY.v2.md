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
├── gateway_happy_path/          # Basic Gateway validation
│   ├── run.sh
│   └── definitions/
│       ├── gateway.yaml
│       ├── gateway-services.yaml
│       └── fraud-detection.yaml
├── gateway_stateful/            # Stateful operations through Gateway
│   ├── run.sh
│   └── definitions/
│       ├── gateway.yaml
│       ├── gateway-services.yaml
│       └── stateful-app.yaml
├── gateway_live_reconfig/       # Live backend switching
│   ├── run.sh
│   └── definitions/
│       ├── kafka-cluster-2.yaml
│       ├── gateway.yaml
│       ├── gateway-services-kafka.yaml
│       ├── gateway-services-kafka2.yaml
│       ├── fraud-detection.yaml
│       └── stateful-transactional.yaml
└── gateway_blue_green/          # Blue/green cluster switching
    ├── run.sh
    └── definitions/
        ├── kafka-cluster-2.yaml
        ├── gateway-kafka.yaml
        ├── gateway-kafka2.yaml
        ├── gateway-services-kafka.yaml
        ├── gateway-services-kafka2.yaml
        ├── fraud-detection.yaml
        └── stateful-transactional.yaml
```

## Test Scenarios

### 1. Happy Path (`gateway_happy_path`)

**Purpose:** Validate basic Gateway functionality with simple Flink application.

**Application:**
- Based on `fraud-detection` pattern from `cmf_cli_base`
- Non-transactional, standard Flink job
- Bounded dataset for deterministic validation

**Infrastructure:**
- Single Kafka cluster (namespace: `kafka`)
- Gateway with port-based broker identification
- Gateway services for Kafka cluster

**Validation (Moderate):**
- ✅ Deployment reaches "running" state
- ✅ CLI proxy can connect to Flink job
- ✅ Job is active (jobs-running > 0)
- ✅ Checkpoint progress (successful checkpoints incrementing)
- ✅ Records processed (numRecordsIn/Out > 0)

**CMF Integration Validation:**
- ✅ CMF catalog operations work (list catalogs, describe catalog) - SQL-based, not Kafka-dependent
- ✅ Database operations succeed (list databases, query database metadata) - SQL-based
- ✅ KafkaDatabase configured with Gateway endpoint (`gateway-demo.kafka.svc.cluster.local:9092`)
- ✅ FlinkApplication receives correct bootstrap.servers from KafkaDatabase
- ✅ Flink job connects to Kafka **through Gateway** (not directly)
- ✅ No CMF errors in CMF operator logs

**Success Criteria:**
- Flink job runs successfully through Gateway
- Basic metrics validate data flow
- CMF can read/write metadata through Gateway transparently
- No errors in Gateway or Flink logs

---

### 2. Happier Path (`gateway_stateful`)

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
- ✅ All Happy Path validations
- ✅ State size increases (stateful operations working)
- ✅ Checkpoint completion (not just attempted)
- ✅ Recovery from checkpoint (restart job, verify state restored)
- ✅ Data correctness (consume N messages, produce N messages)

**CMF Integration Validation:**
- ✅ All Happy Path CMF validations
- ✅ Schema Registry operations (register schema, retrieve schema)
  - **Note:** SR stores schemas in `_schemas` Kafka topic - consider if SR should connect through Gateway
- ✅ CMF catalog/database definitions persist in CMF SQL database (not Kafka)
- ✅ Catalog/database metadata available across checkpoint/restore cycles
- ✅ Flink SQL catalog integration works (catalogs are CMF-managed, not Gateway-dependent)

**Success Criteria:**
- Stateful job runs successfully
- Checkpoints complete and can be used for recovery
- State persists correctly through Gateway
- CMF catalog/database operations remain consistent through job lifecycle

---

### 3. Live Reconfiguration (`gateway_live_reconfig`)

**Purpose:** Validate live backend switching from Kafka cluster 1 to cluster 2.

**Scenario:** Scenario A - Live reconfiguration of Gateway `streamingDomains`

**Applications:**
1. **Default App** (fraud-detection pattern)
   - Standard Flink semantics
   - Separate topics: `test-input-default`, `test-output-default`
   - Bounded dataset

2. **Transactional App** (stateful_flink pattern with EOS)
   - `execution.checkpointing.mode: EXACTLY_ONCE`
   - `sink.delivery-guarantee: exactly-once`
   - Kafka transactions enabled
   - Separate topics: `test-input-txn`, `test-output-txn`
   - Bounded dataset

**Infrastructure:**
- Two Kafka clusters:
  - Namespace `kafka` - Cluster 1 (initial backend)
  - Namespace `kafka2` - Cluster 2 (switch target)
- Single Gateway instance
- Gateway services in both namespaces:
  - `kafka-gateway-bootstrap.kafka.svc.cluster.local:9092`
  - `kafka-gateway-bootstrap.kafka2.svc.cluster.local:9092`

**Test Flow:**
1. Deploy both Kafka clusters
2. Deploy Gateway pointing to `kafka` cluster
3. Deploy both Flink applications
4. Start continuous data producer (produces to both input topics)
5. Validate both apps processing data
6. **Switch Gateway backend:** Update `streamingDomains` to point to `kafka2`
7. Continue producing data during switch
8. Validate post-switch behavior

**Validation:**

*Default App:*
- ✅ Job continues running (may restart from checkpoint)
- ✅ Records processing resumes on new cluster
- ✅ Some message loss acceptable
- ✅ No duplicate messages in output

*Transactional App:*
- ✅ In-flight transactions fail (expected during switch)
- ✅ New transactions succeed on kafka2 without intervention
- ✅ Zero duplicate messages in output (hard requirement)
- ✅ Transactions commit on cluster where they started
- ✅ Job recovers automatically

*CMF Integration:*
- ✅ **Key Insight:** CMF metadata is SQL-backed, NOT Kafka-backed
  - **Pre-switch:** KafkaDatabase points to `gateway-demo.kafka.svc.cluster.local:9092`
  - **During switch:** Gateway backend changes (kafka → kafka2), KafkaDatabase config UNCHANGED
  - **Post-switch:** Same KafkaDatabase, Gateway now routes to kafka2
- ✅ CMF catalog/database operations work after Gateway backend switch (SQL operations, unaffected)
- ⚠️ **Schema Registry consideration:** `_schemas` topic exists on kafka1
  - Option A: Migrate SR topics to kafka2 before switch (MirrorMaker2)
  - Option B: Reconfigure Schema Registry to use kafka2 (SR connects directly, not through Gateway)
  - Option C: Deploy separate SR per cluster (test this approach)
- ✅ FlinkEnvironment continues to work (references CMF REST API, not Kafka)
- ✅ Catalog visibility maintained (CMF SQL database unchanged)

**Success Criteria:**
- Both apps continue processing after switch
- Default app: some loss OK, zero duplication
- Transactional app: zero duplication guaranteed
- No manual intervention required for recovery
- CMF catalog/database operations continue working (SQL-backed, unaffected by Kafka switch)
- Schema availability on kafka2 validated (if using schema-aware apps)

---

### 4. Blue/Green Deployment (`gateway_blue_green`)

**Purpose:** Validate controlled cluster migration with parallel Gateway instances.

**Scenario:** Scenario C - Blue/green deployment with traffic cutover

**Applications:**
- Same as Live Reconfiguration (default + transactional)

**Infrastructure:**
- Two Kafka clusters:
  - Namespace `kafka` - Blue cluster
  - Namespace `kafka2` - Green cluster
- Two Gateway instances:
  - `gateway-kafka` pointing to `kafka` cluster
  - `gateway-kafka2` pointing to `kafka2` cluster
- Gateway services in both namespaces

**Test Flow:**
1. Deploy both Kafka clusters
2. Deploy both Gateway instances
3. Deploy Flink apps pointing to `gateway-kafka`
4. Start continuous data producer
5. Validate apps processing on blue cluster
6. **Cutover:** Update Flink apps to point to `gateway-kafka2`
7. Continue producing data during cutover
8. Validate post-cutover behavior
9. Decommission blue cluster and `gateway-kafka`

**Validation:**
- Same validation as Live Reconfiguration
- Additional: verify both Gateways work simultaneously during cutover

*CMF Integration (Blue/Green Specific):*
- ✅ Create two KafkaDatabase objects in CMF:
  - `blue-kafka-cluster`: `bootstrap.servers: gateway-kafka.kafka.svc.cluster.local:9092`
  - `green-kafka-cluster`: `bootstrap.servers: gateway-kafka2.kafka2.svc.cluster.local:9092`
- ✅ Both KafkaDatabase definitions stored in same CMF SQL database (single CMF instance)
- ✅ Schema Registry per cluster (separate SR instances or shared with replication)
- ✅ Both Gateways operational simultaneously during migration
- ✅ FlinkApplications updated to reference `green-kafka-cluster` database (application-level cutover)
- ✅ CMF catalog can contain both databases (no metadata migration needed)

**Success Criteria:**
- Clean cutover with expected data guarantees
- Both clusters/Gateways can run in parallel
- Applications switch cleanly between KafkaDatabase references (blue → green)
- CMF SQL database contains both KafkaDatabase definitions simultaneously
- No CMF metadata migration needed (SQL database unchanged)

---

## Future Test Cases (Documented, Not Implemented Initially)

### A. Pre-seeded Data Migration
- Pre-seed topics on both clusters
- Validate Gateway can read existing data from new cluster
- Test consumer offset migration

### B. Empty Target Cluster
- Second cluster starts empty
- Validate only new writes work after switch
- Simpler validation path

### C. Additional Scenarios
- Gateway failure/recovery
- Network partition between Gateway and Kafka
- Multi-tenant Gateway (multiple routes)
- External access via NodePort

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

```
CMF Operator (operator namespace)
  ├─ SQL Database (catalogs, databases, compute pools)
  │  └─ KafkaDatabase: stores "bootstrap.servers" config
  ├─ REST API (manages FlinkDeployments)
  └─ Kubernetes Controller (watches Flink CRDs)
      │
      └─ Creates FlinkDeployments with Kafka config from KafkaDatabase
              ↓
      FlinkApplication
              ↓
      Flink Job connects to Kafka using bootstrap.servers
              ↓
      Gateway (gateway-demo.kafka.svc.cluster.local:9092)
              ↓
      Kafka Cluster (kafka.kafka.svc.cluster.local:9071)
```

**Key Insight:** CMF itself never connects to Kafka. Only Flink jobs (managed by CMF) connect to Kafka.

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

### Known Considerations

- **CMF Metadata:** Stored in SQL database, not Kafka - no migration needed for backend switching
- **Schema Registry:** Schemas in `_schemas` Kafka topic - consider migration strategy or separate SR per cluster
- **KafkaDatabase Config:** Gateway endpoint stays constant (Scenario A) or multiple databases created (Scenario C)
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
cd ci/e2e/tests/gateway_happy_path
./run.sh

# Via test suite (if integrated)
./ci/e2e/run_tests.sh gateway_happy_path
./ci/e2e/run_tests.sh gateway_stateful
./ci/e2e/run_tests.sh gateway_live_reconfig
./ci/e2e/run_tests.sh gateway_blue_green
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

1. **Gateway Admin Endpoint:** Investigate if Gateway exposes metrics/health endpoints we should validate
2. **Schema Registry Routing Strategy:**
   - **Option A:** Schema Registry connects to Kafka through Gateway (consistency, single routing point)
   - **Option B:** Schema Registry connects directly to Kafka (independence, simpler Gateway config)
   - **Recommendation needed:** Which approach to test?
   - If Option B: How to handle SR during backend switching (migrate `_schemas` topic or separate SR per cluster)?
3. **Multiple KafkaDatabase Support:** Confirm CMF can reference multiple KafkaDatabases in same catalog (needed for blue/green)
4. **Schema Migration:** If using schema-aware applications, validate schema availability on kafka2 before switching
5. **Resource Cleanup:** Determine if we need explicit Gateway cleanup or if Kubernetes GC handles it
6. **Test Duration:** Estimate runtime for bounded datasets (should be < 5 minutes per test ideally)
7. **Failure Scenarios:** Should we add explicit failure injection tests (Gateway pod restart, network partition)?

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
