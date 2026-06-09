# flink-demo-authn Cluster

A Confluent Platform + Apache Flink demo cluster that authenticates every principal via Keycloak OIDC but performs **no authorization** — no MDS, no RBAC. It is a variant of `flink-demo-rbac` with the MDS service and all authorization stripped out.

## Overview

The `flink-demo-authn` cluster provides:

- **Kafka Cluster**: KRaft-based Kafka with OAuth/OIDC authentication (Keycloak) on all listeners and **no authorizer** (any authenticated principal is allowed).
- **Flink Integration**: Confluent Manager for Apache Flink (CMF) authenticating clients via Keycloak OIDC; the CFK operator manages Flink through a `CMFRestClass` using OAuth client-credentials.
- **Monitoring**: Prometheus, Grafana, and Alertmanager with pre-configured dashboards
- **Security**: Keycloak OIDC authentication everywhere; **NO authorization/RBAC, NO MDS** — see [Security Model](#security-model-oidc-authentication-no-authorization) below.
- **Networking**: Traefik ingress controller with local DNS resolution

**Domain**: `*.flink-demo-authn.confluentdemo.local`

## Security Model: OIDC Authentication, NO Authorization

This cluster authenticates every principal via Keycloak OIDC but performs **no authorization**. There is no Kafka authorizer and no MDS/RBAC.

> [!WARNING]
> **Allow-all:** any principal that presents a valid Keycloak token can perform any action on Kafka, Schema Registry, and CMF. Do not use this variant where tenant isolation or least-privilege is required.

### Accessing the platform
- **CLI/REST:** obtain a token directly from Keycloak (client-credentials, or device flow against Keycloak) and pass it as a bearer token. The MDS-hosted `confluent login` device-grant flow used by `flink-demo-rbac` is **not available** here (MDS is removed).
- **Control Center UI:** anonymous access (no login). SSO/OIDC for Control Center requires MDS and is intentionally omitted; C3 still connects to Kafka and Schema Registry using service-account OAuth.
- **What is removed vs. `flink-demo-rbac`:** Kafka `authorization: rbac` + `services.mds`, CMF `authorization` + MDS-coupled auth config, the `mds-keygen` job and `mds-token` secret, all `ConfluentRolebinding` resources, and Control Center's MDS/SSO dependency. Kubernetes RBAC for Flink (`flink-rbac`) is retained — it is unrelated to Confluent authorization.

## Getting Started

> [!TIP]
> **New to this repository?** Start with the [Getting Started for the Uninitiated](../../docs/getting-started-for-the-uninitiated.md) guide for complete step-by-step setup instructions including:
> - Prerequisites and tool installation
> - DNS configuration (`/etc/hosts` setup with IPv6 timeout workaround)
> - Cluster creation and ArgoCD installation
> - Bootstrap and initial deployment
> - Accessing ArgoCD UI

### Deploy Bootstrap

```bash
kubectl apply -f clusters/flink-demo-authn/bootstrap.yaml
```

### Verify Deployment

```bash
# Check bootstrap application
kubectl get application bootstrap -n argocd

# Check all applications
kubectl get applications -n argocd

# Watch sync progress
kubectl get applications -n argocd -w
```

### Manual Sync Applications

<!-- Customize this section for applications that require manual sync in this cluster -->

Some applications require manual sync to ensure operators and namespaces are fully ready.

**Wait for operators to be healthy:**

```bash
# Check CFK operator
kubectl wait --namespace operator --for=condition=Ready pods -l app=confluent-operator --timeout=300s

# Check CMF operator
kubectl wait --namespace operator --for=condition=Ready pods -l app.kubernetes.io/name=confluent-for-apache-flink --timeout=300s

# Check Flink Kubernetes Operator
kubectl wait --namespace operator --for=condition=Ready pods -l app.kubernetes.io/name=flink-kubernetes-operator --timeout=300s
```

**Sync confluent-resources:**

In the ArgoCD UI:
1. Click on `confluent-resources` Application
2. Click **Sync** → **Synchronize**
3. Wait for `Healthy` status (~5-10 minutes)

**Sync flink-resources:**

In the ArgoCD UI:
1. Click on `flink-resources` Application
2. Click **Sync** → **Synchronize**
3. Wait for `Healthy` status (~2-3 minutes)

<!-- Add any additional manual sync steps specific to this cluster -->

## Applications

### Infrastructure Applications

Infrastructure applications are defined in `infrastructure/kustomization.yaml`:

<!-- Update this list to match the actual applications in this cluster -->

- **kube-prometheus-stack-crds** (wave 2) - Prometheus Operator CRDs
- **metrics-server** (wave 5) - Kubernetes Metrics Server
- **traefik** (wave 10) - Ingress controller
- **cert-manager** (wave 20) - TLS certificate management
- **kube-prometheus-stack** (wave 20) - Monitoring stack (Prometheus, Grafana, Alertmanager)
- **trust-manager** (wave 30) - CA certificate distribution
- **vault** (wave 40) - HashiCorp Vault (dev mode)
- **vault-config** (wave 50) - Vault transit engine configuration
- **cert-manager-resources** (wave 75) - ClusterIssuer and certificates
- **argocd-ingress** (wave 80) - Traefik IngressRoute for ArgoCD UI
- **argocd-config** (wave 85) - ArgoCD ConfigMap patches for custom health checks

### Workload Applications

Workload applications are defined in `workloads/kustomization.yaml`:

<!-- Update this list to match the actual applications in this cluster -->

- **namespaces** (wave 100) - Namespace definitions
- **cfk-operator** (wave 105) - Confluent for Kubernetes operator
- **confluent-resources** (wave 110) - Confluent Platform (KRaft, Kafka, Schema Registry, etc.)
- **controlcenter-ingress** (wave 115) - Traefik IngressRoute for Control Center UI
- **flink-kubernetes-operator** (wave 116) - Flink Kubernetes Operator
- **observability-resources** (wave 117) - PodMonitors and Grafana dashboards
- **cmf-operator** (wave 118) - Confluent Manager for Apache Flink
- **flink-resources** (wave 120) - Flink integration resources

## Environment Access

### DNS Configuration

Add these entries to `/etc/hosts`:

```
127.0.0.1  alertmanager.flink-demo-authn.confluentdemo.local
127.0.0.1  argocd.flink-demo-authn.confluentdemo.local
127.0.0.1  cmf.flink-demo-authn.confluentdemo.local
127.0.0.1  controlcenter.flink-demo-authn.confluentdemo.local
127.0.0.1  grafana.flink-demo-authn.confluentdemo.local
127.0.0.1  kafka.flink-demo-authn.confluentdemo.local
127.0.0.1  prometheus.flink-demo-authn.confluentdemo.local
127.0.0.1  schemaregistry.flink-demo-authn.confluentdemo.local
127.0.0.1  vault.flink-demo-authn.confluentdemo.local
```

> [!WARNING]
> If you experience ~5-second timeouts when accessing services, add IPv6 entries as well:
> ```
> ::1  alertmanager.flink-demo-authn.confluentdemo.local
> ::1  argocd.flink-demo-authn.confluentdemo.local
> ::1  cmf.flink-demo-authn.confluentdemo.local
> ::1  controlcenter.flink-demo-authn.confluentdemo.local
> ::1  grafana.flink-demo-authn.confluentdemo.local
> ::1  kafka.flink-demo-authn.confluentdemo.local
> ::1  prometheus.flink-demo-authn.confluentdemo.local
> ::1  schemaregistry.flink-demo-authn.confluentdemo.local
> ::1  vault.flink-demo-authn.confluentdemo.local
> ```

### Services

<!-- Customize URLs and credentials for this cluster's services -->

**ArgoCD UI:**
- **URL**: https://argocd.flink-demo-authn.confluentdemo.local
- **Username**: `admin`
- **Password**: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`

**Control Center:**
- **URL**: https://controlcenter.flink-demo-authn.confluentdemo.local

**Grafana:**
- **URL**: http://grafana.flink-demo-authn.confluentdemo.local
- **Username**: `admin`
- **Password**: `prom-operator`

**Prometheus:**
- **URL**: http://prometheus.flink-demo-authn.confluentdemo.local

**Alertmanager:**
- **URL**: http://alertmanager.flink-demo-authn.confluentdemo.local

**Vault** (dev mode):
- **URL**: http://vault.flink-demo-authn.confluentdemo.local
- **Token**: `root`
- **Warning**: Dev mode - data is not persisted across restarts

**CMF API:**
- **URL**: http://cmf.flink-demo-authn.confluentdemo.local

<!-- Add any additional services or port-forwarding fallbacks specific to this cluster -->

## Authenticating to CMF and Running Flink

CMF in this cluster validates **Keycloak-issued OIDC bearer tokens** (no MDS, no RBAC). You authenticate by obtaining a token from Keycloak and presenting it to the **CMF REST API**.

> [!IMPORTANT]
> **The `confluent flink` CLI does not work against this cluster.** The on-premises `confluent flink` commands authenticate to CMF only via an **MDS login session** or **mTLS client certificates** — neither exists here (MDS is removed; CMF uses OIDC, not mTLS). The CLI has no bearer-token option, so every call returns `401` (verified with Confluent CLI v4.57.0, including with `CONFLUENT_CMF_ACCESS_TOKEN` set). Use the REST API below. See [Using the CLI anyway](#using-the-confluent-flink-cli-anyway-optional) if you need the CLI UX.

### 1. Reach the CMF API

Port-forward CMF (works regardless of ingress / `/etc/hosts`):

```bash
kubectl -n operator port-forward svc/cmf-service 8080:80
```

CMF is now reachable at `http://localhost:8080`, REST base path `/cmf/api/v1`. (Or use the ingress URL `http://cmf.flink-demo-authn.confluentdemo.local`.)

### 2. Get a Keycloak token

Any valid Keycloak token is accepted (no authorization — **allow-all**). The simplest is the `cmf` service client via the client-credentials grant. Port-forward Keycloak in a second terminal:

```bash
kubectl -n keycloak port-forward svc/keycloak 8081:8080
```

```bash
export TOKEN=$(curl -s -X POST \
  http://localhost:8081/realms/confluent/protocol/openid-connect/token \
  -d grant_type=client_credentials \
  -d client_id=cmf -d client_secret=cmf-secret | jq -r .access_token)
```

> The token's `iss` claim is `https://keycloak.flink-demo-authn.confluentdemo.local/realms/confluent` (set by Keycloak's `KC_HOSTNAME`), which matches CMF's `oauthbearer.expected.issuer` — so requesting the token over a port-forward on a different local port is fine.

To authenticate as a **human user** instead of the service client, use the password grant:

```bash
export TOKEN=$(curl -s -X POST \
  http://localhost:8081/realms/confluent/protocol/openid-connect/token \
  -d grant_type=password -d client_id=controlcenter -d client_secret=controlcenter-secret \
  -d username=<user> -d password=<pass> | jq -r .access_token)
```

### 3. Call the CMF REST API

List environments (`shapes-env` and `colors-env` are pre-created by the `flink-resources-rbac` workload):

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/cmf/api/v1/environments | jq .
```

Common endpoints (base `http://localhost:8080/cmf/api/v1`):

| Action | Method + path |
|---|---|
| List / describe environments | `GET /environments`, `GET /environments/{env}` |
| List / create applications | `GET` / `POST /environments/{env}/applications` |
| List compute pools | `GET /environments/{env}/compute-pools` |
| Manage secrets & mappings | `/secrets`, `/environments/{env}/secret-mappings` |
| Kafka catalogs / databases | `/catalogs/kafka`, `/catalogs/kafka/{catalog}/databases` |

Example — create a FlinkApplication in `shapes-env` from a JSON file:

```bash
curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -X POST http://localhost:8080/cmf/api/v1/environments/shapes-env/applications \
  -d @my-application.json | jq .
```

> Keycloak access tokens are short-lived. When a call starts returning `401`, re-run step 2 to refresh `$TOKEN`.

### Using the `confluent flink` CLI anyway (optional)

The CLI cannot send a bearer token, but it can target a local endpoint that injects one. Run a small local reverse proxy that adds `Authorization: Bearer $TOKEN` to every request and forwards to CMF, then point the CLI at the proxy:

```bash
confluent logout    # on-prem flink commands require being logged out of Confluent Cloud
confluent flink environment list --url http://localhost:<proxy-port>
```

This is a local-dev convenience only (the pinned token expires). A maintained helper script is not yet provided — the proper fix is native CLI OIDC support for CMF.

## Cluster Specific Use Cases

- **Authentication without authorization:** see the [Security Model](#security-model-oidc-authentication-no-authorization) above. All OAuth/OIDC tokens are issued by Keycloak and validated directly against its JWKS endpoint (no MDS-signed tokens).
- **CMF access:** the CFK operator authenticates to CMF via a `CMFRestClass` using OAuth client-credentials; human/automation clients use the **CMF REST API with a Keycloak bearer token** — see [Authenticating to CMF and Running Flink](#authenticating-to-cmf-and-running-flink). The `confluent flink` CLI is **not** usable here (no bearer-token support).
- **Pre-created Flink resources:** the `flink-resources-rbac` workload provisions Flink environments, applications, and the CP Flink SQL Sandbox (shapes/colors demos) — identical to `flink-demo-rbac` but without role bindings.

## Troubleshooting

### ArgoCD Applications Not Syncing

Check parent Application health:

```bash
kubectl get application infrastructure-apps --namespace argocd -o yaml
kubectl get application workloads-apps --namespace argocd -o yaml
```

Verify Application manifests exist:

```bash
ls -la ./clusters/flink-demo-authn/infrastructure/
ls -la ./clusters/flink-demo-authn/workloads/
```

### Pods Not Starting

Check pod status and events:

```bash
kubectl get pods --namespace <namespace> --output wide
kubectl describe pod <pod-name> --namespace <namespace>
```

Check resource availability:

```bash
kubectl top nodes
kubectl top pods --all-namespaces
```

### Ingress Not Accessible

Verify kind port mappings:

```bash
docker ps | grep flink-demo-authn
```

Should show port mappings: `0.0.0.0:80->30080/tcp, 0.0.0.0:443->30443/tcp`

Check Traefik IngressRoutes:

```bash
kubectl get ingressroute --all-namespaces
```

### Certificate Issues

Check cert-manager resources:

```bash
kubectl get certificates --all-namespaces
kubectl get certificaterequests --all-namespaces
kubectl get clusterissuers
```

### CFK Components Not Deploying

Check operator logs:

```bash
kubectl logs --namespace operator deployment/confluent-operator --tail=100
```

Verify CRDs installed:

```bash
kubectl get crd | grep platform.confluent.io
```

### Validation Script

Run the comprehensive validation script:

```bash
./scripts/validate-cluster.sh flink-demo-authn --verbose
```

## Cleanup

Remove the kind cluster:

```bash
kind delete cluster --name flink-demo-authn
```

Stop the container runtime (if using Colima):

```bash
colima stop
```
