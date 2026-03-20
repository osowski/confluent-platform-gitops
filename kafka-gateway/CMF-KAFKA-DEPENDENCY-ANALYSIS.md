# CMF and Kafka Dependency Analysis

## Executive Summary

**Critical Finding:** CMF (Confluent Manager for Apache Flink) **does NOT store its metadata in Kafka**. CMF uses a SQL database backend (SQLite/PostgreSQL/SQL Server) for its own metadata storage.

**Gateway Routing Concern:** Only Flink applications should connect through the Gateway. CMF itself does not need Gateway access.

---

## CMF Architecture

### CMF Components

```
┌─────────────────────────────────────────────────────────────┐
│                       CMF Operator                          │
│  ┌────────────────────┐      ┌────────────────────────┐    │
│  │   REST API         │      │  Kubernetes Controller │    │
│  │   (port 8080)      │      │  (watches CRDs)        │    │
│  └────────┬───────────┘      └───────────┬────────────┘    │
│           │                               │                 │
│           └───────────┬───────────────────┘                 │
│                       │                                      │
│           ┌───────────▼───────────┐                         │
│           │   SQL Database        │                         │
│           │  (SQLite/PG/MSSQL)    │                         │
│           │  - Catalogs metadata  │                         │
│           │  - Databases metadata │                         │
│           │  - Compute Pools      │                         │
│           │  - Application defs   │                         │
│           └───────────────────────┘                         │
└─────────────────────────────────────────────────────────────┘
                       │
                       │ Creates/Manages
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                  Flink Applications                         │
│  ┌──────────────────────────────────────────────────┐      │
│  │  FlinkDeployment (Kubernetes CRD)                │      │
│  │  ┌────────────────────────────────────────────┐  │      │
│  │  │  Flink Job                                 │  │      │
│  │  │  - Reads/writes Kafka via connection from  │  │      │
│  │  │    KafkaDatabase config                    │  │      │
│  │  │  - Uses Schema Registry from KafkaCatalog │  │      │
│  │  └────────────────────────────────────────────┘  │      │
│  └──────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────┘
                       │
                       │ Connects to
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                   Kafka Cluster                             │
│  - Topics for application data                              │
│  - Schema Registry (_schemas topic)                         │
│  - NO CMF metadata topics                                   │
└─────────────────────────────────────────────────────────────┘
```

### CMF Metadata Storage

**From cp-flink-cmf test infrastructure (`ci/e2e/includes/utils.sh`):**

```bash
function configure_cmf_helm_values_for_db() {
  if [[ "${CMF_DATABASE_TYPE:-sqlite}" == "postgresql" ]]; then
    # CMF uses PostgreSQL
  elif [[ "${CMF_DATABASE_TYPE:-sqlite}" == "sqlserver" ]]; then
    # CMF uses SQL Server
  else
    # CMF uses SQLite (default, embedded)
  fi
}
```

**Key Insight:** CMF stores catalogs, databases, compute pools, and application definitions in a SQL database, **NOT in Kafka topics**.

---

## CMF to Kafka Connection Points

### 1. KafkaCatalog (CMF Concept)

**Definition:** Metadata pointer to Schema Registry

```yaml
apiVersion: cmf.confluent.io/v1
kind: KafkaCatalog
metadata:
  name: kafka-cat
spec:
  srInstance:
    connectionConfig:
      schema.registry.url: "http://schemaregistry.kafka.svc.cluster.local:8081"
```

- **Stored where:** CMF SQL database
- **Purpose:** Tells CMF where to find Schema Registry for schema operations
- **Direct Kafka dependency:** No (Schema Registry is separate service)
- **Gateway involvement:** No - CMF just stores this URL in its database

### 2. KafkaDatabase (CMF Concept)

**Definition:** Metadata pointer to Kafka cluster bootstrap servers

```yaml
apiVersion: cmf.confluent.io/v1
kind: KafkaDatabase
metadata:
  name: main-kafka-cluster
spec:
  kafkaCluster:
    connectionConfig:
      bootstrap.servers: "kafka.kafka.svc.cluster.local:9071"
```

- **Stored where:** CMF SQL database
- **Purpose:** Tells Flink applications where to connect for Kafka operations
- **Direct Kafka dependency:** No - CMF just stores this configuration
- **Gateway involvement:** **YES - This is where Flink apps get Kafka endpoint**

### 3. FlinkEnvironment (Kubernetes CRD)

**From local deployment (`flink-resources/base/flink-environment.yaml`):**

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: FlinkEnvironment
metadata:
  name: default-flink-env
  namespace: flink
spec:
  kubernetesNamespace: flink
  cmfRestClassRef:
    name: cmf-rest-class
    namespace: flink
  # NOTE: No direct Kafka reference here
```

- **Purpose:** Links Flink namespace to CMF REST API
- **Direct Kafka dependency:** No
- **Gateway involvement:** No

### 4. CMFRestClass (Kubernetes CRD)

**From local deployment (`flink-resources/base/cmfrestclass.yaml`):**

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: CMFRestClass
metadata:
  name: cmf-rest-class
  namespace: flink
spec:
  cmfRest:
    endpoint: http://cmf-service.operator.svc.cluster.local:80
```

- **Purpose:** Tells Flink CRDs where to find CMF REST API
- **Direct Kafka dependency:** No
- **Gateway involvement:** No

---

## Data Flow: Where Does Kafka Get Involved?

### FlinkApplication Deployment Flow

```
1. User creates FlinkApplication CRD
   ├─ References FlinkEnvironment
   └─ FlinkEnvironment references CMFRestClass

2. CMF controller sees FlinkApplication
   ├─ Reads app spec from SQL database
   └─ Creates FlinkDeployment (native Flink CRD)

3. FlinkDeployment includes Kafka connection config
   ├─ bootstrap.servers from KafkaDatabase
   └─ schema.registry.url from KafkaCatalog

4. Flink Job Manager starts
   ├─ Job code executes
   └─ Kafka connector uses bootstrap.servers to connect
       └─ **THIS IS WHERE GATEWAY SHOULD BE USED**
```

**Critical Point:** CMF never connects to Kafka directly. Only Flink jobs connect to Kafka.

---

## Gateway Deployment Implications

### Scenario 1: Current Local Deployment (No Gateway)

```
CMF (operator namespace)
  ├─ SQL Database: Stores KafkaDatabase with bootstrap.servers="kafka.kafka.svc.cluster.local:9071"
  └─ Creates FlinkDeployments with this bootstrap endpoint

Flink Job
  ├─ Reads bootstrap.servers from FlinkDeployment spec
  └─ Connects directly to Kafka: kafka.kafka.svc.cluster.local:9071
```

### Scenario 2: With Gateway (Recommended Approach)

```
CMF (operator namespace)
  ├─ SQL Database: Stores KafkaDatabase with bootstrap.servers="gateway-demo.kafka.svc.cluster.local:9092"
  └─ Creates FlinkDeployments with Gateway endpoint

Flink Job
  ├─ Reads bootstrap.servers from FlinkDeployment spec
  └─ Connects to Gateway: gateway-demo.kafka.svc.cluster.local:9092
      └─ Gateway proxies to: kafka.kafka.svc.cluster.local:9071 (internal listener)
```

**Key Decision:** KafkaDatabase `bootstrap.servers` should point to **Gateway endpoint**, not direct Kafka.

### Scenario 3: CMF Connecting to Kafka Directly? (NOT RECOMMENDED)

```
CMF (operator namespace)
  ├─ SQL Database metadata
  └─ Does CMF itself need Kafka access?
      └─ **Answer: NO**
          ├─ CMF doesn't read/write Kafka topics for its metadata
          ├─ CMF doesn't validate Kafka connectivity when creating KafkaDatabase
          └─ Kafka connection is only used by Flink jobs
```

---

## Backend Switching Implications

### Scenario A: Live Reconfiguration

**What happens to CMF metadata?**

```
Initial State (Kafka Cluster 1):
  CMF Database:
    - KafkaDatabase "main-kafka-cluster"
      - bootstrap.servers: "gateway-demo.kafka.svc.cluster.local:9092"
    - Gateway backend: kafka.kafka.svc.cluster.local:9071

Switch Gateway Backend to Kafka Cluster 2:
  1. Update Gateway streamingDomains to point to kafka2.kafka2.svc.cluster.local:9071
  2. CMF metadata UNCHANGED (still points to gateway-demo endpoint)
  3. Flink jobs continue using gateway-demo endpoint
  4. Gateway now routes to kafka2 cluster

Result:
  ✅ CMF metadata does NOT need migration
  ✅ KafkaDatabase config remains valid
  ❌ BUT: Existing data on kafka1 is not accessible
  ❌ Schema Registry needs consideration (separate migration)
```

### Scenario C: Blue/Green Deployment

**What happens to CMF metadata?**

```
Blue Cluster (Kafka 1):
  CMF Database:
    - KafkaDatabase "blue-kafka-cluster"
      - bootstrap.servers: "gateway-kafka.kafka.svc.cluster.local:9092"
  Gateway: gateway-kafka → kafka.kafka.svc.cluster.local:9071

Green Cluster (Kafka 2):
  CMF Database (SAME CMF instance):
    - KafkaDatabase "green-kafka-cluster"  ← NEW database definition
      - bootstrap.servers: "gateway-kafka2.kafka2.svc.cluster.local:9092"
  Gateway: gateway-kafka2 → kafka.kafka2.svc.cluster.local:9071

Migration:
  1. Create new KafkaDatabase pointing to gateway-kafka2
  2. Update FlinkApplications to use green-kafka-cluster database
  3. Redeploy Flink jobs
  4. Jobs now connect to gateway-kafka2 → kafka2

Result:
  ✅ CMF metadata can reference BOTH clusters simultaneously
  ✅ Gradual migration possible (blue and green coexist)
  ✅ No CMF metadata migration needed
  ✅ Schema Registry can be separate per cluster
```

---

## Recommendations

### 1. CMF Deployment Location

**Current:** CMF in `operator` namespace

**Recommendation:** ✅ **Keep CMF in `operator` namespace**

**Rationale:**
- CMF is cluster-scoped operator, not tied to specific Kafka cluster
- CMF SQL database is independent of Kafka
- CMF can manage Flink applications across multiple Kafka clusters

### 2. CMF Should NOT Use Gateway

**CMF itself does not need Gateway access.**

**What CMF needs:**
- ✅ Kubernetes API access (to create FlinkDeployments)
- ✅ SQL database (SQLite/PostgreSQL/SQL Server)
- ✅ CMF REST API endpoint (for FlinkEnvironments to reference)
- ❌ NO direct Kafka access required

### 3. Flink Applications SHOULD Use Gateway

**KafkaDatabase configuration should point to Gateway:**

```yaml
apiVersion: cmf.confluent.io/v1
kind: KafkaDatabase
metadata:
  name: main-kafka-cluster
spec:
  kafkaCluster:
    connectionConfig:
      # Point to Gateway, not direct Kafka
      bootstrap.servers: "gateway-demo.kafka.svc.cluster.local:9092"
```

**Why:**
- Flink jobs connect to Kafka through this endpoint
- Gateway provides abstraction layer for backend switching
- Multiple KafkaDatabases can point to different Gateways (blue/green)

### 4. Schema Registry Considerations

**Schema Registry has its own Kafka dependency:**

```
Schema Registry
  ├─ Stores schemas in _schemas Kafka topic
  └─ Connects to Kafka cluster

Question: Should Schema Registry connect through Gateway?
  Option A: Yes - SR goes through Gateway for consistency
    ✅ Single point of management
    ❌ Gateway becomes critical for schema operations

  Option B: No - SR connects directly to Kafka
    ✅ Independent from Gateway
    ❌ Must be reconfigured during backend switch
```

**Recommendation for testing:** Start with **Option B** (SR direct to Kafka) for simplicity.

---

## Testing Strategy Updates

### Gateway Tests Should Validate

1. **Happy Path:**
   - ✅ Create KafkaDatabase with Gateway endpoint
   - ✅ FlinkApplication uses this database
   - ✅ Flink job connects through Gateway successfully

2. **Stateful:**
   - ✅ Checkpoints work through Gateway
   - ✅ Schema Registry operations (direct to Kafka, not through Gateway initially)

3. **Live Reconfiguration:**
   - ✅ Update Gateway backend (kafka → kafka2)
   - ✅ KafkaDatabase config unchanged (still points to same Gateway endpoint)
   - ✅ Flink jobs automatically use new backend
   - ⚠️ Schema Registry needs separate handling

4. **Blue/Green:**
   - ✅ Two KafkaDatabase definitions (blue-kafka-cluster, green-kafka-cluster)
   - ✅ Each points to different Gateway (gateway-kafka, gateway-kafka2)
   - ✅ Migrate FlinkApplications from blue to green database
   - ✅ Both clusters operational during migration

### CMF-Specific Validations

**Do NOT test:**
- ❌ CMF connecting through Gateway (CMF doesn't connect to Kafka)
- ❌ CMF metadata stored in Kafka (it's in SQL database)

**DO test:**
- ✅ KafkaDatabase creation with Gateway endpoint
- ✅ FlinkApplication deployment using Gateway-backed database
- ✅ CMF catalog operations (list catalogs, databases) - these are SQL operations, not Kafka
- ✅ Schema Registry operations if SR is configured through Gateway

---

## Open Questions

1. **Schema Registry Gateway Routing:**
   - Should Schema Registry connect to Kafka through Gateway or directly?
   - If through Gateway: requires separate Gateway route for SR
   - If directly: SR must be reconfigured during backend switch

2. **Multiple KafkaDatabase Support:**
   - Can CMF reference multiple KafkaDatabases in same catalog?
   - Needed for blue/green scenario

3. **CMF Catalog Migration:**
   - If using different Schema Registry per cluster, how to handle catalog metadata?
   - Are catalogs cluster-specific or global?

4. **Gateway HA Considerations:**
   - If Gateway fails, all Flink jobs lose Kafka access
   - Need Gateway deployment strategy (replicas, anti-affinity, etc.)

---

## Conclusion

**CMF and Kafka are decoupled:**
- CMF stores metadata in SQL database
- CMF creates KafkaDatabase objects with Kafka endpoint configuration
- Flink jobs (managed by CMF) connect to Kafka using this configuration
- **Gateway should only be used by Flink jobs, not CMF itself**

**For backend switching:**
- Scenario A (live reconfig): Gateway backend changes, KafkaDatabase stays same
- Scenario C (blue/green): Multiple KafkaDatabases, each with different Gateway endpoint

**Testing implications:**
- Focus on Flink job connectivity through Gateway
- CMF operations (create catalog, database) are independent of Gateway
- Schema Registry needs explicit handling in test strategy

---

## References

- cp-flink-cmf: `ci/e2e/includes/install_and_start_cmf.sh`
- cp-flink-cmf: `ci/e2e/includes/utils.sh` (database configuration)
- Local deployment: `workloads/cmf-operator/base/values.yaml`
- Local deployment: `workloads/cp-flink-sql-sandbox/base/cmf-config-configmap.yaml`
- CMF CRDs: FlinkEnvironment, CMFRestClass, KafkaCatalog, KafkaDatabase
