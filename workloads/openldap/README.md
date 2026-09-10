# openldap

Local LDAP directory for the `flink-demo-rbac` LDAP-backed CP-MDS RBAC spike
([Epic #408](https://github.com/osowski/confluent-platform-gitops/issues/408),
[Task #409](https://github.com/osowski/confluent-platform-gitops/issues/409)).
Replaces Keycloak as CP-MDS's user store for this cluster — see
`docs/architecture.md` and the forthcoming `adrs/0014-ldap-backed-mds-rbac.md`
for the full picture.

## What this deploys

- `osixia/openldap:1.5.0` Deployment + ClusterIP Service in its own
  `openldap` namespace, plain LDAP on port 389 (no LDAPS in this first pass —
  see Security notes below).
- A PostSync Job (`seed-job.yaml`) that idempotently loads the demo directory
  tree from `seed-ldif-configmap.yaml`:

  ```
  dc=confluentdemo,dc=local
  ├── ou=services
  │   ├── uid=mds     (MDS's own bind/search credential — see mds-bind-secret.yaml)
  │   ├── uid=kafka
  │   ├── uid=erp     (KafkaRestClass / REST proxy)
  │   ├── uid=sr       (Schema Registry)
  │   └── uid=c3       (Control Center)
  ├── ou=users
  │   ├── uid=admin           (mail: admin@osow.ski)
  │   ├── uid=user-square
  │   ├── uid=user-circle
  │   ├── uid=user-red
  │   └── uid=user-blue
  └── ou=groups
      ├── cn=admins  (member: admin)
      ├── cn=shapes  (members: user-square, user-circle)
      └── cn=colors  (members: user-red, user-blue)
  ```

  Object classes are plain OpenLDAP (`inetOrgPerson` / `groupOfNames`), not
  Active Directory-flavored — this matters for the CFK
  `services.mds.provider.ldap.configurations` fields wired up in Task #410,
  which must match this schema (`userObjectClass: inetOrgPerson`,
  `groupObjectClass: groupOfNames`, `groupSearchBase: ou=groups,...`, etc.),
  not the AD-style `CN=...,DC=...` examples in Confluent's own docs samples.

## Why a PostSync seed Job instead of image-native LDIF bootstrap

`osixia/openldap` supports mounting custom bootstrap LDIF, but it only
applies on first container start and re-triggering it cleanly on every
ArgoCD sync is fragile. A PostSync `Job` running `ldapadd -c` against the
already-running service is idempotent (continues past "already exists" on
re-sync) and matches this repo's existing pattern for seeding auxiliary
state — see `workloads/mds-keygen/overlays/*/mds-keygen-job.yaml` and
`workloads/keycloak/base/realm-sync-job.yaml`.

## Security notes (demo-only)

- All passwords in `seed-ldif-configmap.yaml` and the two Secrets in this
  directory are **plaintext demo values committed to git** — consistent
  with this cluster's existing convention (Keycloak's realm/client secrets
  are handled the same way; see `workloads/keycloak/base/realm-configmap.yaml`).
  Do not reuse these values outside this demo.
- `mds-ldap-credential` is a **dedicated** bind/search-only principal. Per
  CFK's documented rotation guidance
  (`docs-operator/co-manage-authentication.rst`, "Update MDS user"): if you
  ever rotate it, add a standby user and swap `secretRef`, don't edit this
  Secret's content in place — an in-place password change can leave brokers
  unable to re-authenticate against MDS mid-rolling-restart.
- LDAP traffic is plaintext (port 389, `LDAP_TLS: "false"`) for this first
  pass, matching this cluster's existing internal-traffic posture (Keycloak's
  internal token/JWKS endpoints are plain HTTP too). LDAPS (636, via a
  cert-manager `Certificate` like `workloads/keycloak/base/certificate.yaml`)
  is a documented follow-up, not yet implemented — see Task #410's PR for
  whether it lands there or as a separate hardening task.

## Verify

```bash
kubectl -n openldap get pods
kubectl -n openldap logs job/openldap-seed

# Bind as the MDS credential and confirm search access:
kubectl -n openldap run ldap-test --rm -it --restart=Never \
  --image=osixia/openldap:1.5.0 -- \
  ldapsearch -x -H ldap://openldap.openldap.svc.cluster.local:389 \
    -D "uid=mds,ou=services,dc=confluentdemo,dc=local" -w mds-bind-password \
    -b "dc=confluentdemo,dc=local" "(objectClass=inetOrgPerson)"

# Confirm a demo user can bind with their own credentials:
kubectl -n openldap run ldap-test --rm -it --restart=Never \
  --image=osixia/openldap:1.5.0 -- \
  ldapwhoami -x -H ldap://openldap.openldap.svc.cluster.local:389 \
    -D "uid=user-square,ou=users,dc=confluentdemo,dc=local" -w square123
```

## Render locally

```bash
kubectl kustomize workloads/openldap/overlays/flink-demo-rbac
```

## Cleanup

Deleting the `openldap` Application (or removing it from
`clusters/flink-demo-rbac/workloads/kustomization.yaml`) removes the
namespace and all directory data — there is no persistent volume in this
demo (`emptyDir` for both `/var/lib/ldap` and `/etc/ldap/slapd.d`), so a pod
restart also resets the directory to empty until the seed Job re-runs on the
next ArgoCD sync.
