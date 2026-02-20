# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **HashiCorp Vault for secrets management** ([#5](https://github.com/osowski/confluent-platform-gitops/issues/5))
  - Added Vault as infrastructure application (sync-wave 40) in dev mode for demo cluster
  - Enables transit secrets engine for Client-Side Field Level Encryption (CSFLE) operations
  - Deployed via Helm chart from HashiCorp repository (version 0.28.1)
  - Includes Traefik IngressRoute for Vault UI access (vault.flink-demo.confluentdemo.local, sync-wave 45)
  - Post-deployment Kubernetes Job (sync-wave 50) configures transit engine and creates CSFLE encryption key
  - Idempotent configuration using ArgoCD PostSync hook with automatic retry logic
  - Deployed to dedicated vault namespace with self-signed TLS certificate

### Changed
- **Inlined shared checklist from homelab-docs** ([#18](https://github.com/osowski/confluent-platform-gitops/issues/18))
  - Copied all shared checklist items from homelab-docs code review checklist into this repo's `docs/code_review_checklist.md`
  - Added sections: Secrets and Credentials, Input Validation, Authentication and Authorization, Network Security, Defensive Programming, Dependencies, Code Organization, Git and GitHub (Branch Naming, PR Description, Commits), Validation
  - Merged overlapping items in Idempotency, Documentation, Testing, and Common Pitfalls sections
  - Removed all external references to homelab-docs checklist — document is now fully self-contained

### Added
- **trust-manager for CA certificate distribution** ([#16](https://github.com/osowski/confluent-platform-gitops/issues/16))
  - Added cert-manager's trust-manager as infrastructure application (sync-wave 30)
  - Enables automatic distribution of trust bundles (CA certificates) across cluster namespaces
  - Deployed to cert-manager namespace alongside cert-manager
  - Version v0.20.3 via OCI Helm chart from Jetstack (quay.io/jetstack/charts/trust-manager)
  - Deployed after cert-manager (wave 20) to ensure CRDs are available
- **CFK component sync-wave ordering for optimal startup time** ([#3](https://github.com/osowski/confluent-platform-gitops/issues/3))
  - Added ArgoCD sync-wave annotations to CFK resource manifests in `workloads/confluent-resources/base/`
  - Dependency chain: KRaftController (wave 0) → Kafka (wave 10) → SchemaRegistry/Connect (wave 20) → ControlCenter/KafkaTopic (wave 30)
  - Added custom Lua health checks for 5 CFK resource types (KRaftController, Kafka, SchemaRegistry, Connect, ControlCenter) to `argocd-cm` ConfigMap
  - Health checks evaluate `status.state == "RUNNING"` to gate sync-wave progression
  - Eliminates unnecessary retry loops by ensuring components start in correct dependency order
  - ADR-0002 documents the architectural decision

## [0.2.0] - 2026-02-14

### Added
- **Release tagging and version-pinned deployments** ([#7](https://github.com/osowski/confluent-platform-gitops/issues/7))
  - End-to-end release orchestrator (`scripts/release.sh`) automates the full release workflow in a single command
  - Release preparation script (`scripts/prepare-release.sh`) automates version pinning across all Application manifests
  - Script pins `targetRevision` only for sources matching this repository's URL (safe for multi-source Applications with external Helm charts)
  - Two-commit workflow: changelog and version pinning are separate commits; pinning is reverted before merge to keep `main` on `HEAD`
  - `--dry-run` flag on `release.sh` and `--verify` flag on `prepare-release.sh` for safe previewing
  - Confirmation prompt before pushing to remote; all prior steps are local and reversible
  - Error recovery instructions printed on failure
  - Documentation: `docs/release-process.md` with complete release and deployment workflows
  - ADR-0003: Documents the release versioning strategy decision
  - Updated `docs/bootstrap-procedure.md` and `docs/cluster-onboarding.md` with version-pinning guidance

### Changed
- **Refactored `prepare-release.sh` to use `yq` for YAML pinning** ([#7](https://github.com/osowski/confluent-platform-gitops/issues/7))
  - Replaced fragile `sed` patterns with structured `yq` commands for `targetRevision` pinning
  - `yq` approach is structurally aware, doesn't depend on line ordering or adjacency
  - Safely handles both single-source (`spec.source`) and multi-source (`spec.sources[]`) Applications
  - Only pins sources matching this repository's URL (external Helm chart versions unchanged)
  - Removed release branch validation from `prepare-release.sh` (handled by `release.sh` orchestrator)
  - Added `--verify` flag for dry-run validation of pinning targets

### Changed
- **Repository migration from homelab-argocd**
  - Migrated from [homelab-argocd](https://github.com/osowski/homelab-argocd) to focus on Confluent Platform deployments
  - Removed portcullis and artoo clusters and their overlays
  - Consolidated to single flink-demo cluster as primary deployment target
  - Updated all documentation to reference confluent-platform-gitops repository
  - Removed Longhorn storage component (portcullis-specific)
  - Removed http-echo validation service
  - Repository now focused exclusively on Confluent Platform and Apache Flink workloads
- **Renamed confluent-operator to cfk-operator**
  - Renamed `workloads/confluent-operator` to `workloads/cfk-operator` for clarity
  - Updated Application name from `confluent-operator` to `cfk-operator`
  - Updated all documentation references
  - Internal Helm chart references (image names, labels, service accounts) remain unchanged

### Added
- **Longhorn distributed block storage** (#8)
  - Infrastructure: `longhorn` application (sync-wave 15) deployed via Helm
  - Default StorageClass for persistent volume provisioning
  - Configuration optimized for homelab with 2 replicas per volume
  - Deployed to longhorn-system namespace on flink-demo cluster
  - Longhorn UI accessible at `longhorn.flink-demo.confluentdemo.local` via Traefik IngressRoute
  - TLS certificate via cert-manager with self-signed ClusterIssuer
  - IngressRoute and Certificate defined via Helm `extraObjects` feature
  - Prerequisites (open-iscsi) installed on cluster nodes via [homelab-ansible#43](https://github.com/osowski/homelab-ansible/issues/43)
  - No backup configuration (S3, NFS) - homelab environment has no backup requirements
- **Confluent Platform for Apache Flink** (#26)
  - **flink-kubernetes-operator** (sync-wave 116) - Helm-based Flink Kubernetes Operator deployment
    - Manages Flink deployments and jobs on Kubernetes
    - Resources: 2 CPU, 3 GB RAM
    - Deployed to confluent namespace
    - Watches confluent namespace for Flink resources
  - **cmf-operator** (sync-wave 118) - Confluent Manager for Apache Flink (CMF) deployment
    - Central management interface for Flink applications
    - Resources: 2 CPU, 1 GB RAM, 10 GB storage (PVC)
    - SQLite database for metadata persistence
    - Trial license auto-generated for homelab use
  - **flink-resources** (sync-wave 120) - Flink custom resources for integration
    - CMFRestClass for CFK-CMF communication
    - FlinkEnvironment with default settings and Kafka integration
    - Integrates with existing Kafka broker and Schema Registry
    - Conservative resource defaults for homelab (1 CPU, 1 GB per component)
  - Enhanced workloads project RBAC for Flink CRDs
    - Added flink.apache.org CRDs (FlinkDeployment, FlinkSessionJob)
    - Added flink.confluent.io CRDs (CMFRestClass, FlinkEnvironment, FlinkApplication)
  - Documentation: `docs/confluent-flink.md` with architecture and usage guide
- **ArgoCD configuration management** via GitOps (#22)
  - Infrastructure: `argocd-config` application patches ArgoCD ConfigMap
  - Custom health check for Ingress resources (fixes forever "Progressing" status)
  - Traefik on KIND doesn't populate `status.loadBalancer.ingress`, causing false "Progressing" reports
  - Works with manually installed ArgoCD (pre-self-management)
  - Extensible for future ArgoCD customizations (RBAC, SSO, notifications)
- Control Center external access via Traefik IngressRoute with TLS support (#30)
  - Workload: `controlcenter-ingress` with base and cluster-specific overlays
  - Accessible at `controlcenter.{cluster}.confluentdemo.local` for flink-demo and flink-demo clusters
  - Self-signed TLS certificates via cert-manager
  - Deployed in workloads project alongside confluent-resources

### Changed
- **Documentation consolidation with homelab-docs** ([#27](https://github.com/osowski/confluent-platform-gitops/issues/27))
  - Rewrote `docs/code_review_checklist.md` to replace Ansible-specific content with ArgoCD/Kustomize/Helm-relevant checks
  - Added cross-references to [homelab-docs](https://github.com/osowski/homelab-docs) for shared practices, ADR guidelines, and system architecture
  - Updated `adrs/README.md` to reference canonical ADR template and cross-cutting ADRs in homelab-docs
  - Replaced `adrs/0000-template.md` with pointer to canonical template in homelab-docs
  - Added homelab-docs to Related Repositories in README.md
  - Fixed homelab-ansible URL in README.md Related Repositories
  - Updated CLAUDE.md to remove Ansible-specific language and align with ArgoCD codebase

### Added
- **Confluent Platform with Confluent for Kubernetes (CFK) operator**
  - **cfk-operator** (sync-wave 105) - Helm-based CFK operator deployment
    - Namespace-scoped mode for security
    - Creates 22 Confluent Platform CRDs and webhooks
    - Deployed to confluent namespace with 1 replica
    - Resource limits: 500m CPU, 512Mi RAM
  - **confluent-resources** (sync-wave 110) - Kustomize-based Confluent Platform resources
    - KRaft controller (1 replica, 1 CPU, 2GB RAM, 10GB storage)
    - Kafka broker (1 replica, 2 CPU, 4GB RAM, 50GB storage)
    - Schema Registry (1 replica, 0.5 CPU, 1GB RAM)
    - KRaft mode (no ZooKeeper) for simplified architecture
    - Total resource requirements: ~4 CPU, 8GB RAM, 60GB storage
  - Enhanced workloads project RBAC to allow CRD and webhook creation
  - Follows cert-manager two-application pattern (operator + resources)
  - Base manifests with flink-demo cluster overlays
  - Documentation: `docs/confluent-platform.md` with usage guide
- **cert-manager** (sync-wave 20)
  - Helm-based deployment using OCI chart from Quay (v1.19.2)
  - Multi-source pattern with Git-based values files
  - Base configuration enables CRDs only for minimal footprint
  - Cluster overlay for flink-demo-specific settings
  - Essential for TLS certificate management across infrastructure
- **cert-manager-resources** (sync-wave 75)
  - Kustomize-based deployment of certificate management resources
  - Self-signed ClusterIssuer for internal certificate generation
  - Deployed after cert-manager to ensure CRDs are available
  - Provides foundation for internal PKI
- **argocd-ingress** (sync-wave 80)
  - Kustomize-based Traefik IngressRoute for ArgoCD UI access
  - Certificate resource for TLS (argocd.flink-demo.confluentdemo.local)
  - ServersTransport for internal HTTPS communication with ArgoCD
  - Base manifests use placeholder patterns (CLUSTER_NAME.DOMAIN)
  - Cluster overlays patch with specific hostnames
  - Enables secure external access to ArgoCD without port-forwarding
- **kube-prometheus-stack-crds** (sync-wave 2)
  - Standalone Helm deployment for Prometheus Operator CRDs
  - Deployed very early (wave 2) to ensure CRDs available before other components
  - Decoupled from main kube-prometheus-stack deployment (wave 20)
  - Helm values configured to enable only CRDs, disabling all other components
  - Addresses CRD timing issues with ServiceMonitor and PrometheusRule resources
- Comprehensive Helm deployment guide (`docs/adding-helm-workloads.md`)
  - Detailed walkthroughs for infrastructure and workload applications
  - Real-world examples with cert-manager and Grafana
  - Advanced patterns: multi-value files, sync waves, secrets management
  - Comprehensive troubleshooting section with 10+ common scenarios
  - Testing and validation procedures
  - Production-ready best practices
- **Traefik ingress controller** (sync-wave 10)
  - OCI Helm chart deployment with multi-source pattern
  - Base and cluster-specific values configuration
  - Deployed to monitoring namespace
- **kube-prometheus-stack monitoring** (sync-wave 20)
  - Complete monitoring stack with Prometheus, Grafana, Alertmanager
  - Base values with conservative resource limits
  - Portcullis cluster overlay with ingress configuration
  - ServiceMonitor and PrometheusRule CRDs enabled (via separate kps-crds app)
  - Persistent storage for Prometheus, Grafana, and Alertmanager
- **Sync wave annotations** for deployment ordering
  - Bootstrap: wave 0
  - Parent applications: waves 1, 100
  - Infrastructure: waves 10-50
  - Workloads: waves 105+
- **Kustomization files** in cluster directories
  - `clusters/<cluster>/infrastructure/kustomization.yaml` lists infrastructure apps
  - `clusters/<cluster>/workloads/kustomization.yaml` lists workload apps
  - Parent Applications monitor these files for discovery

### Changed
- **ArgoCD self-management deferred to future state**
  - ArgoCD remains as manual installation for now (not self-managed via GitOps)
  - Self-management documentation consolidated for future reference
  - Decision allows focus on infrastructure components first
  - ArgoCD access now provided via argocd-ingress Application (Traefik IngressRoute)
  - See `docs/argocd-self-management.md` for future migration guidance
- **BREAKING: Bootstrap pattern restructured**
  - Moved from `bootstrap/values-<cluster>.yaml` to `clusters/<cluster>/bootstrap.yaml`
  - Bootstrap now uses inline `valuesObject` for cluster configuration
  - Bootstrap deployed as ArgoCD Application with sync-wave 0
  - Enables per-cluster GitOps management of bootstrap configuration
- **Multi-source Application pattern for Helm charts**
  - Infrastructure applications use `sources` (plural) instead of single `source`
  - First source: upstream Helm chart (OCI or HTTP repository)
  - Second source: values files from Git repository using `ref: values`
  - Values referenced with `$values/infrastructure/<component>/...` pattern
  - Replaced raw GitHub URL pattern with multi-source approach
- **Parent Application naming**
  - Changed from `infrastructure-apps` and `workloads-apps` to `infrastructure` and `workloads`
  - Simplified naming convention for clarity
- **Infrastructure component deployment**
  - Moved from future/placeholder to implemented for traefik and kube-prometheus-stack
  - Added `ServerSideApply=true` sync option for CRDs
  - Added retry policies with exponential backoff
- Updated documentation:
  - `docs/architecture.md` - Bootstrap pattern, multi-source applications, sync waves, current state
  - `docs/adding-applications.md` - Multi-source Helm pattern, sync waves, kustomization updates
  - `docs/bootstrap-procedure.md` - New bootstrap Application deployment procedure
  - `docs/cluster-onboarding.md` - Updated for new bootstrap pattern and kustomization files
  - `README.md` - Reference to new Helm deployment guide

## [0.1.0] - 2025-01-XX

### Added
- Initial GitOps repository structure
- Bootstrap Helm chart implementing App of Apps pattern
- ArgoCD Project definitions (infrastructure, workloads)
- Parent Applications for automatic child Application discovery
- http-echo validation service deployment
- Comprehensive documentation:
  - Architecture overview
  - Application deployment guide
  - Bootstrap procedure
  - Cluster onboarding guide
- Architecture Decision Records (ADRs):
  - ADR-0001: App of Apps pattern selection
- Support for flink-demo cluster
- Kustomize base + overlay pattern for applications
- GitOps automation with automated sync, prune, and self-heal

### Security
- ArgoCD RBAC Projects for permission boundaries
- Infrastructure project: Cluster-scoped resource access
- Workloads project: Namespace-scoped resources only
- Secrets excluded from repository (external management)

[Unreleased]: https://github.com/osowski/confluent-platform-gitops/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/osowski/confluent-platform-gitops/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/osowski/confluent-platform-gitops/releases/tag/v0.1.0
