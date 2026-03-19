# Flink Resources - flink-demo-rbac Overlay

This overlay configures Flink resources for the flink-demo-rbac cluster with OAuth authentication.

## CMFRestClass Configuration

The flink-demo-rbac cluster uses the **base CMFRestClass** (in `flink` namespace) with OAuth authentication enabled.

The CMFRestClass is patched to add OAuth authentication for **CFK operator** to CMF communication:

- **cmfrestclass-oauth-patch.yaml** - Adds OAuth authentication to base CMFRestClass
- **cfk-oauth-secret.yaml** - OAuth token secret for CFK operator

### OAuth Authentication Architecture

**Important:** CMFRestClass authentication is **operator-level**, not user-level:

```
CFK Operator → (OAuth token) → CMF REST API → (creates Flink resources)
```

This token allows the CFK operator to manage FlinkEnvironment and FlinkApplication resources in CMF on behalf of users.

**User-level authorization** is enforced separately by:
1. **Kubernetes RBAC** (Issue #85): Controls which namespaces users can deploy CRDs to
2. **CMF RBAC via MDS** (Issue #87): Controls which Flink resources users can access via CMF UI/API

### OAuth Token Secret

The `cfk-cmf-oauth-token` secret in the `flink` namespace contains:

```yaml
stringData:
  bearer-token: "<token>"  # OAuth bearer token for operator
  client-id: "cmf"         # Alternative: client credentials
  client-secret: "cmf-secret"
```

**Note:** The bearer token is a placeholder. In production, either:
1. Obtain a token manually and update the secret
2. Use client credentials if CFK supports automatic token refresh

## Three-Layer Authorization Model

This cluster implements a **three-layer authorization model** for complete access control:

### Layer 1: Kubernetes RBAC (Issue #85)
**Controls:** Kubernetes API access, namespace isolation, CRD deployment

- Shapes group: Can deploy FlinkEnvironment/FlinkApplication CRDs to `flink-shapes` namespace
- Colors group: Can deploy FlinkEnvironment/FlinkApplication CRDs to `flink-colors` namespace
- Admin: Can deploy to all namespaces

**Resources:** See `workloads/flink-rbac/`

### Layer 2: CFK Operator Authentication
**Controls:** CFK operator to CMF REST API communication

- CMFRestClass configured with OAuth authentication
- CFK uses `cfk-cmf-oauth-token` secret to authenticate as operator
- Operator can create/manage Flink resources in CMF on behalf of users

**Resources:** `cmfrestclass-oauth-patch.yaml`, `cfk-oauth-secret.yaml`

### Layer 3: CMF RBAC via MDS (Issue #87)
**Controls:** User access to Flink resources via CMF UI/REST API

When users access CMF directly:
1. User authenticates with OAuth (Keycloak)
2. CMF validates bearer token and extracts principal + groups
3. CMF queries MDS for ConfluentRoleBindings
4. Access granted/denied based on role bindings

**ConfluentRoleBindings** (Kubernetes CRDs in `workloads/confluent-resources/overlays/flink-demo-rbac/confluentrolebindings.yaml`):

**Admin user (admin@osow.ski):**
- SystemAdmin role on CMF cluster (full access)
- ClusterAdmin role on CMF cluster (manage environments/apps)

**Shapes group:**
- DeveloperManage role on shapes-env FlinkEnvironment
- DeveloperRead role on shapes-env FlinkEnvironment resource

**Colors group:**
- DeveloperManage role on colors-env FlinkEnvironment
- DeveloperRead role on colors-env FlinkEnvironment resource

### Permission Enforcement Example

**Scenario:** User from shapes group tries to access colors-env via CMF UI

1. ✅ **K8s RBAC**: User can deploy FlinkApplication CRD to `flink-shapes` namespace
2. ✅ **CFK Auth**: Operator creates resource in CMF using operator token
3. ❌ **CMF RBAC**: User has no DeveloperManage on colors-env → **Access Denied**

This ensures users can only manage Flink resources in their assigned environments, even if they can deploy Kubernetes CRDs to their namespace.

## Related Resources

- CMF OAuth configuration: `workloads/cmf-operator/overlays/flink-demo-rbac/values.yaml`
- Kubernetes RBAC: `workloads/flink-rbac/`
- Issue #85 - Kubernetes RBAC implementation
- Issue #87 - CMF OAuth configuration (this overlay)
