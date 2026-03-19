# Flink Demo RBAC Cluster

Multi-user RBAC demonstration cluster for Confluent Platform Flink with namespace-based isolation.

## Overview

This cluster variant demonstrates comprehensive Role-Based Access Control (RBAC) for Confluent Platform Flink with the following features:

- **Group-based namespace isolation** - Shapes and Colors user groups with separate Flink environments
- **Multi-layer authentication** - Kubernetes RBAC for kubectl, OIDC/OAuth for UI/CLI access
- **Keycloak integration** - Identity provider running inside the Kubernetes cluster
- **11 demo users** - 10 group users + 1 admin with pre-configured credentials

## Architecture

### User Groups

**Shapes Group** (`/shapes`) - 5 users:
- user-square@osow.ski (password: square123)
- user-circle@osow.ski (password: circle123)
- user-triangle@osow.ski (password: triangle123)
- user-trapezoid@osow.ski (password: trapezoid123)
- user-diamond@osow.ski (password: diamond123)

**Colors Group** (`/colors`) - 5 users:
- user-red@osow.ski (password: red123)
- user-green@osow.ski (password: green123)
- user-orange@osow.ski (password: orange123)
- user-blue@osow.ski (password: blue123)
- user-yellow@osow.ski (password: yellow123)

**Admin**:
- admin@osow.ski (password: admin123)

### Namespaces

- `flink-shapes` - FlinkEnvironment: shapes-env, FlinkApplication: shapes-wordcount
- `flink-colors` - FlinkEnvironment: colors-env, FlinkApplication: colors-statemachine
- `keycloak` - Keycloak identity provider + PostgreSQL backend

### Access Control

| User Group | kubectl Access | Control Center UI | CMF CLI |
|------------|----------------|-------------------|---------|
| Shapes | flink-shapes namespace only | shapes-env only | shapes-env only |
| Colors | flink-colors namespace only | colors-env only | colors-env only |
| Admin | All namespaces | All environments | All environments |

## Prerequisites

1. **Kind installed** - Kubernetes in Docker
2. **kubectl installed** - Kubernetes CLI
3. **Helm installed** - Package manager for Kubernetes
4. **ArgoCD installed** - GitOps deployment tool

## Setup Instructions

### 1. Create the Cluster

```bash
# Create Kind cluster with custom configuration
kind create cluster --name flink-demo-rbac --config kind-config.yaml

# Verify cluster is running
kubectl cluster-info
```

### 2. Add /etc/hosts Entries

```bash
# Get Kind node IP
CLUSTER_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Add required hostnames to /etc/hosts
cat <<EOF | sudo tee -a /etc/hosts
$CLUSTER_IP controlcenter.flink-demo-rbac.confluentdemo.local
$CLUSTER_IP kafka.flink-demo-rbac.confluentdemo.local
$CLUSTER_IP keycloak.flink-demo-rbac.confluentdemo.local
EOF
```

### 3. Bootstrap ArgoCD and Infrastructure

Follow the standard bootstrap procedure to deploy ArgoCD and infrastructure components.

### 4. Deploy Keycloak

```bash
# Deploy Keycloak and PostgreSQL
kubectl apply -f ../../workloads/keycloak/base/

# Wait for Keycloak to be ready
kubectl wait --for=condition=ready pod -l app=keycloak -n keycloak --timeout=300s

# Verify Keycloak is accessible
curl http://keycloak.flink-demo-rbac.confluentdemo.local:30080/realms/confluent/.well-known/openid-configuration
```

**Keycloak Admin Console:** http://keycloak.flink-demo-rbac.confluentdemo.local:30080
- Username: `admin`
- Password: `admin`

### 5. Generate User kubeconfig Contexts

```bash
# Run the RBAC kubeconfig setup script
../../scripts/setup-rbac-kubeconfigs.sh

# This creates kubeconfig files in ~/.kube/flink-rbac/ for:
# - Each shapes group user
# - Each colors group user
# - Admin user
```

### 6. Test kubectl Access

```bash
# Test as shapes group user (user-square)
export KUBECONFIG=~/.kube/flink-rbac/user-square@flink-demo-rbac.kubeconfig
kubectl get flinkapplications
# Should only see resources in flink-shapes namespace

# Test as colors group user (user-red)
export KUBECONFIG=~/.kube/flink-rbac/user-red@flink-demo-rbac.kubeconfig
kubectl get flinkapplications
# Should only see resources in flink-colors namespace

# Test as admin
export KUBECONFIG=~/.kube/flink-rbac/admin@flink-demo-rbac.kubeconfig
kubectl get flinkapplications --all-namespaces
# Should see resources in all namespaces

# Return to Kind cluster admin
unset KUBECONFIG
# Or: export KUBECONFIG=~/.kube/config
```

### 7. Test Control Center UI Access

1. Open browser: http://controlcenter.flink-demo-rbac.confluentdemo.local
2. You'll be redirected to Keycloak login
3. Login as any user (e.g., user-circle / circle123)
4. Navigate to Flink section - should only see resources from that user's group
5. Logout and login as admin - should see all resources

### 8. Test Confluent CLI Access

```bash
# Install Confluent CLI
curl -sL --http1.1 https://cnfl.io/cli | sh -s -- latest

# Login as shapes group user
confluent login --username user-triangle@osow.ski --password triangle123

# List Flink environments (should only see shapes-env)
confluent flink environment list
```

## Access Patterns

### Kind Cluster Admin (Kubernetes Platform Administrator)

```bash
# Get cluster admin kubeconfig
kind get kubeconfig --name flink-demo-rbac > ~/.kube/flink-demo-rbac-admin.kubeconfig
export KUBECONFIG=~/.kube/flink-demo-rbac-admin.kubeconfig

# Full cluster access - no Keycloak interaction
kubectl get pods --all-namespaces
kubectl get flinkapplications --all-namespaces
kubectl describe node
```

**Use cases:**
- Cluster management and debugging
- Emergency operations
- Infrastructure troubleshooting
- ArgoCD management

### Demo Users (Application Developers/Operators)

```bash
# Use ServiceAccount-based kubeconfig
export KUBECONFIG=~/.kube/flink-rbac/user-blue@flink-demo-rbac.kubeconfig

# Limited namespace access
kubectl get flinkapplications  # Only sees flink-colors namespace
kubectl get flinkapplications -n flink-shapes  # Forbidden

# For C3 UI and CMF CLI - Keycloak authentication required
```

**Use cases:**
- Managing Flink applications within assigned environments
- Viewing logs and metrics for authorized resources
- Creating/updating FlinkApplications in allowed namespaces

## Alternative: External Keycloak with Docker Compose

For development convenience, Keycloak can run outside the cluster using Docker Compose.

### When to Use External Keycloak

- **Faster iteration** - No need to rebuild/redeploy Keycloak pod
- **Persistent realm changes** - Easier to test realm configuration changes
- **Simpler debugging** - Direct access to Keycloak logs via `docker logs`
- **Resource constraints** - Free up cluster resources for other workloads

### Docker Compose Setup

**File:** `keycloak-external/docker-compose.yaml`

```yaml
version: '3.8'

services:
  postgres:
    image: postgres:16-alpine
    container_name: keycloak-postgres
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: keycloak
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - keycloak-net

  keycloak:
    image: quay.io/keycloak/keycloak:26.2.5
    container_name: keycloak
    command: start-dev --import-realm
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: keycloak
      KEYCLOAK_ADMIN: admin
      KEYCLOAK_ADMIN_PASSWORD: admin
      KC_HTTP_PORT: 30080
      KC_HOSTNAME_STRICT: false
      KC_HOSTNAME_STRICT_HTTPS: false
    ports:
      - "30080:30080"
    volumes:
      - ./realm-import:/opt/keycloak/data/import
    networks:
      - keycloak-net
    depends_on:
      - postgres

networks:
  keycloak-net:

volumes:
  postgres_data:
```

### Using External Keycloak

1. **Start Keycloak:**
   ```bash
   cd keycloak-external
   docker-compose up -d
   ```

2. **Update CMF and C3 configurations** to use `http://keycloak.flink-demo-rbac.confluentdemo.local:30080` instead of internal cluster DNS

3. **No /etc/hosts changes needed** - Uses same hostname, just different endpoint

4. **Stop Keycloak:**
   ```bash
   docker-compose down
   # Preserve data: docker-compose down (volumes persist)
   # Clean slate: docker-compose down -v (removes volumes)
   ```

### Trade-offs

| Aspect | In-Cluster Keycloak | External Docker Compose |
|--------|---------------------|------------------------|
| Setup complexity | Higher (K8s manifests) | Lower (single docker-compose) |
| Production-like | ✅ Yes | ❌ No |
| Resource usage | Uses cluster resources | Separate Docker containers |
| Iteration speed | Slower (pod restarts) | Faster (container restarts) |
| Realm persistence | PVC in cluster | Docker volume on host |
| Network access | Requires NodePort/Ingress | Direct port mapping |

## Troubleshooting

### Keycloak Not Accessible

```bash
# Check Keycloak pod status
kubectl get pods -n keycloak

# Check Keycloak logs
kubectl logs -n keycloak -l app=keycloak

# Verify NodePort service
kubectl get svc -n keycloak keycloak-external

# Test internal cluster access
kubectl run curl-test --image=curlimages/curl -it --rm -- \
  curl http://keycloak.keycloak.svc.cluster.local:8080/realms/confluent
```

### User Cannot Access Namespace

```bash
# Check ServiceAccount exists
kubectl get sa user-square -n flink-shapes

# Check RoleBinding
kubectl get rolebinding -n flink-shapes

# Test permissions
kubectl auth can-i get flinkapplications \
  --as=system:serviceaccount:flink-shapes:user-square \
  -n flink-shapes
```

### Control Center Redirect Loop

```bash
# Verify Keycloak client configuration
# Login to Keycloak admin console
# Check redirect URIs for controlcenter client

# Verify C3 OIDC configuration
kubectl get controlcenter -n kafka -o yaml | grep -A 10 oidc
```

### Token Expiration Issues

Token lifespan is set to 120 minutes (7200 seconds). If users are getting logged out:

1. **Increase token lifespan** in Keycloak:
   - Keycloak Admin Console → Realm Settings → Tokens
   - Access Token Lifespan: 120 minutes (default)
   - Increase as needed for longer demo sessions

2. **Check session timeout** in Control Center:
   - Should be configured to 7200000 ms (2 hours)

## Documentation

For complete implementation details, architecture diagrams, and step-by-step configuration:

**See:** `/docs/flink-rbac-research.md`

## Cleanup

```bash
# Delete the Kind cluster
kind delete cluster --name flink-demo-rbac

# Remove /etc/hosts entries
sudo sed -i.bak '/flink-demo-rbac.confluentdemo.local/d' /etc/hosts

# Clean up kubeconfig files
rm -rf ~/.kube/flink-rbac/

# Stop external Keycloak (if using Docker Compose)
cd keycloak-external && docker-compose down -v
```
