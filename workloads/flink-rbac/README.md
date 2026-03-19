# Flink RBAC Resources

This workload provides Kubernetes-level RBAC for the flink-demo-rbac cluster, enabling namespace-level isolation for shapes and colors user groups.

## Overview

### Namespaces

- **flink-shapes** - Dedicated namespace for shapes group users
- **flink-colors** - Dedicated namespace for colors group users

### RBAC Model

Each group gets:

**Full permissions in their namespace:**
- All Flink Kubernetes Operator resources (flink.apache.org)
- All CFK Flink resources (platform.confluent.io: FlinkEnvironment, FlinkApplication, CMFRestClass)
- All core Kubernetes resources (pods, services, configmaps, secrets, etc.)
- All apps resources (deployments, statefulsets, etc.)
- All batch resources (jobs, cronjobs)

**Read-only access to shared namespaces:**
- kafka namespace - Read all Confluent Platform resources and core resources
- flink namespace - Read all Flink and CFK resources and core resources

**Admin user:**
- Full cluster-wide access to all Flink, CFK, and Kubernetes resources
- Can manage RBAC resources

## Important: CMF Internal RBAC

**Kubernetes RBAC (this workload) handles:**
- Namespace-level isolation (shapes vs colors)
- Access to Kubernetes resources (pods, services, CFK CRDs)
- kubectl command authorization

**CMF Internal RBAC (Issue #87) handles:**
- Authorization to CMF-managed resources (FlinkEnvironments, FlinkApplications accessed via REST API)
- Resources with apiVersion `cmf.confluent.io/v1` (not Kubernetes CRDs)
- Access control via MDS (Metadata Service) and role bindings
- Managed via `confluent iam rbac role-binding create` commands

The two RBAC systems work together:
1. Kubernetes RBAC controls what users can do in Kubernetes (kubectl, CRDs)
2. CMF RBAC controls what users can do via CMF REST API and Confluent CLI
3. Issue #87 will configure CMF to map Keycloak groups to CMF RBAC roles

## Resources Created

### Roles (namespace-scoped)

- **flink-developer** (in flink-shapes) - Full permissions for shapes group
- **flink-developer** (in flink-colors) - Full permissions for colors group
- **kafka-reader** (in kafka) - Read-only access for all Flink developers
- **flink-reader** (in flink) - Read-only access for all Flink developers

### ClusterRole

- **flink-admin** - Full cluster-wide access for administrators

### ServiceAccounts

- **shapes-group** (flink-shapes) - Represents shapes user group
- **colors-group** (flink-colors) - Represents colors user group
- **admin-user** (default) - Represents admin user

### RoleBindings

- shapes-group → flink-developer (flink-shapes) - Full access
- shapes-group → kafka-reader (kafka) - Read access
- shapes-group → flink-reader (flink) - Read access
- colors-group → flink-developer (flink-colors) - Full access
- colors-group → kafka-reader (kafka) - Read access
- colors-group → flink-reader (flink) - Read access

### ClusterRoleBinding

- admin-user → flink-admin - Cluster-wide admin access

## API Groups Used

### platform.confluent.io (CFK)

Confluent for Kubernetes provides these CRDs:
- FlinkEnvironment
- FlinkApplication
- CMFRestClass
- Plus all Confluent Platform resources (Kafka, Connect, SchemaRegistry, etc.)

### flink.apache.org (Flink Kubernetes Operator)

Apache Flink Kubernetes Operator provides:
- FlinkDeployment
- FlinkSessionJob

## Related Issues

- #85 - This issue (Kubernetes RBAC)
- #87 - CMF OAuth and internal RBAC configuration
- #76 - Parent epic for flink-demo-rbac cluster
