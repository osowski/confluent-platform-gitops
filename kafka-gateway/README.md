# Confluent Private Cloud Gateway

Internal cluster proxy for Kafka access.

## Deployment

```bash
# Apply in order
kubectl apply -f kafka-services.yaml
kubectl apply -f gateway.yaml
```

## Client Connection

**Bootstrap Server:**
```
gateway-demo.kafka.svc.cluster.local:9092
```

## Example Usage

```bash
# List topics through the Gateway
kafka-topics --list \
  --bootstrap-server gateway-demo.kafka.svc.cluster.local:9092

# Produce/consume messages
kafka-console-producer \
  --bootstrap-server gateway-demo.kafka.svc.cluster.local:9092 \
  --topic my-topic

kafka-console-consumer \
  --bootstrap-server gateway-demo.kafka.svc.cluster.local:9092 \
  --topic my-topic \
  --from-beginning
```

## Configuration

- **Image:** `confluentinc/cpc-gateway:1.1.2`
- **Backend Kafka:** `kafka.kafka.svc.cluster.local:9092`
- **Broker Strategy:** Port-based (no TLS required)
- **Access:** Internal cluster only
