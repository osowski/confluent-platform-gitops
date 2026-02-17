# Confluent Platform GitOps Roadmap

All feature development will be tracked in the [Issues](./issues) tab of this repository. The intention of this repository is to evolve modular and composable workloads to easily demonstrate the entirety of Confluent Platform with ease!

## Future Clusters

- AWS EKS demo cluster
- AWS EKS production cluster, utilizing [Karpenter](https://karpenter.sh/)

## Future Workloads

### Kubernetes Platform Components

- Automated mTLS bundles with [trust-manager](https://cert-manager.io/docs/trust/)
- Alternate observability deployment with [VictoriaMetrics](https://github.com/VictoriaMetrics/VictoriaMetrics) instead of `kube-prometheus-stack`
- Automation to side-load required images for KIND clusters
- Add [Kubernetes Dashboard](https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard/) as an optional install

### Confluent Platform
- Kafka Authentication with Basic Authentication
- Kafka Authentication with mTLS

### Kafka Applications

- TODO Elaborate on neccessary baseline use cases for Kafka workloads

### Flink Applications

- TODO Elaborate on neccessary baseline use cases for Flink workloads