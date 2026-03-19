# MDS/RBAC Setup Guide for flink-demo-rbac

This guide explains the MDS (Metadata Service) and RBAC configuration for the flink-demo-rbac cluster.

## Overview

The flink-demo-rbac cluster is configured with full RBAC authorization using:
- **MDS (Metadata Service)** running on Kafka brokers
- **OAuth authentication** via Keycloak for identity
- **RBAC authorization** for fine-grained permissions
- **CMF integration** with MDS for Flink resource authorization

## Prerequisites

1. Keycloak realm configured with:
   - Users: admin@osow.ski, shapes group users, colors group users
   - Groups: shapes, colors
   - OAuth clients: cmf, kafka, controlcenter, confluent-sso
   - See: `workloads/keycloak/base/realm-configmap.yaml`

2. Kubernetes RBAC configured:
   - Namespaces: flink-shapes, flink-colors
   - ServiceAccounts and RoleBindings
   - See: `workloads/flink-rbac/`

## Initial Setup

### 1. Generate MDS Token Keypair

The MDS token keypair is used to sign/validate authentication tokens.

**Generate RSA keypair:**
```bash
# Generate private key
openssl genrsa -out mds-tokenkeypair.txt 2048

# Extract public key
openssl rsa -in mds-tokenkeypair.txt -outform PEM -pubout -out mds-publickey.txt
```

**Create Kubernetes secret:**
```bash
kubectl create secret generic mds-token \
  --from-file=mdsPublicKey.pem=mds-publickey.txt \
  --from-file=mdsTokenKeyPair.pem=mds-tokenkeypair.txt \
  --namespace kafka \
  --dry-run=client -o yaml > mds-token-secret.yaml

# Apply the secret (overwrites placeholder)
kubectl apply -f mds-token-secret.yaml
```

**Important:** Delete the plaintext key files after creating the secret.

### 2. Verify OAuth Client Secrets

The following secrets should exist with credentials matching Keycloak:

```bash
# Check Kafka OAuth client
kubectl get secret kafka-oauth-client -n kafka -o yaml

# Check KRaft OAuth client
kubectl get secret kraft-oauth-client -n kafka -o yaml

# Check CMF MDS OAuth client
kubectl get secret cmf-mds-oauth-client -n operator -o yaml
```

These are created by `oauth-client-secrets.yaml` with values from the Keycloak realm.

### 3. Deploy Resources

Deploy via ArgoCD:
```bash
# Sync confluent-resources application
kubectl -n argocd get application confluent-resources

# Sync cmf-operator application
kubectl -n argocd get application cmf-operator
```

### 4. Verify MDS is Running

Check that MDS is accessible on Kafka brokers:
```bash
# Port-forward to Kafka broker
kubectl port-forward -n kafka kafka-0 8090:8090

# In another terminal, check MDS health
curl http://localhost:8090/security/1.0/activePrincipals

# Should return: {"activeUsers":[]}
```

### 5. Configure ConfluentRoleBindings

ConfluentRoleBindings are created via the Confluent CLI, not Kubernetes resources.

**Install Confluent CLI:**
```bash
# See: https://docs.confluent.io/confluent-cli/current/install.html
brew install confluentinc/tap/cli
```

**Login to MDS:**
```bash
# Set MDS endpoint
export MDS_URL=http://localhost:8090

# Login as admin user
confluent login --url $MDS_URL \
  --ca-cert-path /path/to/ca.crt  # if using HTTPS
```

**Create role bindings for admin:**
```bash
# Grant SystemAdmin on CMF cluster
confluent iam rbac role-binding create \
  --principal User:admin@osow.ski \
  --role SystemAdmin \
  --cmf CMF-id

# Grant ClusterAdmin on CMF cluster
confluent iam rbac role-binding create \
  --principal User:admin@osow.ski \
  --role ClusterAdmin \
  --cmf CMF-id
```

**Create role bindings for shapes group:**
```bash
# Grant DeveloperManage on shapes environment
confluent iam rbac role-binding create \
  --principal Group:shapes \
  --role DeveloperManage \
  --cmf CMF-id \
  --flink-environment shapes-env \
  --resource FlinkApplication:"*"

# Grant DeveloperRead on shapes environment
confluent iam rbac role-binding create \
  --principal Group:shapes \
  --role DeveloperRead \
  --cmf CMF-id \
  --resource FlinkEnvironment:shapes-env
```

**Create role bindings for colors group:**
```bash
# Grant DeveloperManage on colors environment
confluent iam rbac role-binding create \
  --principal Group:colors \
  --role DeveloperManage \
  --cmf CMF-id \
  --flink-environment colors-env \
  --resource FlinkApplication:"*"

# Grant DeveloperRead on colors environment
confluent iam rbac role-binding create \
  --principal Group:colors \
  --role DeveloperRead \
  --cmf CMF-id \
  --resource FlinkEnvironment:colors-env
```

## Testing RBAC

### Test with Admin User

```bash
# Obtain OAuth token for admin user
TOKEN=$(curl -X POST http://keycloak.flink-demo-rbac.confluentdemo.local:30080/realms/confluent/protocol/openid-connect/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=confluent-sso" \
  -d "username=admin@osow.ski" \
  -d "password=admin-password" | jq -r '.access_token')

# Make authenticated request to CMF
curl -H "Authorization: Bearer $TOKEN" \
  http://cmf-service.operator.svc.cluster.local:80/api/v1/environments
```

### Test with Shapes Group User

```bash
# Obtain token for shapes user
TOKEN=$(curl -X POST http://keycloak.flink-demo-rbac.confluentdemo.local:30080/realms/confluent/protocol/openid-connect/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=confluent-sso" \
  -d "username=user-square@shapes.local" \
  -d "password=shapes-password" | jq -r '.access_token')

# Access shapes environment (should succeed)
curl -H "Authorization: Bearer $TOKEN" \
  http://cmf-service.operator.svc.cluster.local:80/api/v1/environments/shapes-env

# Access colors environment (should fail - unauthorized)
curl -H "Authorization: Bearer $TOKEN" \
  http://cmf-service.operator.svc.cluster.local:80/api/v1/environments/colors-env
```

## RBAC Roles Summary

### CMF Cluster-Level Roles

- **SystemAdmin**: Full access, can delete environments
- **ClusterAdmin**: Manage environments and applications, cannot manage role bindings
- **UserAdmin**: Manage role bindings only

### CMF Resource-Level Roles

- **ResourceOwner**: Full access to specific resources, can manage role bindings
- **DeveloperManage**: Create/update/delete resources, cannot manage role bindings
- **DeveloperRead**: Read-only access to resources

See: [CMF Access Control](https://docs.confluent.io/platform/current/flink/configure/access-control.html)

## Troubleshooting

### MDS not accessible

Check Kafka broker logs:
```bash
kubectl logs -n kafka kafka-0 | grep -i mds
```

Verify MDS port is listening:
```bash
kubectl exec -n kafka kafka-0 -- netstat -ln | grep 8090
```

### OAuth token validation fails

Check CMF logs:
```bash
kubectl logs -n operator -l app.kubernetes.io/name=cmf | grep -i oauth
```

Verify Keycloak JWKS endpoint is accessible from CMF pod:
```bash
kubectl exec -n operator <cmf-pod> -- curl http://keycloak.keycloak.svc.cluster.local:8080/realms/confluent/protocol/openid-connect/certs
```

### Role bindings not working

List role bindings for a principal:
```bash
confluent iam rbac role-binding list \
  --principal User:admin@osow.ski \
  --cmf CMF-id
```

Check MDS audit logs for authorization decisions.

## Security Considerations

1. **Token Keypair**: Store securely, rotate periodically
2. **OAuth Secrets**: Use Kubernetes secrets, never commit plaintext
3. **HTTPS**: In production, enable TLS for all endpoints
4. **Principle of Least Privilege**: Grant minimal permissions needed
5. **Audit Logs**: Enable centralized audit logging for compliance

## Related Documentation

- [Confluent RBAC Overview](https://docs.confluent.io/platform/current/security/authorization/rbac/overview.html)
- [CMF Authorization](https://docs.confluent.io/platform/current/flink/installation/authorization.html)
- [CFK RBAC Configuration](https://docs.confluent.io/operator/current/co-rbac.html)
