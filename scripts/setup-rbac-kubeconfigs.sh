#!/usr/bin/env bash
#
# Generate kubeconfig contexts for flink-demo-rbac cluster users
# This script creates ServiceAccount-based kubeconfigs for testing RBAC before OIDC is configured
#
# Usage: ./scripts/setup-rbac-kubeconfigs.sh [cluster-name]
#
# Default cluster: flink-demo-rbac
#

set -euo pipefail

# Configuration
CLUSTER_NAME="${1:-flink-demo-rbac}"
OUTPUT_DIR="${HOME}/.kube/flink-rbac"
CONTEXT_NAME="${CLUSTER_NAME}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# User groups
SHAPES_USERS=("user-square" "user-circle" "user-triangle" "user-trapezoid" "user-diamond")
COLORS_USERS=("user-red" "user-green" "user-orange" "user-blue" "user-yellow")
ADMIN_USER="admin"

echo -e "${GREEN}=== Flink RBAC Kubeconfig Generator ===${NC}"
echo "Cluster: ${CLUSTER_NAME}"
echo "Output directory: ${OUTPUT_DIR}"
echo ""

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Get cluster information
echo -e "${YELLOW}Getting cluster information...${NC}"
CLUSTER_ENDPOINT=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CLUSTER_CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

echo "Cluster endpoint: ${CLUSTER_ENDPOINT}"
echo ""

# Function to create kubeconfig for a user
create_kubeconfig() {
    local username=$1
    local serviceaccount=$2
    local namespace=$3
    local default_namespace=$4

    echo -e "${YELLOW}Creating kubeconfig for ${username}...${NC}"

    # Create ServiceAccount token secret
    local token_secret_name="${serviceaccount}-token-${username}"

    # Create token Secret
    kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: ${token_secret_name}
  namespace: ${namespace}
  annotations:
    kubernetes.io/service-account.name: ${serviceaccount}
type: kubernetes.io/service-account-token
EOF

    # Wait for token to be populated
    local max_attempts=30
    local attempt=0
    while [ ${attempt} -lt ${max_attempts} ]; do
        TOKEN=$(kubectl get secret "${token_secret_name}" -n "${namespace}" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
        if [ -n "${TOKEN}" ]; then
            break
        fi
        sleep 1
        ((attempt++))
    done

    if [ -z "${TOKEN}" ]; then
        echo -e "${RED}Failed to get token for ${username}${NC}"
        return 1
    fi

    # Create kubeconfig
    local kubeconfig_file="${OUTPUT_DIR}/${username}@${CLUSTER_NAME}.kubeconfig"

    cat > "${kubeconfig_file}" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CLUSTER_CA}
    server: ${CLUSTER_ENDPOINT}
  name: ${CLUSTER_NAME}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    namespace: ${default_namespace}
    user: ${username}
  name: ${username}@${CLUSTER_NAME}
current-context: ${username}@${CLUSTER_NAME}
users:
- name: ${username}
  user:
    token: ${TOKEN}
EOF

    echo -e "${GREEN}✓ Created: ${kubeconfig_file}${NC}"
}

# Create kubeconfigs for shapes group
echo -e "${GREEN}Creating kubeconfigs for shapes group...${NC}"
for user in "${SHAPES_USERS[@]}"; do
    create_kubeconfig "${user}" "shapes-group" "flink-shapes" "flink-shapes"
done
echo ""

# Create kubeconfigs for colors group
echo -e "${GREEN}Creating kubeconfigs for colors group...${NC}"
for user in "${COLORS_USERS[@]}"; do
    create_kubeconfig "${user}" "colors-group" "flink-colors" "flink-colors"
done
echo ""

# Create kubeconfig for admin
echo -e "${GREEN}Creating kubeconfig for admin...${NC}"
create_kubeconfig "${ADMIN_USER}" "flink-admin" "default" "default"
echo ""

# Summary
echo -e "${GREEN}=== Summary ===${NC}"
echo "Created 11 kubeconfig files in ${OUTPUT_DIR}/"
echo ""
echo -e "${GREEN}=== Usage Instructions ===${NC}"
echo ""
echo "Test shapes group user:"
echo "  export KUBECONFIG=${OUTPUT_DIR}/user-square@${CLUSTER_NAME}.kubeconfig"
echo "  kubectl get pods -n flink-shapes"
echo "  kubectl get pods -n flink-colors  # Should be forbidden"
echo ""
echo "Test colors group user:"
echo "  export KUBECONFIG=${OUTPUT_DIR}/user-red@${CLUSTER_NAME}.kubeconfig"
echo "  kubectl get pods -n flink-colors"
echo "  kubectl get pods -n flink-shapes  # Should be forbidden"
echo ""
echo "Test admin:"
echo "  export KUBECONFIG=${OUTPUT_DIR}/admin@${CLUSTER_NAME}.kubeconfig"
echo "  kubectl get pods --all-namespaces"
echo ""
echo "Return to default kubeconfig:"
echo "  unset KUBECONFIG"
echo ""
echo -e "${GREEN}Done!${NC}"
