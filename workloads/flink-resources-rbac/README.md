# Flink Resources RBAC

This Argo CD Application configures Flink resources for RBAC-enabled clusters with OAuth authentication.

## CMFRestClass Configuration

The RBAC-enabled clusters uses the **base CMFRestClass** (in `flink` namespace) with OAuth authentication enabled.

The CMFRestClass is contains OAuth authentication for **CFK operator** to CMF communication:

- **cfk-oauth-secret.yaml** - OAuth token secret for CFK operator

### OAuth Authentication Architecture

**Important:** CMFRestClass authentication is **operator-level**, not user-level:

```
CFK Operator → (OAuth token) → CMF REST API → (creates Flink resources)
```

This token allows the CFK operator to manage FlinkEnvironment and FlinkApplication resources in CMF on behalf of users.

### OAuth Client Credentials Secret

The `cfk-cmf-oauth-client` secret in the `flink` namespace contains OAuth client credentials in plain text format:

```yaml
stringData:
  oauth.txt: |
    clientId=cmf
    clientSecret=cmf-secret
```

**How it works:**
1. CFK reads client credentials from the secret
2. CFK calls Keycloak token endpoint to obtain access tokens
3. CFK automatically refreshes tokens as needed
4. No manual token management required

**Token endpoint:** `http://keycloak.keycloak.svc.cluster.local:8080/realms/confluent/protocol/openid-connect/token`

This uses the **OAuth 2.0 client credentials flow**, where CFK exchanges the client ID/secret for bearer tokens automatically

## Three-Layer Authorization Model

The RBAC-enabled clusters implement a **three-layer authorization model** for complete access control:

### Layer 1: Kubernetes RBAC (Issue #85)
**Controls:** Kubernetes API access, namespace isolation, CRD deployment

- Shapes group: Can deploy FlinkEnvironment/FlinkApplication CRDs to `flink-shapes` namespace
- Colors group: Can deploy FlinkEnvironment/FlinkApplication CRDs to `flink-colors` namespace
- Admin: Can deploy to all namespaces

**Resources:** See `workloads/flink-rbac/`

### Layer 2: CFK Operator Authentication
**Controls:** CFK operator to CMF REST API communication

- CMFRestClass configured with OAuth client credentials flow
- CFK uses `cfk-cmf-oauth-client` secret containing client ID/secret
- CFK automatically obtains and refreshes OAuth tokens from Keycloak
- Operator can create/manage Flink resources in CMF on behalf of users

**Resources:** `cmfrestclass.yaml`, `cfk-oauth-secret.yaml`

### Layer 3: CMF RBAC via MDS
**Controls:** User access to Flink resources via CMF UI/REST API

When users access CMF directly:
1. User authenticates with OAuth (Keycloak)
2. CMF validates bearer token and extracts principal + groups
3. CMF queries MDS for ConfluentRoleBindings
4. Access granted/denied based on role bindings

**ConfluentRoleBindings** (Kubernetes CRDs in `workloads/confluent-resources/overlays/flink-demo-rbac/confluentrolebindings.yaml`):

**Admin user (admin@osow.ski / admin@dspdemos.com):**
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