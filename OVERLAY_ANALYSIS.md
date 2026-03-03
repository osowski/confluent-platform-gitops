# Overlay Template Analysis

## Current State

**Overlays in flink-demo:**
- 11 infrastructure overlays (~21 cluster-specific references)
- 6 workload overlays (~10 cluster-specific references)
- Total: 17 overlay directories, ~307 lines, ~92KB

**Overlay Types:**

1. **Cluster-specific (hostnames):**
   - `argocd-ingress`, `vault-ingress`, `controlcenter-ingress`
   - Contain: `Host(\`argocd.flink-demo.confluentdemo.local\`)`
   - **MUST** be templated for each cluster

2. **Environment-specific (KIND vs cloud):**
   - `traefik` (DaemonSet + NodePort for KIND)
   - `metrics-server` (insecure TLS for local dev)
   - **SHOULD NOT** be templated (varies by environment)

3. **Optional configuration:**
   - `cfk-operator` (`debug: true`)
   - `kube-prometheus-stack` (resource limits, retention)
   - **CAN** be shared or customized per cluster

## Options Analysis

### Option A: Template All Overlays ❌

**Copy all 17 overlay directories to templates/**

Pros:
- ✅ Complete "just works" experience
- ✅ Users get everything immediately

Cons:
- ❌ Massive duplication (17 dirs × N clusters = bloat)
- ❌ Environment-specific overlays don't transfer (KIND → cloud)
- ❌ Low value for low-frequency operation
- ❌ Template maintenance burden (sync overlay changes)
- ❌ Users may not understand what to change

**Recommendation: ❌ Rejected** - Too much duplication for rare operation

---

### Option B: Set `ignoreMissingValueFiles: true` Globally ⚠️

**Add to all Helm Application templates, no overlay templates**

Pros:
- ✅ No overlay duplication
- ✅ Clean, minimal templates
- ✅ Applications deploy with base values
- ✅ Users add overlays incrementally as needed

Cons:
- ⚠️ Some apps won't work without overlays (ingress hostnames)
- ⚠️ Users must create required overlays manually
- ⚠️ Steeper learning curve

**Recommendation: ⚠️ Partial** - Good foundation, needs documentation

---

### Option C: Hybrid - Critical Overlays Only ⚠️

**Template only cluster-specific overlays (ingress patches)**

Template includes:
- `argocd-ingress/overlays/$CLUSTER_NAME/`
- `vault-ingress/overlays/$CLUSTER_NAME/`
- `controlcenter-ingress/overlays/$CLUSTER_NAME/`

Users create environment-specific:
- `traefik/overlays/$CLUSTER_NAME/` (if needed)
- `metrics-server/overlays/$CLUSTER_NAME/` (if needed)

Pros:
- ✅ Apps with ingress work immediately
- ✅ Minimal template duplication (3 overlays vs 17)
- ✅ Environment-specific settings left to user
- ✅ Reasonable for low-frequency operation

Cons:
- ⚠️ Partial automation (some overlays needed)
- ⚠️ Requires clear documentation

**Recommendation: ⚠️ Viable** - Balances automation vs. duplication

---

### Option D: Documentation-First Approach ✅ **RECOMMENDED**

**Add `ignoreMissingValueFiles: true` + comprehensive docs**

Implementation:
1. Add `ignoreMissingValueFiles: true` to all Helm Application templates
2. Update README.md template with "Creating Overlays" section
3. Document which overlays to create and why
4. Provide copy/paste examples with placeholders

Example README section:
```markdown
## Creating Cluster-Specific Overlays

Most applications work with base configuration. Create overlays for:

### Required for Ingress Access

**ArgoCD Ingress** (if using ArgoCD UI):
```bash
mkdir -p infrastructure/argocd-ingress/overlays/$CLUSTER_NAME
cat > infrastructure/argocd-ingress/overlays/$CLUSTER_NAME/ingressroute-patch.yaml <<EOF
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-server
spec:
  routes:
    - match: Host(\`argocd.$CLUSTER_NAME.$DOMAIN\`)
EOF
```

### Optional - Environment Specific

**Traefik for KIND clusters**:
```bash
# Use DaemonSet + NodePort for KIND
mkdir -p infrastructure/traefik/overlays/$CLUSTER_NAME
cat > infrastructure/traefik/overlays/$CLUSTER_NAME/values.yaml <<EOF
deployment:
  kind: DaemonSet
service:
  type: NodePort
EOF
```
```

Pros:
- ✅ Zero template duplication
- ✅ Users understand what they're creating and why
- ✅ Environment-appropriate (don't copy KIND settings to cloud)
- ✅ Low-frequency operation = acceptable manual step
- ✅ Educational - users learn overlay structure
- ✅ Easy to maintain - no template sync needed

Cons:
- ❌ Not fully automated (requires reading docs)
- ❌ Users must execute additional commands

**Recommendation: ✅ RECOMMENDED** - Best fit for stated requirements

---

## Recommendation

**Implement Option D** with these changes:

### 1. Update Application Templates

Add `ignoreMissingValueFiles: true` to all Helm apps that don't have it:
- `kube-prometheus-stack`
- `cfk-operator`
- `cmf-operator`
- `flink-kubernetes-operator`
- Plus any others missing it

### 2. Enhanced README Template

Add comprehensive "Creating Overlays" section with:
- Quick reference table (overlay → purpose → when needed)
- Copy/paste examples for common overlays
- Clear explanation of base vs. overlay pattern

### 3. Optional: Helper Script (Future Enhancement)

Could create `scripts/new-overlay.sh`:
```bash
./scripts/new-overlay.sh <cluster-name> argocd-ingress <domain>
```

But document first, automate later if needed.

## Why This Approach?

1. **Low frequency** - Matches stated requirement
2. **No duplication** - Avoids template bloat
3. **Educational** - Users understand what they're doing
4. **Flexible** - Works for KIND, cloud, bare metal
5. **Maintainable** - No overlay template sync needed
6. **Appropriate effort** - Manual steps OK for rare operation

## Files to Change

1. `templates/new-cluster/infrastructure/*.yaml.template` - Add `ignoreMissingValueFiles: true`
2. `templates/new-cluster/workloads/*.yaml.template` - Add `ignoreMissingValueFiles: true`
3. `templates/new-cluster/README.md.template` - Add overlay creation guide

## Validation

Test that applications deploy with:
- ✅ Base values only (no overlays)
- ✅ Applications in Progressing/Healthy state
- ⚠️ Note which apps need overlays for full functionality
