# Testing kube-prometheus-stack Implementation

This guide provides commands to test and validate the kube-prometheus-stack implementation before deploying to a cluster.

## Pre-Deployment Testing

### 1. Add Helm Repository

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### 2. Verify Chart Version Exists

```bash
helm search repo prometheus-community/kube-prometheus-stack --version 56.6.2
```

Expected output:
```
NAME                                          CHART VERSION  APP VERSION  DESCRIPTION
prometheus-community/kube-prometheus-stack    56.6.2         v0.71.2      kube-prometheus-stack collects Kubernetes manif...
```

### 3. View Default Chart Values

```bash
helm show values prometheus-community/kube-prometheus-stack --version 56.6.2 | less
```

### 4. Test Helm Template Rendering

#### Render with Base Values Only

```bash
helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 56.6.2 \
  --namespace monitoring \
  --values infrastructure/kube-prometheus-stack/base/values.yaml \
  > /tmp/kube-prometheus-stack-base.yaml

# Check for errors
echo "Exit code: $?"
wc -l /tmp/kube-prometheus-stack-base.yaml
```

#### Render with Base + Portcullis Overlay

```bash
helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 56.6.2 \
  --namespace monitoring \
  --values infrastructure/kube-prometheus-stack/base/values.yaml \
  --values infrastructure/kube-prometheus-stack/overlays/portcullis/values.yaml \
  > /tmp/kube-prometheus-stack-portcullis.yaml

# Check for errors
echo "Exit code: $?"
wc -l /tmp/kube-prometheus-stack-portcullis.yaml
```

#### Compare Base vs Overlay Output

```bash
# See what the overlay changes
diff /tmp/kube-prometheus-stack-base.yaml /tmp/kube-prometheus-stack-portcullis.yaml | grep -A 5 -B 5 "storageClassName\|ingress\|host"
```

### 5. Validate Kubernetes Manifests

```bash
# Dry-run apply to validate manifests
kubectl apply --dry-run=client -f /tmp/kube-prometheus-stack-portcullis.yaml
```

### 6. Check for Required Resources

```bash
# Count each resource type
echo "Resource counts:"
grep "^kind:" /tmp/kube-prometheus-stack-portcullis.yaml | sort | uniq -c
```

Expected resources:
- ServiceAccount
- ClusterRole
- ClusterRoleBinding
- Role
- RoleBinding
- ConfigMap
- Secret
- Service
- Deployment
- DaemonSet
- StatefulSet
- ServiceMonitor
- PrometheusRule
- Prometheus
- Alertmanager
- Ingress
- PersistentVolumeClaim (via StatefulSet)

### 7. Validate ArgoCD Application Manifest

```bash
# Validate Application CRD
kubectl apply --dry-run=client -f clusters/portcullis/infrastructure/kube-prometheus-stack.yaml

# Check if Application is well-formed
kubectl apply --dry-run=server -f clusters/portcullis/infrastructure/kube-prometheus-stack.yaml 2>&1
```

### 8. Check Value File Syntax

```bash
# Validate YAML syntax
yamllint infrastructure/kube-prometheus-stack/base/values.yaml
yamllint infrastructure/kube-prometheus-stack/overlays/portcullis/values.yaml

# Or use yq if installed
yq eval '.' infrastructure/kube-prometheus-stack/base/values.yaml > /dev/null && echo "✓ Base values valid"
yq eval '.' infrastructure/kube-prometheus-stack/overlays/portcullis/values.yaml > /dev/null && echo "✓ Overlay values valid"
```

### 9. Test Raw GitHub URLs

```bash
# Verify value files are accessible via raw GitHub URLs
# (Requires files to be committed and pushed)

curl -fsSL https://raw.githubusercontent.com/osowski/homelab-argocd/HEAD/infrastructure/kube-prometheus-stack/base/values.yaml

curl -fsSL https://raw.githubusercontent.com/osowski/homelab-argocd/HEAD/infrastructure/kube-prometheus-stack/overlays/portcullis/values.yaml
```

### 10. Check Resource Requirements

```bash
# Calculate total resource requests
grep -A 2 "requests:" /tmp/kube-prometheus-stack-portcullis.yaml | grep -E "cpu|memory" | \
  awk '{print $2}' | sed 's/"//g'

# Estimate total:
# - Prometheus: 1000m CPU, 2Gi memory
# - Grafana: 200m CPU, 256Mi memory
# - Alertmanager: 100m CPU, 128Mi memory
# - Prometheus Operator: 100m CPU, 128Mi memory
# - Node Exporter: 50m CPU per node, 64Mi memory per node
# - Kube State Metrics: 50m CPU, 64Mi memory
# Total: ~1.5-2 CPU cores, 3-4Gi memory (excluding Node Exporter on multiple nodes)
```

## Post-Deployment Testing

These tests require the application to be deployed to a cluster.

### 1. Monitor ArgoCD Sync

```bash
# Watch Application sync progress
watch -n 5 kubectl get application kube-prometheus-stack -n argocd

# View detailed sync status
kubectl describe application kube-prometheus-stack -n argocd

# Check sync status and health
kubectl get application kube-prometheus-stack -n argocd -o jsonpath='{.status.sync.status}' && echo
kubectl get application kube-prometheus-stack -n argocd -o jsonpath='{.status.health.status}' && echo
```

### 2. Verify Pods Are Running

```bash
# All pods should reach Running status
kubectl get pods -n monitoring -w

# Check for any CrashLoopBackOff or Error states
kubectl get pods -n monitoring | grep -v "Running\|Completed"

# View pod resource usage
kubectl top pods -n monitoring
```

### 3. Check Persistent Volume Claims

```bash
# All PVCs should be Bound
kubectl get pvc -n monitoring

# Check PVC details
kubectl describe pvc -n monitoring

# Verify storage class
kubectl get pvc -n monitoring -o jsonpath='{.items[*].spec.storageClassName}' | tr ' ' '\n' | sort -u
```

### 4. Verify Services

```bash
# List all services
kubectl get svc -n monitoring

# Check key services
kubectl get svc -n monitoring kube-prometheus-stack-prometheus
kubectl get svc -n monitoring kube-prometheus-stack-grafana
kubectl get svc -n monitoring kube-prometheus-stack-alertmanager
```

### 5. Check Ingress Resources

```bash
# List ingresses
kubectl get ingress -n monitoring

# Verify ingress configuration
kubectl describe ingress -n monitoring

# Check TLS secrets
kubectl get secret -n monitoring | grep tls
```

### 6. Test Prometheus

#### Port-Forward Access

```bash
# Forward Prometheus port
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
PF_PID=$!

# Test Prometheus API
curl -s http://localhost:9090/api/v1/status/config | jq '.status'

# Query metrics
curl -s 'http://localhost:9090/api/v1/query?query=up' | jq '.data.result[] | {job: .metric.job, instance: .metric.instance, value: .value[1]}'

# Kill port-forward
kill $PF_PID
```

#### Check Targets

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
PF_PID=$!

# List all targets
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'

# Count healthy targets
curl -s http://localhost:9090/api/v1/targets | jq '[.data.activeTargets[] | select(.health=="up")] | length'

kill $PF_PID
```

### 7. Test Grafana

#### Port-Forward Access

```bash
# Forward Grafana port
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &
PF_PID=$!

# Test Grafana API (should return 302 redirect to /login)
curl -I http://localhost:3000/

# Test login (use admin credentials from overlay)
curl -X POST http://localhost:3000/login \
  -H "Content-Type: application/json" \
  -d '{"user":"admin","password":"portcullis-admin-password"}' \
  -c /tmp/grafana-cookie

# List datasources (requires authentication)
curl -b /tmp/grafana-cookie http://localhost:3000/api/datasources | jq

kill $PF_PID
```

#### Verify Dashboards

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &
PF_PID=$!

# Login and get dashboards
curl -X POST http://localhost:3000/login \
  -H "Content-Type: application/json" \
  -d '{"user":"admin","password":"portcullis-admin-password"}' \
  -c /tmp/grafana-cookie

# Count dashboards
curl -b /tmp/grafana-cookie http://localhost:3000/api/search?type=dash-db | jq '. | length'

# List dashboard titles
curl -b /tmp/grafana-cookie http://localhost:3000/api/search?type=dash-db | jq -r '.[].title'

kill $PF_PID
```

### 8. Test Alertmanager

```bash
# Forward Alertmanager port
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093 &
PF_PID=$!

# Check Alertmanager status
curl -s http://localhost:9093/api/v2/status | jq

# List active alerts
curl -s http://localhost:9093/api/v2/alerts | jq

# Check silences
curl -s http://localhost:9093/api/v2/silences | jq

kill $PF_PID
```

### 9. Verify ServiceMonitors

```bash
# List all ServiceMonitors
kubectl get servicemonitor -n monitoring

# Check specific ServiceMonitor
kubectl describe servicemonitor kube-prometheus-stack-prometheus -n monitoring

# Verify Prometheus is discovering ServiceMonitors
kubectl logs -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prometheus | grep -i servicemonitor | tail -20
```

### 10. Check PrometheusRules

```bash
# List all PrometheusRules
kubectl get prometheusrule -n monitoring

# View custom homelab rules
kubectl get prometheusrule -n monitoring -o yaml | grep -A 10 "homelab-alerts"

# Check if rules are loaded in Prometheus
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
PF_PID=$!

curl -s http://localhost:9090/api/v1/rules | jq '.data.groups[] | select(.name=="homelab") | .rules[] | .name'

kill $PF_PID
```

### 11. Test Ingress Access

```bash
# Test Prometheus ingress (requires DNS/hosts file entry)
curl -I https://prometheus.portcullis.osow.ski

# Test Grafana ingress
curl -I https://grafana.portcullis.osow.ski

# Test Alertmanager ingress
curl -I https://alertmanager.portcullis.osow.ski

# Verify TLS certificate
openssl s_client -connect grafana.portcullis.osow.ski:443 -servername grafana.portcullis.osow.ski < /dev/null 2>/dev/null | openssl x509 -noout -text | grep -A 2 "Subject:"
```

### 12. End-to-End Monitoring Test

```bash
# Deploy a test application with ServiceMonitor
kubectl create namespace test-monitoring

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: test-app
  namespace: test-monitoring
  labels:
    app: test-app
spec:
  ports:
    - name: metrics
      port: 8080
  selector:
    app: test-app
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-app
  namespace: test-monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-app
  template:
    metadata:
      labels:
        app: test-app
    spec:
      containers:
        - name: metrics
          image: ghcr.io/prometheus/prometheus:latest
          args: ["--web.listen-address=:8080"]
          ports:
            - name: metrics
              containerPort: 8080
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: test-app
  namespace: test-monitoring
  labels:
    prometheus: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: test-app
  endpoints:
    - port: metrics
      interval: 30s
EOF

# Wait for pod to be ready
kubectl wait --for=condition=ready pod -l app=test-app -n test-monitoring --timeout=60s

# Check if Prometheus is scraping the test app (wait ~1 minute for discovery)
sleep 60
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
PF_PID=$!

curl -s 'http://localhost:9090/api/v1/query?query=up{job="test-app"}' | jq '.data.result'

kill $PF_PID

# Cleanup
kubectl delete namespace test-monitoring
```

### 13. Check Events

```bash
# View recent events in monitoring namespace
kubectl get events -n monitoring --sort-by='.lastTimestamp' | tail -20

# Check for errors or warnings
kubectl get events -n monitoring --field-selector type!=Normal
```

### 14. Resource Usage Validation

```bash
# Check actual resource usage vs requests/limits
kubectl top pods -n monitoring

# Compare to requests
kubectl get pods -n monitoring -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].resources.requests.cpu}{"\t"}{.spec.containers[*].resources.requests.memory}{"\n"}{end}'
```

## Troubleshooting Commands

### Pod Not Starting

```bash
# Describe pod
kubectl describe pod -n monitoring <pod-name>

# Check logs
kubectl logs -n monitoring <pod-name> --previous

# Check events
kubectl get events -n monitoring --field-selector involvedObject.name=<pod-name>
```

### Prometheus Not Scraping

```bash
# Check Prometheus config
kubectl get secret -n monitoring prometheus-kube-prometheus-stack-prometheus -o jsonpath='{.data.prometheus\.yaml\.gz}' | base64 -d | gunzip | less

# Check service endpoints
kubectl get endpoints -n monitoring

# Verify network connectivity
kubectl run -it --rm debug --image=nicolaka/netshoot --restart=Never -- curl -v http://kube-prometheus-stack-prometheus.monitoring.svc:9090/-/healthy
```

### Grafana Dashboard Missing Metrics

```bash
# Check Grafana datasource
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &
PF_PID=$!

curl -b /tmp/grafana-cookie http://localhost:3000/api/datasources | jq

# Test Prometheus connection from Grafana
curl -b /tmp/grafana-cookie http://localhost:3000/api/datasources/proxy/1/api/v1/query?query=up

kill $PF_PID
```

## Performance Testing

### Load Test Prometheus Query

```bash
# Simple load test
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
PF_PID=$!

for i in {1..100}; do
  curl -s 'http://localhost:9090/api/v1/query?query=up' > /dev/null &
done
wait

kill $PF_PID
```

### Monitor Prometheus Performance

```bash
# Check Prometheus metrics about itself
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
PF_PID=$!

# Query ingestion rate
curl -s 'http://localhost:9090/api/v1/query?query=rate(prometheus_tsdb_head_samples_appended_total[5m])' | jq '.data.result[0].value[1]'

# Check storage usage
curl -s 'http://localhost:9090/api/v1/query?query=prometheus_tsdb_storage_blocks_bytes' | jq

kill $PF_PID
```

## Cleanup Test Resources

```bash
# Remove test output files
rm /tmp/kube-prometheus-stack-*.yaml
rm /tmp/grafana-cookie

# Stop any remaining port-forwards
pkill -f "kubectl port-forward.*monitoring"
```

## Success Criteria

The deployment is successful if:

- [ ] All pods in `monitoring` namespace are Running
- [ ] All PVCs are Bound
- [ ] Prometheus has healthy targets (check via UI or API)
- [ ] Grafana is accessible and displays dashboards with metrics
- [ ] Alertmanager is running and shows configuration
- [ ] Ingress endpoints are accessible via HTTPS
- [ ] TLS certificates are valid (issued by Let's Encrypt)
- [ ] ServiceMonitors are discovered by Prometheus
- [ ] PrometheusRules are loaded and evaluating
- [ ] No error events in the monitoring namespace
- [ ] Resource usage is within expected limits
