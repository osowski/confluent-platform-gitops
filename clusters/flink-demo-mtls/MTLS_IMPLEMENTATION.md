# mTLS Implementation Guide

## Overview

This is an expert-level operational guide for deploying and managing mTLS authentication in the `flink-demo-mtls` cluster. For architecture and design details, see [README.md](./README.md#mtls-configuration).

**Quick Links:**
- [Cluster Overview](./README.md) - Cluster architecture and components
- [mTLS Architecture](./README.md#mtls-configuration) - How mTLS components interact
- [Design Decisions](./README.md#design-decisions) - Why ClusterIssuer, strategic merge patches, etc.

## Deployment Prerequisites

### Required Infrastructure
The following must be deployed before applying this overlay:

- ✅ **cert-manager** (sync-wave 20)
  ```bash
  kubectl get pods -n cert-manager -l app=cert-manager
  ```

- ✅ **trust-manager** (sync-wave 30)
  ```bash
  kubectl get pods -n cert-manager -l app.kubernetes.io/name=trust-manager
  ```

- ✅ **selfsigned-cluster-issuer** (cluster-scoped)
  ```bash
  kubectl get clusterissuer selfsigned-cluster-issuer
  ```

- ✅ **Certificate Infrastructure** (from flink-resources overlay)
  ```bash
  # Check certificates are ready
  kubectl get certificates -n cert-manager
  kubectl get certificates -n operator
  kubectl get certificates -n flink
  ```

### Namespace Requirements
Both namespaces must exist and be labeled:
```bash
# Verify namespaces and labels
kubectl get namespace operator -o yaml | grep "cmf-mtls: enabled"
kubectl get namespace flink -o yaml | grep "cmf-mtls: enabled"
```

## Deployment Sequence

The overlay is deployed via ArgoCD Application. The deployment follows this sequence:

1. **flink-resources overlay applies** (creates certificate infrastructure)
2. **cert-manager issues certificates** (CA, server cert, client cert)
3. **trust-manager distributes CA bundle** (ConfigMaps in labeled namespaces)
4. **cmf-operator applies with mTLS** (mounts server certificate)
5. **cp-flink-sql-sandbox overlay applies** (patches hook jobs for mTLS)
6. **Hook jobs execute** (wait for certificates, use mTLS flags)

## Pre-Deployment Verification

Run these checks before deploying the overlay:

```bash
# 1. Verify certificate infrastructure is ready
kubectl wait --for=condition=Ready certificate/cmf-root-ca -n cert-manager --timeout=300s
kubectl wait --for=condition=Ready certificate/cmf-server-tls -n operator --timeout=300s
kubectl wait --for=condition=Ready certificate/cmf-client-tls -n flink --timeout=300s

# 2. Verify trust bundles are distributed
kubectl get configmap cmf-ca-bundle -n operator
kubectl get configmap cmf-ca-bundle -n flink

# 3. Verify CMF service is ready
kubectl get pods -n operator -l app.kubernetes.io/name=confluent-manager-for-apache-flink
kubectl get svc -n operator cmf-service

# 4. Verify secrets exist and are populated
kubectl get secret cmf-server-tls -n operator -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject
kubectl get secret cmf-client-tls -n flink -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject
```

## Advanced Troubleshooting

For basic troubleshooting, see [README.md](./README.md#troubleshooting). This section covers advanced diagnostic procedures.

### Hook Job Failures

#### Debug wait-for-certificates initContainer
```bash
# Get pod that's stuck waiting
POD=$(kubectl get pods -n flink -l job-name=cmf-catalog-database-init --field-selector=status.phase=Pending -o name | head -1)

# Check initContainer logs
kubectl logs -n flink $POD -c wait-for-certificates

# Check if secrets/configmaps are mounted
kubectl describe pod -n flink $POD | grep -A 10 "Volumes:"

# Verify secret exists and has correct keys
kubectl get secret cmf-client-tls -n flink -o jsonpath='{.data}' | jq 'keys'

# Expected: ["ca.crt", "tls.crt", "tls.key"]
```

#### Debug mTLS CLI command failures
```bash
# Get the actual hook job pod
POD=$(kubectl get pods -n flink -l job-name=cmf-catalog-database-init -o name | head -1)

# Exec into the pod to test manually
kubectl exec -it -n flink $POD -- sh

# Inside pod, verify certificate files
ls -la /certs/client/
ls -la /certs/ca/

# Test certificate validity
openssl x509 -in /certs/client/tls.crt -noout -text | grep "Not After"

# Test connection to CMF
curl -v \
  --cacert /certs/ca/ca.crt \
  --cert /certs/client/tls.crt \
  --key /certs/client/tls.key \
  https://cmf-service.operator.svc.cluster.local:443/health
```

### Certificate Chain Validation

```bash
# Verify full certificate chain
echo "1. Root CA (cert-manager namespace):"
kubectl get secret cmf-root-ca -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d | openssl x509 -noout -subject -issuer

echo "2. Server Certificate (operator namespace):"
kubectl get secret cmf-server-tls -n operator -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer

echo "3. Client Certificate (flink namespace):"
kubectl get secret cmf-client-tls -n flink -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer

# Verify issuer chain
echo "4. Verify ClusterIssuer:"
kubectl get clusterissuer cmf-ca-issuer -o yaml

# Check certificate readiness
kubectl get certificates -A | grep cmf
```

### CMF Service mTLS Configuration

```bash
# Verify CMF pod has server certificate mounted
CMF_POD=$(kubectl get pods -n operator -l app.kubernetes.io/name=confluent-manager-for-apache-flink -o name | head -1)

kubectl exec -n operator $CMF_POD -- ls -la /etc/cmf/tls/

# Check CMF configuration for mTLS
kubectl get deployment -n operator -l app.kubernetes.io/name=confluent-manager-for-apache-flink -o yaml | grep -A 20 "volumes:"

# Check CMF logs for TLS handshake
kubectl logs -n operator $CMF_POD | grep -i "tls\|certificate\|handshake"
```

## Operational Testing

### End-to-End mTLS Test

Create a test pod to verify the complete mTLS flow:

```bash
# Create test pod with same certificate mounts as hook jobs
kubectl run -n flink test-mtls-connection \
  --image=confluentinc/confluent-cli:4.53.0 \
  --rm -it \
  --overrides='{
  "spec": {
    "containers": [{
      "name": "test",
      "image": "confluentinc/confluent-cli:4.53.0",
      "command": ["sh"],
      "volumeMounts": [
        {"name": "client-certs", "mountPath": "/certs/client", "readOnly": true},
        {"name": "ca-bundle", "mountPath": "/certs/ca", "readOnly": true}
      ]
    }],
    "volumes": [
      {"name": "client-certs", "secret": {"secretName": "cmf-client-tls"}},
      {"name": "ca-bundle", "configMap": {"name": "cmf-ca-bundle"}}
    ]
  }
}'

# Inside the pod, run these tests:

# 1. Verify certificate files
ls -la /certs/client/
ls -la /certs/ca/

# 2. Test HTTPS connection
curl -v \
  --cacert /certs/ca/ca.crt \
  --cert /certs/client/tls.crt \
  --key /certs/client/tls.key \
  https://cmf-service.operator.svc.cluster.local:443/health

# 3. Test Confluent Flink CLI commands
export CMF_URL="https://cmf-service.operator.svc.cluster.local:443"

confluent flink environment list \
  --cacert /certs/ca/ca.crt \
  --cert /certs/client/tls.crt \
  --key /certs/client/tls.key

# 4. Verify without certs fails (should get TLS error)
curl -v -k https://cmf-service.operator.svc.cluster.local:443/health
# Expected: Connection error or certificate verification failure
```

### Certificate Renewal Test

Verify auto-renewal is working correctly:

```bash
# Check current certificate expiry
kubectl get secret cmf-client-tls -n flink -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -noout -enddate

# Trigger renewal by shortening renewBefore (for testing only)
kubectl patch certificate cmf-client-tls -n flink --type merge -p '
spec:
  renewBefore: 2159h
'

# Watch cert-manager renew the certificate
kubectl get certificate cmf-client-tls -n flink -w

# Verify new certificate was issued
kubectl describe certificate cmf-client-tls -n flink

# Restore original renewBefore
kubectl patch certificate cmf-client-tls -n flink --type merge -p '
spec:
  renewBefore: 720h
'
```

## Post-Deployment Validation

### Validation Checklist

Complete this checklist after deploying the overlay:

#### Infrastructure (✅ = Ready)
- [ ] **cert-manager pods running**
  ```bash
  kubectl get pods -n cert-manager -l app=cert-manager
  ```

- [ ] **trust-manager pods running**
  ```bash
  kubectl get pods -n cert-manager -l app.kubernetes.io/name=trust-manager
  ```

- [ ] **ClusterIssuer ready**
  ```bash
  kubectl get clusterissuer cmf-ca-issuer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
  # Expected: True
  ```

#### Certificates (✅ = Ready)
- [ ] **Root CA issued**
  ```bash
  kubectl get certificate cmf-root-ca -n cert-manager -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
  # Expected: True
  ```

- [ ] **Server certificate issued**
  ```bash
  kubectl get certificate cmf-server-tls -n operator -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
  # Expected: True
  ```

- [ ] **Client certificate issued**
  ```bash
  kubectl get certificate cmf-client-tls -n flink -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
  # Expected: True
  ```

#### Trust Distribution (✅ = ConfigMaps exist)
- [ ] **CA bundle in operator namespace**
  ```bash
  kubectl get configmap cmf-ca-bundle -n operator
  ```

- [ ] **CA bundle in flink namespace**
  ```bash
  kubectl get configmap cmf-ca-bundle -n flink
  ```

- [ ] **Namespace labels applied**
  ```bash
  kubectl get namespace operator -o jsonpath='{.metadata.labels.cmf-mtls}'
  kubectl get namespace flink -o jsonpath='{.metadata.labels.cmf-mtls}'
  # Expected: enabled
  ```

#### CMF Service (✅ = mTLS enabled)
- [ ] **CMF pods running with server cert mounted**
  ```bash
  kubectl get pods -n operator -l app.kubernetes.io/name=confluent-manager-for-apache-flink
  kubectl exec -n operator <cmf-pod> -- ls /etc/cmf/tls/
  # Expected: tls.crt  tls.key  ca.crt
  ```

- [ ] **CMF service accessible via HTTPS**
  ```bash
  kubectl run -n operator test-cmf --image=curlimages/curl --rm -it -- \
    curl -k https://cmf-service.operator.svc.cluster.local:443/health
  ```

#### Hook Jobs (✅ = Successful)
- [ ] **cmf-init-job completed successfully**
  ```bash
  kubectl get job -n flink cmf-catalog-database-init -o jsonpath='{.status.succeeded}'
  # Expected: 1
  kubectl logs -n flink -l job-name=cmf-catalog-database-init
  ```

- [ ] **cmf-compute-pool-job completed successfully**
  ```bash
  kubectl get job -n flink cmf-compute-pool-init -o jsonpath='{.status.succeeded}'
  # Expected: 1
  kubectl logs -n flink -l job-name=cmf-compute-pool-init
  ```

#### End-to-End (✅ = Working)
- [ ] **Flink environment exists**
  ```bash
  kubectl get flinkenvironment -n flink
  ```

- [ ] **Compute pool exists**
  ```bash
  kubectl get flinkcomputepool -n flink
  ```

- [ ] **CMFRestClass configured for mTLS**
  ```bash
  kubectl get cmfrestclass cmf-rest-class -n flink -o yaml | grep "type: mtls"
  ```

## Rollback Procedures

### Emergency Rollback (Quick)

If mTLS is causing issues and you need to revert immediately:

```bash
# 1. Scale down problematic workload
kubectl scale deployment -n operator -l app.kubernetes.io/name=confluent-manager-for-apache-flink --replicas=0

# 2. Switch ArgoCD application to base overlay (or previous cluster variant)
# Edit the Application manifest to point to base or flink-demo overlay

# 3. Sync the application
# This reverts hook jobs to HTTP, removes mTLS patches

# 4. Scale CMF back up (if using flink-demo overlay without mTLS)
kubectl scale deployment -n operator -l app.kubernetes.io/name=confluent-manager-for-apache-flink --replicas=1
```

### Controlled Rollback (Preferred)

For a cleaner rollback with proper cleanup:

#### 1. Revert Hook Jobs to HTTP
```bash
# Point ArgoCD Application to non-mTLS overlay
kubectl patch application cp-flink-sql-sandbox -n argocd --type merge -p '
spec:
  source:
    path: workloads/cp-flink-sql-sandbox/base
'

# Sync the application
argocd app sync cp-flink-sql-sandbox
```

#### 2. Revert CMF Operator to HTTP
```bash
# Update cmf-operator overlay to remove mTLS config
# (or switch to flink-demo overlay)
kubectl patch application cmf-operator -n argocd --type merge -p '
spec:
  source:
    path: workloads/cmf-operator/overlays/flink-demo
'

argocd app sync cmf-operator
```

#### 3. Revert flink-resources Overlay
```bash
# Switch to base or non-mTLS overlay
kubectl patch application flink-resources -n argocd --type merge -p '
spec:
  source:
    path: workloads/flink-resources/base
'

argocd app sync flink-resources
```

#### 4. Clean Up Certificate Resources (Optional)
```bash
# Only if completely removing mTLS infrastructure
kubectl delete certificate cmf-client-tls -n flink
kubectl delete certificate cmf-server-tls -n operator
kubectl delete certificate cmf-root-ca -n cert-manager
kubectl delete clusterissuer cmf-ca-issuer
kubectl delete bundle cmf-ca-bundle

# Remove namespace labels
kubectl label namespace operator cmf-mtls-
kubectl label namespace flink cmf-mtls-
```

### Verification After Rollback

```bash
# 1. Verify hook jobs are using HTTP
kubectl get job -n flink cmf-catalog-database-init -o yaml | grep "CMF_URL"
# Expected: http://cmf-service.operator.svc.cluster.local:80

# 2. Verify CMF is accessible via HTTP
kubectl run -n flink test-http --image=curlimages/curl --rm -it -- \
  curl http://cmf-service.operator.svc.cluster.local:80/health

# 3. Verify CMFRestClass is using HTTP
kubectl get cmfrestclass cmf-rest-class -n flink -o yaml | grep endpoint
# Expected: http://cmf-service.operator.svc.cluster.local:80
```

## Monitoring and Alerts

### Certificate Expiry Monitoring

Set up alerts for certificate expiration (recommended with Prometheus):

```yaml
# Example PrometheusRule for certificate expiry
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cmf-certificate-alerts
  namespace: monitoring
spec:
  groups:
  - name: certificates
    interval: 1h
    rules:
    - alert: CertificateExpiryWarning
      expr: |
        certmanager_certificate_expiration_timestamp_seconds
        - time() < 7 * 24 * 3600
      labels:
        severity: warning
      annotations:
        summary: "Certificate {{ $labels.name }} expires in less than 7 days"
    - alert: CertificateExpiryCritical
      expr: |
        certmanager_certificate_expiration_timestamp_seconds
        - time() < 24 * 3600
      labels:
        severity: critical
      annotations:
        summary: "Certificate {{ $labels.name }} expires in less than 24 hours"
```

### Health Checks

```bash
# Automated health check script
#!/bin/bash
echo "Checking mTLS infrastructure..."

# Check certificates
for cert in cmf-root-ca:cert-manager cmf-server-tls:operator cmf-client-tls:flink; do
  name=${cert%:*}
  ns=${cert#*:}
  status=$(kubectl get certificate $name -n $ns -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  echo "Certificate $name in $ns: $status"
done

# Check trust bundles
for ns in operator flink; do
  kubectl get configmap cmf-ca-bundle -n $ns &>/dev/null && echo "CA bundle in $ns: OK" || echo "CA bundle in $ns: MISSING"
done

# Check CMF service
kubectl get pods -n operator -l app.kubernetes.io/name=confluent-manager-for-apache-flink -o jsonpath='{.items[0].status.phase}' | grep -q Running && echo "CMF service: Running" || echo "CMF service: NOT RUNNING"
```

---

**Related Documentation:**
- [README.md](./README.md#mtls-configuration) - Cluster overview and mTLS architecture
- [Issue #71](https://github.com/osowski/confluent-platform-gitops/issues/71) - Phase 1 & 2 implementation
- [Issue #73](https://github.com/osowski/confluent-platform-gitops/issues/73) - Phase 3: Kafka broker mTLS
- [Issue #74](https://github.com/osowski/confluent-platform-gitops/issues/74) - Phase 4: Schema Registry mTLS
- [Issue #75](https://github.com/osowski/confluent-platform-gitops/issues/75) - Phase 5: Complete component mTLS
