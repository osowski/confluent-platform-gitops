# Confluent Platform for Apache Flink

## Overview

This deployment provides Apache Flink stream processing capabilities integrated with the existing Confluent Platform deployment. Flink enables complex, stateful, low-latency streaming applications with exactly-once processing semantics.

## Architecture

### Components

The Flink deployment consists of three ArgoCD Applications:

1. **flink-kubernetes-operator** (sync-wave 116)
   - Manages Flink deployments and jobs on Kubernetes
   - Helm chart: `confluentinc/flink-kubernetes-operator` v1.130.0
   - Resources: 2 CPU, 3 GB RAM
   - Namespace: `confluent`

2. **cmf-operator** (sync-wave 118)
   - Confluent Manager for Apache Flink (CMF)
   - Central management interface for Flink applications
   - Helm chart: `confluentinc/confluent-manager-for-apache-flink` v2.1.0
   - Resources: 2 CPU, 1 GB RAM, 10 GB storage (PVC)
   - Database: SQLite with persistent volume
   - License: Trial license auto-generated

3. **flink-resources** (sync-wave 120)
   - Custom resources for Flink integration
   - CMFRestClass: Communication bridge between CFK and CMF
   - FlinkEnvironment: Default settings and Kafka integration
   - Kustomize-based deployment

### Integration with Confluent Platform

Flink integrates with the existing Confluent Platform components:

- **Kafka Broker**: `kafka.confluent.svc.cluster.local:9092`
  - Source and sink for Flink streaming jobs
  - Bootstrap servers configured in FlinkEnvironment

- **Schema Registry**: `http://schemaregistry.confluent.svc.cluster.local:8081`
  - Schema management for Kafka topics
  - Avro serialization/deserialization

- **Control Center**: Monitoring and management
  - View Kafka topics and consumer groups
  - Monitor Flink job metrics (via Kafka integration)

### Deployment Order

Sync waves ensure proper dependency ordering:

```
105: cfk-operator (CFK operator)
110: confluent-resources (Kafka, Schema Registry, etc.)
115: controlcenter-ingress
116: flink-kubernetes-operator (Flink operator)
118: cmf-operator (CMF management)
120: flink-resources (Integration resources)
```

## Resource Requirements

Total estimated resources for Flink deployment:

| Component | CPU | Memory | Storage |
|-----------|-----|--------|---------|
| Flink Kubernetes Operator | 2 | 3 GB | - |
| CMF Operator | 2 | 1 GB | 10 GB (PVC) |
| FlinkEnvironment defaults | 1 per component | 1 GB per component | - |
| **Total (operators only)** | **4 CPU** | **4 GB** | **10 GB** |

**Note**: Actual Flink job resources depend on FlinkApplication definitions. Each job creates JobManager and TaskManager pods with configurable resources.

## Configuration

### FlinkEnvironment

Default configuration in `workloads/flink-resources/base/flink-environment.yaml`:

```yaml
spec:
  # Kafka integration
  kafkaCluster:
    bootstrapServers: kafka.confluent.svc.cluster.local:9092

  # Schema Registry integration
  schemaRegistry:
    url: http://schemaregistry.confluent.svc.cluster.local:8081

  # Default resources (conservative for homelab)
  flinkConfiguration:
    jobmanager.memory.process.size: "1024m"
    jobmanager.cpu: "1.0"
    taskmanager.memory.process.size: "1024m"
    taskmanager.cpu: "1.0"
    taskmanager.numberOfTaskSlots: "2"

    # Checkpointing
    state.backend: rocksdb
    state.checkpoints.dir: "file:///tmp/flink-checkpoints"
    execution.checkpointing.interval: "60s"
    execution.checkpointing.mode: "EXACTLY_ONCE"
```

### Customization

To customize Flink settings for a specific cluster:

1. Create cluster overlay: `workloads/flink-resources/overlays/<cluster>/`
2. Add patch file: `flink-environment-patch.yaml`
3. Update `kustomization.yaml` to apply the patch

Example patch for increased resources:

```yaml
apiVersion: flink.confluent.io/v1beta1
kind: FlinkEnvironment
metadata:
  name: default-flink-env
  namespace: confluent
spec:
  flinkConfiguration:
    jobmanager.memory.process.size: "2048m"
    taskmanager.memory.process.size: "2048m"
    taskmanager.numberOfTaskSlots: "4"
```

## Usage

### Deploying Flink Applications

Create a FlinkApplication custom resource:

```yaml
apiVersion: flink.confluent.io/v1beta1
kind: FlinkApplication
metadata:
  name: my-flink-job
  namespace: confluent
spec:
  # Reference the default environment
  flinkEnvironmentRef:
    name: default-flink-env
    namespace: confluent

  # Application JAR location
  job:
    jarURI: "local:///opt/flink/examples/streaming/StateMachineExample.jar"
    parallelism: 2
    upgradeMode: stateless

  # Override resources if needed
  flinkConfiguration:
    taskmanager.numberOfTaskSlots: "2"

  # JobManager configuration
  jobManager:
    resource:
      memory: "1048m"
      cpu: 1

  # TaskManager configuration
  taskManager:
    resource:
      memory: "1048m"
      cpu: 1
```

### Flink SQL

Flink SQL provides a SQL interface for stream processing:

```sql
-- Create a table from Kafka topic
CREATE TABLE orders (
  order_id STRING,
  product_id STRING,
  quantity INT,
  price DECIMAL(10, 2),
  order_time TIMESTAMP(3)
) WITH (
  'connector' = 'kafka',
  'topic' = 'orders',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9092',
  'format' = 'avro-confluent',
  'avro-confluent.url' = 'http://schemaregistry.confluent.svc.cluster.local:8081'
);

-- Aggregate and write to another topic
CREATE TABLE order_totals (
  product_id STRING,
  total_quantity INT,
  total_revenue DECIMAL(10, 2)
) WITH (
  'connector' = 'kafka',
  'topic' = 'order-totals',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9092',
  'format' = 'avro-confluent',
  'avro-confluent.url' = 'http://schemaregistry.confluent.svc.cluster.local:8081'
);

-- Execute streaming query
INSERT INTO order_totals
SELECT
  product_id,
  SUM(quantity) as total_quantity,
  SUM(quantity * price) as total_revenue
FROM orders
GROUP BY product_id;
```

## Monitoring

### Prometheus / Grafana (ServiceMonitor)

Flink pod metrics are scraped by Prometheus via a `ServiceMonitor` and a headless `Service` defined in `workloads/flink-resources/base/`:

| File | Purpose |
|------|---------|
| `service.yaml` | Exposes Flink pods on port 9249 (`metrics`), selected by `type: flink-native-kubernetes` |
| `servicemonitor.yaml` | Configures Prometheus scraping; sets `job="flink"` via `relabelings` |
| `grafana-dashboard.yaml` | ConfigMap with embedded Grafana dashboard; loaded automatically via `grafana_dashboard: "1"` label |

#### Label conventions

The `ServiceMonitor` uses a `relabelings` entry to hardcode `job="flink"` on all scraped metrics. This intentionally aligns with the label convention used by the upstream [confluentinc/jmx-monitoring-stacks](https://github.com/confluentinc/jmx-monitoring-stacks) Flink dashboards (`flink-jobmanager.json`, `flink-taskmanager.json`), which filter on `job="flink"` in every PromQL expression.

Pod labels (`app`, `component`, `type`, `platform.confluent.io/origin`) are propagated to metrics via `podTargetLabels`. The `app` label is used in dashboard variable queries as the environment selector (`app="$env"`).

> **Note**: If you import the upstream jmx-monitoring-stacks dashboards directly, their `env` label variable queries must be updated to use `app` instead, as this stack does not add an `env` label to scraped metrics.

#### Operator metrics

The Flink Kubernetes Operator itself is monitored via a separate `PodMonitor` defined in `workloads/flink-kubernetes-operator/podmonitor-operator.yaml`, targeting pods with `app.kubernetes.io/name: flink-kubernetes-operator`.

### CMF UI (Future)

CMF provides a web interface for managing Flink applications:

- Create and manage Flink deployments
- Submit SQL queries
- Monitor job status and metrics
- View logs and checkpoints

**Note**: Ingress for CMF UI can be added following the pattern in `workloads/controlcenter-ingress/`.

### Kubernetes Resources

Monitor Flink pods:

```bash
# View Flink operator pods
kubectl get pods -n confluent -l app.kubernetes.io/name=flink-kubernetes-operator

# View CMF pods
kubectl get pods -n confluent -l app.kubernetes.io/name=cmf

# View Flink application pods
kubectl get pods -n confluent -l type=flink-native-kubernetes

# Check Flink custom resources
kubectl get flinkdeployment -n confluent
kubectl get flinkapplication -n confluent
```

### Logs

```bash
# Flink Kubernetes Operator logs
kubectl logs -n confluent -l app.kubernetes.io/name=flink-kubernetes-operator

# CMF logs
kubectl logs -n confluent -l app.kubernetes.io/name=cmf

# Flink JobManager logs
kubectl logs -n confluent <jobmanager-pod-name>

# Flink TaskManager logs
kubectl logs -n confluent <taskmanager-pod-name>
```

## Troubleshooting

### Operator Issues

**Problem**: Flink Kubernetes Operator not starting

**Solution**:
1. Check operator logs: `kubectl logs -n confluent -l app.kubernetes.io/name=flink-kubernetes-operator`
2. Verify RBAC permissions: `kubectl auth can-i create flinkdeployment --as=system:serviceaccount:confluent:flink-kubernetes-operator -n confluent`
3. Check CRDs installed: `kubectl get crd | grep flink`

### CMF Issues

**Problem**: CMF pod in CrashLoopBackOff

**Solution**:
1. Check logs: `kubectl logs -n confluent -l app.kubernetes.io/name=cmf`
2. Verify PVC bound: `kubectl get pvc -n confluent`
3. Check storage class available: `kubectl get storageclass`

### FlinkApplication Issues

**Problem**: FlinkApplication not creating pods

**Solution**:
1. Check FlinkApplication status: `kubectl describe flinkapplication <name> -n confluent`
2. Verify FlinkEnvironment exists: `kubectl get flinkenvironment -n confluent`
3. Check CMFRestClass configured: `kubectl get cmfrestclass -n confluent`
4. Verify Kafka connectivity from a test pod

### Kafka Connection Issues

**Problem**: Flink jobs cannot connect to Kafka

**Solution**:
1. Verify Kafka broker running: `kubectl get kafka -n confluent`
2. Test connectivity:
   ```bash
   kubectl run -it --rm kafka-test --image=confluentinc/cp-kafka:8.1.0 --restart=Never -- \
     kafka-broker-api-versions --bootstrap-server kafka.confluent.svc.cluster.local:9092
   ```
3. Check FlinkEnvironment Kafka configuration
4. Verify network policies allow traffic

## Security Considerations

### Authentication

Current deployment uses:
- **CMF to CFK**: No authentication (internal cluster traffic)
- **Flink to Kafka**: PLAINTEXT (no authentication)

**Future enhancements**:
- Enable mTLS for CMF to CFK communication
- Configure SASL/PLAIN or mTLS for Kafka authentication
- Add Schema Registry authentication

### Network Policies

Consider adding NetworkPolicies to restrict:
- Flink operator to Kubernetes API
- CMF to Kafka brokers
- Flink jobs to Kafka and Schema Registry
- External access to CMF UI

### Secrets Management

Sensitive configuration should use Kubernetes Secrets:
- Kafka authentication credentials
- Schema Registry credentials
- CMF license keys (production)
- Database encryption keys (production)

## Next Steps

1. **Deploy sample application**: Create a simple FlinkApplication to validate the setup
2. **Enable authentication**: Configure Kafka security (SASL/PLAIN or mTLS)
3. **Tune resources**: Adjust memory and CPU based on workload requirements
4. **Add to flink-demo cluster**: Replicate configuration for flink-demo cluster

## References

- [Confluent for Flink Documentation](https://docs.confluent.io/platform/current/flink/overview.html)
- [Manage Flink with CFK](https://docs.confluent.io/operator/current/co-manage-flink.html)
- [Flink Kubernetes Operator](https://nightlies.apache.org/flink/flink-kubernetes-operator-docs-main/)
- [CMF Installation Guide](https://docs.confluent.io/platform/current/flink/installation/helm.html)
- [Flink SQL Reference](https://docs.confluent.io/platform/current/flink/reference/sql-reference.html)
- [confluentinc/jmx-monitoring-stacks](https://github.com/confluentinc/jmx-monitoring-stacks) — upstream Flink Grafana dashboards this stack aligns with
