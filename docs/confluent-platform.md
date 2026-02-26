# Confluent Platform Usage Guide

## Overview

This homelab deployment uses Confluent Platform managed by the Confluent for Kubernetes (CFK) operator. The platform runs in KRaft mode (no ZooKeeper) with minimal resource allocation suitable for homelab environments.

## Architecture

### Component Startup Ordering

CFK components are deployed within the `confluent-resources` application using ArgoCD sync-wave annotations to enforce the correct dependency chain:

```
KRaftController (wave 0) → Kafka (wave 10) → SchemaRegistry (wave 20) → ControlCenter (wave 30)
                                            → Connect (wave 20)       ↗
```

ArgoCD deploys each wave sequentially and waits for resources to report `status.state == "RUNNING"` (via custom Lua health checks in `argocd-cm`) before advancing to the next wave. This eliminates unnecessary retry loops and ensures components start in optimal order.

For the full sync-wave table and architectural decision, see [Architecture - Intra-Application Sync Waves](./architecture.md#intra-application-sync-waves-confluent-resources).

### Components

1. **cfk-operator** (wave 105)
   - Helm chart from https://packages.confluent.io/helm
   - Namespace-scoped operator managing Confluent Platform resources
   - Deployed to `confluent` namespace
   - Creates 22 CRDs in the `platform.confluent.io` API group

2. **confluent-resources** (wave 110)
   - KRaft Controller (metadata management, replaces ZooKeeper)
   - Kafka Broker (single broker for homelab)
   - Schema Registry (Avro schema management)

### Resource Allocation

| Component | Replicas | CPU | Memory | Storage |
|-----------|----------|-----|--------|---------|
| CFK Operator | 1 | 100m-500m | 128Mi-512Mi | - |
| KRaft Controller | 1 | 1000m | 2Gi | 10Gi |
| Kafka Broker | 1 | 2000m | 4Gi | 50Gi |
| Schema Registry | 1 | 500m | 1Gi | - |
| **Total** | - | ~4 CPU | ~8GB | 60GB |

## Accessing Kafka

### Internal Cluster Access

Kafka is accessible within the cluster at:
```
kafka.confluent.svc.cluster.local:9092
```

### kubectl Port-Forward

For local development or testing:
```bash
# Forward Kafka broker port
kubectl port-forward -n confluent kafka-0 9092:9092

# Forward Schema Registry port
kubectl port-forward -n confluent schemaregistry-0 8081:8081
```

### From a Pod

Use the internal DNS name and port 9092:
```yaml
env:
  - name: KAFKA_BOOTSTRAP_SERVERS
    value: "kafka.confluent.svc.cluster.local:9092"
```

## Common Operations

### Creating Topics

```bash
# Exec into Kafka pod
kubectl exec -it -n confluent kafka-0 -- bash

# Create a topic
kafka-topics \
  --create \
  --topic my-topic \
  --partitions 1 \
  --replication-factor 1 \
  --bootstrap-server localhost:9092

# List topics
kafka-topics --list --bootstrap-server localhost:9092

# Describe a topic
kafka-topics \
  --describe \
  --topic my-topic \
  --bootstrap-server localhost:9092

# Delete a topic
kafka-topics \
  --delete \
  --topic my-topic \
  --bootstrap-server localhost:9092
```

### Producing Messages

```bash
# Console producer
kubectl exec -it -n confluent kafka-0 -- \
  kafka-console-producer \
  --broker-list localhost:9092 \
  --topic my-topic
# Type messages and press Ctrl+D to exit

# Produce from a file
kubectl exec -i -n confluent kafka-0 -- \
  kafka-console-producer \
  --broker-list localhost:9092 \
  --topic my-topic < messages.txt
```

### Consuming Messages

```bash
# Console consumer (from beginning)
kubectl exec -it -n confluent kafka-0 -- \
  kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic my-topic \
  --from-beginning

# Consumer with group
kubectl exec -it -n confluent kafka-0 -- \
  kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic my-topic \
  --group my-consumer-group
```

### Managing Consumer Groups

```bash
# List consumer groups
kubectl exec -it -n confluent kafka-0 -- \
  kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --list

# Describe consumer group
kubectl exec -it -n confluent kafka-0 -- \
  kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --group my-consumer-group \
  --describe

# Reset consumer group offsets
kubectl exec -it -n confluent kafka-0 -- \
  kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --group my-consumer-group \
  --topic my-topic \
  --reset-offsets \
  --to-earliest \
  --execute
```

### Schema Registry Operations

```bash
# Port-forward Schema Registry
kubectl port-forward -n confluent schemaregistry-0 8081:8081

# List subjects (schemas)
curl http://localhost:8081/subjects

# Get schema for a subject
curl http://localhost:8081/subjects/my-topic-value/versions/latest

# Register a new schema
curl -X POST http://localhost:8081/subjects/my-topic-value/versions \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{
    "schema": "{\"type\":\"record\",\"name\":\"User\",\"fields\":[{\"name\":\"name\",\"type\":\"string\"},{\"name\":\"age\",\"type\":\"int\"}]}"
  }'
```

## Monitoring

### Check Component Health

```bash
# Get all Confluent resources
kubectl get kafka,kraftcontroller,schemaregistry -n confluent

# Check pod status
kubectl get pods -n confluent

# View pod logs
kubectl logs -n confluent kafka-0
kubectl logs -n confluent kraftcontroller-0
kubectl logs -n confluent schemaregistry-0

# Check PVCs
kubectl get pvc -n confluent
```

### Prometheus Integration

CFK components expose JMX metrics via the Prometheus JMX Exporter on port 7778. A `PodMonitor` resource automatically discovers and scrapes metrics from all running CFK pods.

#### PodMonitor Configuration

The `confluent-platform` PodMonitor is deployed alongside CFK resources in the `kafka` namespace:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: confluent-platform
  namespace: kafka
spec:
  jobLabel: platform.confluent.io/type
  podTargetLabels:
    - app
    - clusterId
    - platform.confluent.io/type
  podMetricsEndpoints:
    - port: prometheus
      interval: 60s
  selector:
    matchExpressions:
      - key: confluent-platform
        operator: Exists
```

**How it works:**
- **Selector**: Matches all pods with the `confluent-platform` label (automatically applied by CFK)
- **jobLabel**: Sets Prometheus `job` label per component type (e.g., `job="kafka"`, `job="schemaregistry"`) using the `platform.confluent.io/type` pod label
- **podTargetLabels**: Propagates pod labels into scraped metrics for dashboard filtering
- **Coverage**: Single `PodMonitor` covers all CFK components—Kafka, KRaft Controller, Schema Registry, Connect, Control Center

#### Verifying Metrics Collection

Check that Prometheus is scraping CFK metrics:

```bash
# Port-forward to Prometheus
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090

# Open Prometheus UI: http://localhost:9090
# Navigate to Status > Targets
# Look for targets with job labels: kafka, kraftcontroller, schemaregistry, connect, controlcenter
```

Query sample metrics in Prometheus:
```promql
# Kafka broker metrics
kafka_server_replicamanager_leadercount{job="kafka"}

# Schema Registry metrics
kafka_schema_registry_registered_count{job="schemaregistry"}

# Controller metrics
kafka_controller_kafkacontroller_activecontrollercount{job="kraftcontroller"}
```

#### Grafana Dashboards

Import Confluent Platform dashboards from the [confluentinc/jmx-monitoring-stacks](https://github.com/confluentinc/jmx-monitoring-stacks) repository:

- **Kafka Cluster**: Dashboard for broker health, throughput, partition metrics
- **Schema Registry**: Schema counts, request rates, error metrics
- **Connect**: Connector and task status, throughput

Dashboards filter on `job` label matching component type (e.g., `job="kafka"`), which aligns with the `jobLabel` configuration in the `PodMonitor`.

## Configuration

### Base Configuration

Located in `workloads/confluent-resources/base/`:
- `kraft-controller.yaml` - KRaft controller configuration
- `kafka-broker.yaml` - Kafka broker configuration with dependencies
- `schema-registry.yaml` - Schema Registry configuration

### Cluster-Specific Overrides

Located in `workloads/confluent-resources/overlays/flink-demo/`:
- `kustomization.yaml` - References base manifests
- `storage-patch.yaml` - Optional storage class overrides (commented out)

### Modifying Resources

To change resource allocations, edit the relevant YAML file in the base or overlay:

```yaml
spec:
  podTemplate:
    resources:
      requests:
        cpu: 2000m
        memory: 4Gi
      limits:
        cpu: 2000m
        memory: 4Gi
```

Commit changes to Git and ArgoCD will automatically sync.

## Troubleshooting

### Pods Not Starting

```bash
# Check pod events
kubectl describe pod -n confluent kafka-0

# Common issues:
# - Insufficient resources (check node capacity)
# - PVC binding failures (check storage class)
# - CRD not installed (check operator logs)
```

### CRDs Not Found

```bash
# Verify CRDs are installed
kubectl get crd | grep platform.confluent.io

# Should show 22 CRDs including:
# - kafkas.platform.confluent.io
# - kraftcontrollers.platform.confluent.io
# - schemaregistries.platform.confluent.io

# If missing, check operator deployment
kubectl get pods -n confluent
kubectl logs -n confluent -l app=cfk-operator
```

### Connection Refused Errors

- Ensure pods are running: `kubectl get pods -n confluent`
- Check service endpoints: `kubectl get svc -n confluent`
- Verify network policies aren't blocking traffic
- For KRaft dependency issues, ensure KRaft controller is ready before Kafka starts

### Storage Issues

```bash
# Check PVC status
kubectl get pvc -n confluent

# If PVC is pending:
# - Verify storage class exists: kubectl get storageclass
# - Check if storage provisioner is running (e.g., Longhorn)
# - Review PVC events: kubectl describe pvc <pvc-name> -n confluent
```

## Security Considerations

### Current State (Minimal Security)

- Authentication: `PLAIN` (no authentication)
- TLS: Disabled on all listeners
- Authorization: None configured

**This configuration is suitable for homelab development only.**

### Future Enhancements

For production-like deployments, consider:

1. **TLS/SSL**
   - Enable TLS on Kafka listeners
   - Integrate with cert-manager for certificate management
   - Configure Schema Registry with TLS

2. **Authentication**
   - Enable SASL/PLAIN or SASL/SCRAM authentication
   - Configure Kafka ACLs for authorization
   - Use Kubernetes secrets for credentials

3. **Network Policies**
   - Restrict pod-to-pod communication
   - Limit external access to specific namespaces

4. **Monitoring and Alerting**
   - Deploy Prometheus ServiceMonitors
   - Configure Grafana dashboards
   - Set up alerts for broker health, disk usage, lag

## Client Configuration Examples

### Java

```java
Properties props = new Properties();
props.put("bootstrap.servers", "kafka.confluent.svc.cluster.local:9092");
props.put("key.serializer", "org.apache.kafka.common.serialization.StringSerializer");
props.put("value.serializer", "org.apache.kafka.common.serialization.StringSerializer");
```

### Python (kafka-python)

```python
from kafka import KafkaProducer, KafkaConsumer

producer = KafkaProducer(
    bootstrap_servers=['kafka.confluent.svc.cluster.local:9092']
)

consumer = KafkaConsumer(
    'my-topic',
    bootstrap_servers=['kafka.confluent.svc.cluster.local:9092'],
    group_id='my-group'
)
```

### Go (confluent-kafka-go)

```go
import "github.com/confluentinc/confluent-kafka-go/kafka"

producer, err := kafka.NewProducer(&kafka.ConfigMap{
    "bootstrap.servers": "kafka.confluent.svc.cluster.local:9092",
})
```

## Additional Resources

- [Confluent for Kubernetes Documentation](https://docs.confluent.io/operator/current/overview.html)
- [Apache Kafka Documentation](https://kafka.apache.org/documentation/)
- [Confluent Platform Documentation](https://docs.confluent.io/platform/current/overview.html)
- [KRaft Mode Documentation](https://docs.confluent.io/platform/current/kafka-metadata/kraft.html)

## Related Documentation

- [Architecture](./architecture.md) - Sync wave strategy and RBAC configuration
- [Adding Applications](./adding-applications.md) - How to deploy applications that consume Kafka
- [Changelog](./changelog.md) - Version history and changes
