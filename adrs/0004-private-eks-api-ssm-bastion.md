# 4. Private EKS API Endpoint with SSM+SOCKS5 Bastion

Date: 2026-04-22

## Status

Accepted

## Context

When provisioning the eks-demo EKS cluster, we had to decide how to expose the Kubernetes API endpoint. EKS gives you three options: public-only, public-and-private, or private-only. Public access means the API endpoint is reachable from the internet — authenticated, but reachable. Private-only means it is only accessible from within the VPC.

For a demo cluster that is created, destroyed, and recreated frequently, the risk surface of a public API endpoint is unnecessary overhead. The broader concern is operational exposure: a misconfigured IAM policy, an overly permissive access entry, or a leaked kubeconfig can all result in unauthorized cluster access when the endpoint is public. Reducing the reachable surface to VPC-internal-only eliminates that class of risk entirely.

At the same time, developers and operators need `kubectl` access to the cluster from their local machines. This creates a genuine tension — the endpoint can't be public, but it also can't be completely unreachable. The common solutions are:

1. **VPN**: Establish a VPN connection into the VPC (OpenVPN, AWS Client VPN, etc.)
2. **Jump box with SSH**: SSH tunnel through a bastion with a public IP and SSH key management
3. **AWS SSM Session Manager + SOCKS5 proxy**: Port-forward to a bastion with no public IP, using AWS's control plane as the transport layer

We chose Option 3. AWS SSM Session Manager allows port-forwarding to any EC2 instance with the SSM agent installed, without requiring the instance to have a public IP or any inbound security group rules. The bastion runs 3proxy, which provides a SOCKS5 proxy on `localhost:1080`. Operators set `HTTPS_PROXY=socks5://localhost:1080` in their terminal, and all `kubectl` traffic routes through the tunnel transparently.

## Decision

Use a private-only EKS API endpoint. Provide developer and operator access via AWS SSM Session Manager port-forwarding to a bastion EC2 instance running 3proxy as a SOCKS5 proxy. The bastion has no public IP address and no inbound security group rules.

## Consequences

### Positive

- **Reduced attack surface**: The Kubernetes API is not reachable from the internet under any circumstances, regardless of what other mistakes might be made with IAM or access entries
- **No SSH key management**: SSM authentication relies on IAM credentials, eliminating the operational burden of SSH key distribution, rotation, and revocation
- **Audit trail**: All SSM sessions are logged to CloudWatch, providing a clear and tamper-evident record of who accessed the cluster and when
- **No inbound rules required**: The bastion security group has zero inbound rules, which removes a common misconfiguration vector entirely

### Negative

- **Tunnel required for all access**: Every operator must start the SSM tunnel before running any `kubectl` commands; forgetting to start it produces confusing timeout behavior rather than a clear authentication failure
- **SSM plugin dependency**: The local machine must have the AWS Session Manager plugin installed alongside the AWS CLI — it is a separate install and is not bundled with the CLI itself
- **CI/CD complexity**: Automated pipelines need SSM access and the tunnel setup baked into their workflow before any in-cluster operations can run
- **3proxy built from source**: Amazon Linux 2023 does not include 3proxy in its default package repositories; the bastion user-data script builds it from a pinned release tag at boot, adding a few minutes to the first-boot provisioning time

### Neutral

- **Access entries still required**: A private endpoint does not eliminate the need for EKS access entry management; each operator still needs an access entry with the appropriate policy association before they can interact with the cluster
- **Same kubeconfig workflow**: `aws eks update-kubeconfig` works exactly the same as it does for public-endpoint clusters; the only additional requirement is setting `HTTPS_PROXY` in the operator's shell before running `kubectl`

## References

- [eks-demo Terraform module](../terraform/eks-demo/)
- [eks-demo cluster README](../terraform/eks-demo/README.md)
- [AWS SSM Session Manager Port Forwarding](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-sessions-start.html)
- [ADR-0005: Terraform and ArgoCD Cluster Provisioning Split](0005-terraform-argocd-cluster-provisioning-split.md)
- [GitHub Issue #24](https://github.com/osowski/confluent-platform-gitops/issues/24)
