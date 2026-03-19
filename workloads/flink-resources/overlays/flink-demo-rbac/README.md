# Flink Resources - flink-demo-rbac Overlay

This overlay configures Flink resources for the flink-demo-rbac cluster with OAuth authentication.

## CMFRestClass Configuration

The flink-demo-rbac cluster uses namespace-specific CMFRestClass resources:

- **cmfrestclass-shapes.yaml** - CMFRestClass for flink-shapes namespace
- **cmfrestclass-colors.yaml** - CMFRestClass for flink-colors namespace

Both are configured with OAuth authentication pointing to CMF's OAuth-enabled endpoint.

### OAuth Token Management

Each CMFRestClass references a secret named `cmf-oauth-token` that must be created in the respective namespace. This secret should contain:

- OAuth bearer token, or
- Client credentials for obtaining tokens

**Example secret creation:**
```bash
# For shapes namespace
kubectl create secret generic cmf-oauth-token \
  -n flink-shapes \
  --from-literal=bearer-token=<token>

# For colors namespace
kubectl create secret generic cmf-oauth-token \
  -n flink-colors \
  --from-literal=bearer-token=<token>
```

## Authorization - MDS RBAC

**MDS (Metadata Service) is configured** to provide full group-based RBAC authorization.

This cluster includes:
- ✅ MDS enabled on Kafka brokers with OAuth provider (Keycloak)
- ✅ CMF configured to use MDS for authorization
- ✅ OAuth authentication for identity verification
- ✅ Kubernetes RBAC for namespace-level isolation (see Issue #85)

### ConfluentRoleBindings

ConfluentRoleBindings are **not Kubernetes resources** - they are created via MDS API using the Confluent CLI:

```bash
# Example: Grant DeveloperManage role to shapes group
confluent iam rbac role-binding create \
  --principal Group:shapes \
  --role DeveloperManage \
  --cmf CMF-id \
  --flink-environment shapes-env \
  --resource FlinkApplication:"*"

# Example: Grant DeveloperManage role to colors group
confluent iam rbac role-binding create \
  --principal Group:colors \
  --role DeveloperManage \
  --cmf CMF-id \
  --flink-environment colors-env \
  --resource FlinkApplication:"*"
```

These role bindings are stored in MDS and evaluated when users make requests to CMF.

For Kubernetes-level RBAC (namespace isolation, pod permissions), see `workloads/flink-rbac/`.

## Related Resources

- CMF OAuth configuration: `workloads/cmf-operator/overlays/flink-demo-rbac/values.yaml`
- Kubernetes RBAC: `workloads/flink-rbac/`
- Issue #85 - Kubernetes RBAC implementation
- Issue #87 - CMF OAuth configuration (this overlay)
