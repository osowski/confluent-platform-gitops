# MDS Token Keypair Generation

## Overview

The MDS (Metadata Service) token keypair is used to sign and validate authentication tokens for RBAC authorization. This overlay includes an automated Kubernetes Job that generates the keypair programmatically.

## Automated Generation (Default)

The `mds-keygen-job.yaml` file defines a Kubernetes Job that:

1. **Runs as ArgoCD PreSync hook** - Executes before other resources (sync-wave: -4)
2. **Generates RSA 2048-bit keypair** - Uses openssl to create cryptographically secure keys
3. **Creates mds-token secret** - Stores keys in `mds-token` Secret in kafka namespace
4. **Idempotent operation** - Checks if valid keys exist before regenerating
5. **Detects placeholders** - Replaces placeholder keys from previous versions

### How It Works

```yaml
# ArgoCD PreSync hook ensures keys exist before Kafka starts
annotations:
  argocd.argoproj.io/hook: PreSync
  argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
  argocd.argoproj.io/sync-wave: "-4"
```

**The job:**
1. Checks if `mds-token` secret exists
2. If it exists, validates the keys are not placeholders
3. If valid keys exist, exits successfully (no-op)
4. If no keys or placeholder keys found, generates new RSA keypair
5. Creates/updates the secret with the generated keys
6. Cleans up temporary files

### RBAC Permissions

The job requires these permissions (included in `mds-keygen-job.yaml`):
- ServiceAccount: `mds-keygen`
- Role: Can create/update secrets named `mds-token`
- RoleBinding: Binds ServiceAccount to Role

## Verification

After ArgoCD syncs the application:

```bash
# Check if the job completed successfully
kubectl get job mds-keygen -n kafka

# Expected output:
# NAME         COMPLETIONS   DURATION   AGE
# mds-keygen   1/1           5s         2m

# View job logs
kubectl logs job/mds-keygen -n kafka

# Verify the secret exists
kubectl get secret mds-token -n kafka

# Check the public key (should be a valid PEM-encoded RSA key)
kubectl get secret mds-token -n kafka -o jsonpath='{.data.mdsPublicKey\.pem}' | base64 -d
```

**Valid output should start with:**
```
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA...
```

## Manual Generation (Alternative)

If you prefer to generate keys manually or need to rotate keys:

```bash
# 1. Generate RSA 2048-bit private key
openssl genrsa -out mds-tokenkeypair.pem 2048

# 2. Extract public key
openssl rsa -in mds-tokenkeypair.pem -outform PEM -pubout -out mds-publickey.pem

# 3. Create or update the secret
kubectl create secret generic mds-token \
  --from-file=mdsPublicKey.pem=mds-publickey.pem \
  --from-file=mdsTokenKeyPair.pem=mds-tokenkeypair.pem \
  --namespace kafka \
  --dry-run=client -o yaml | kubectl apply -f -

# 4. Clean up local key files (IMPORTANT!)
rm mds-tokenkeypair.pem mds-publickey.pem

# 5. Restart Kafka pods to pick up new keys
kubectl rollout restart statefulset/kafka -n kafka
```

## Key Rotation

To rotate the MDS token keypair:

**Option 1: Delete the secret and let the job regenerate**
```bash
# Delete the existing secret
kubectl delete secret mds-token -n kafka

# Trigger ArgoCD sync to run the keygen job again
kubectl -n argocd patch application confluent-resources \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}' \
  --type merge
```

**Option 2: Generate and apply new keys manually**
Follow the manual generation steps above.

**After rotation:**
1. Restart Kafka pods: `kubectl rollout restart statefulset/kafka -n kafka`
2. Restart KRaft controllers: `kubectl rollout restart statefulset/kraftcontroller -n kafka`
3. Restart CMF: `kubectl rollout restart deployment -n operator -l app.kubernetes.io/name=cmf`

## Security Considerations

1. **Keys are cluster-scoped** - Each cluster gets unique keys generated on first deployment
2. **Keys are ephemeral** - Not stored in Git, generated per cluster
3. **Automatic rotation** - Delete secret to trigger regeneration
4. **Private key protection** - Stored only in Kubernetes Secret, never written to disk outside cluster
5. **GitOps-friendly** - No manual key management required

## Troubleshooting

### Job fails with "command not found: openssl"

The bitnami/kubectl image includes openssl. If it's missing, the job installs it:
```bash
apk add --no-cache openssl
```

### Secret exists but Kafka won't start

Check if the secret has valid keys:
```bash
# Verify public key format
kubectl get secret mds-token -n kafka -o jsonpath='{.data.mdsPublicKey\.pem}' | base64 -d | openssl rsa -pubin -text -noout

# Should show RSA public key details, not an error
```

If invalid, delete the secret and let the job regenerate:
```bash
kubectl delete secret mds-token -n kafka
kubectl -n argocd get application confluent-resources -o yaml | grep -A 5 "operation:"
```

### Job runs but secret not created

Check job logs for errors:
```bash
kubectl logs job/mds-keygen -n kafka

# Check if ServiceAccount has permissions
kubectl auth can-i create secrets --as=system:serviceaccount:kafka:mds-keygen -n kafka
```

## Production Considerations

For production environments:
1. **Use external secret management** (Vault, AWS Secrets Manager, etc.)
2. **Implement key rotation policy** (e.g., rotate every 90 days)
3. **Backup keys** to encrypted storage for disaster recovery
4. **Monitor key expiration** and rotation events
5. **Use encrypted private keys** with passphrase protection

See [External Secrets Operator](https://external-secrets.io/) for Vault integration.
