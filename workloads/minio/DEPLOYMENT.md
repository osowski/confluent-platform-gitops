# MinIO Deployment for Flink S3 Storage

MinIO replaces s3proxy to provide reliable S3-compatible object storage for Flink checkpointing and high availability.

## Files Created

### Base Manifests (`workloads/minio/base/`)
- `secret.yaml` - Credentials (admin/password) with Reflector annotations for cross-namespace sharing
- `pvc.yaml` - 10Gi persistent volume for data
- `deployment.yaml` - MinIO server deployment
- `service.yaml` - ClusterIP service (ports 9000=API, 9001=console)
- `ingressroute.yaml` - Traefik ingress for external access
- `init-job.yaml` - Creates warehouse bucket on startup
- `kustomization.yaml` - Base kustomization

### Overlay (`workloads/minio/overlays/flink-demo-rbac/`)
- `ingressroute-patch.yaml` - Cluster-specific hostnames
- `kustomization.yaml` - Overlay kustomization

### Cyberduck Profile
- `clusters/flink-demo-rbac/cyberduck/S3_minio_flink-demo-rbac.cyberduckprofile`

## Deployment Steps

### 1. Deploy MinIO
```bash
kubectl apply -k workloads/minio/overlays/flink-demo-rbac
```

### 2. Verify MinIO is Running
```bash
kubectl get pods -n flink -l app=minio
kubectl logs -n flink -l app=minio
```

### 3. Update FlinkApplications

Update both `flink-application-colors.yaml` and `flink-application-shapes.yaml`:

**Change S3 endpoint:**
```yaml
flinkConfiguration:
  s3.endpoint: "http://minio.flink.svc.cluster.local:9000"  # Changed from s3proxy:8000
```

**All other S3 configs remain the same:**
```yaml
  s3.access-key: "admin"
  s3.secret-key: "password"
  s3.path.style.access: "true"
  s3.connection.ssl.enabled: "false"
  state.checkpoints.dir: "s3://warehouse/checkpoints/colors"
  state.savepoints.dir: "s3://warehouse/savepoints/colors"
  high-availability.type: kubernetes
  high-availability.storageDir: "s3://warehouse/ha/colors"
```

### 4. Redeploy Flink Applications
```bash
kubectl delete flinkapplication -n flink-colors colors
kubectl delete flinkapplication -n flink-shapes shapes
# Wait for operator to reconcile
kubectl apply -f workloads/flink-resources/overlays/flink-demo-rbac/flink-application-colors.yaml
kubectl apply -f workloads/flink-resources/overlays/flink-demo-rbac/flink-application-shapes.yaml
```

### 5. Optional: Remove s3proxy
```bash
kubectl delete -k workloads/s3proxy/overlays/flink-demo-rbac
```

## Testing MinIO

### Internal Access (from pod)
```bash
kubectl run test-minio --image=amazon/aws-cli --rm -i --restart=Never \
  --env="AWS_ACCESS_KEY_ID=admin" \
  --env="AWS_SECRET_ACCESS_KEY=password" \
  -- s3 --endpoint-url http://minio.flink.svc.cluster.local:9000 ls s3://warehouse/
```

### External Access
- **API**: http://s3.flink-demo-rbac.confluentdemo.local
- **Console**: http://s3-console.flink-demo-rbac.confluentdemo.local (login: admin/password)

### Cyberduck
Use the profile at `clusters/flink-demo-rbac/cyberduck/S3_minio_flink-demo-rbac.cyberduckprofile`

## Why MinIO vs s3proxy?

- ✅ Properly handles Hadoop S3A empty directory listings
- ✅ Production-grade S3 compatibility
- ✅ Works with Flink HA job-result-store
- ✅ Web console for debugging
- ✅ Actively maintained and widely used
- ❌ s3proxy filesystem backend has known issues with empty directories

## Configuration

### Credentials

Default credentials (externalized in Secret):
- User: `admin`
- Password: `password`

The `minio-credentials` Secret is automatically reflected to `flink-colors` and `flink-shapes` namespaces using Reflector annotations:
```yaml
reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "flink-colors,flink-shapes"
reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
```

To change credentials:
1. Update `workloads/minio/base/secret.yaml`
2. Update FlinkApplication `s3.access-key` and `s3.secret-key`
3. Redeploy
