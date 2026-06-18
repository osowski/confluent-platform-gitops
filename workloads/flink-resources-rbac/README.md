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

## Flink SQL Statement Pipeline

A standalone, RBAC-secured Flink SQL pipeline runs alongside the JAR-based `FlinkApplication`
jobs in the shapes environment. It is fully isolated — it does **not** write to the JAR
pipeline topics (`shapes-output`, `shapes-state`).

**Resources** (all in `flink-shapes`):

| Resource | Name | Notes |
|----------|------|-------|
| Input topic | `shapes-sql-input` | dedicated; `shapes-` prefix for RBAC |
| Output topic | `shapes-sql-output` | dedicated; `shapes-` prefix for RBAC |
| Input schema | `shapes-sql-input-value` | reuses `SensorEvent` ConfigMap |
| Output schema | `shapes-sql-output-value` | reuses `ProcessedSensorEvent` ConfigMap |
| Statement | `shapes-sql-enrich` | continuous `INSERT INTO`, on `shapes-pool` |
| Producer | `shapes-sql-producer` | Deployment, `replicas: 0` by default |

**How it works:**
1. The `shapes-sql-init` PostSync-hook Job (step `[7/7]`) POSTs the statement JSON from the
   `shapes-statement-config` ConfigMap to `POST /cmf/api/v1/environments/shapes-env/statements`.
   Idempotent: a `409` (already exists) is treated as success.
2. The statement reads the inferred `shapes-sql-input` table, adds an `encoded` column
   (mirroring the JAR enrichment), and writes `ProcessedSensorEvent` records to
   `shapes-sql-output`. The Kafka tables are auto-inferred from the registered SR schemas.
3. Topic/consumer-group/transactional-ID access is authorized via the `sa-shapes-flink`
   service account's `ResourceOwner` PREFIXED `shapes-` bindings.

**Validate end-to-end:**
```bash
# Feed the dedicated input
kubectl -n flink-shapes scale deploy/shapes-sql-producer --replicas=1
# Confirm the statement is RUNNING
confluent --environment shapes-env flink statement list
# Inspect transformed output
kubectl -n kafka exec -it <kafka-pod> -- kafka-avro-console-consumer \
  --topic shapes-sql-output --from-beginning --max-messages 5 ...
```

> **Versions:** requires CMF chart **2.3.1+** (2.3.0 ships incorrectly built SQL jars). The
> Flink SQL compute-pool image tracks the latest `confluentinc/cp-flink-sql` tag independently
> (`1.19-cp8` at time of writing — verify with `skopeo list-tags docker://confluentinc/cp-flink-sql`).
> The SQL functions in the statement (`TO_BASE64`, `ENCODE`, `CONCAT`) target Flink 1.19;
> validate at deploy time if bumping the image.