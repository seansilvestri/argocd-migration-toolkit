#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "🚀 Setting up ArgoCD Migration Test Environment"
echo ""

# Check prerequisites
check_prerequisites() {
    echo "📋 Checking prerequisites..."
    
    if ! command -v docker &> /dev/null; then
        echo "❌ Docker is not installed or not running"
        exit 1
    fi
    
    if ! docker ps &> /dev/null; then
        echo "❌ Docker daemon is not running"
        exit 1
    fi
    
    if ! command -v kind &> /dev/null; then
        echo "❌ Kind is not installed. Install with: brew install kind"
        exit 1
    fi
    
    if ! command -v kubectl &> /dev/null; then
        echo "❌ kubectl is not installed. Install with: brew install kubectl"
        exit 1
    fi
    
    if ! command -v argocd &> /dev/null; then
        echo "❌ ArgoCD CLI is not installed. Install with: brew install argocd"
        exit 1
    fi
    
    echo "✅ All prerequisites met"
}

# Create Kind clusters
create_clusters() {
    echo ""
    echo "🏗️  Creating Kind clusters..."
    
    # Check if clusters already exist
    if kind get clusters 2>/dev/null | grep -q "source-argocd"; then
        echo "⚠️  Clusters already exist. Cleaning up first..."
        kind delete cluster --name source-argocd 2>/dev/null || true
        kind delete cluster --name target-argocd 2>/dev/null || true
        kind delete cluster --name workload-cluster 2>/dev/null || true
    fi
    
    # Get absolute path to fixtures directory
    local fixtures_path="${SCRIPT_DIR}/fixtures"
    
    # Create Kind config with extraMounts for test fixtures
    local kind_config=$(mktemp)
    cat > "${kind_config}" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
  - hostPath: ${fixtures_path}
    containerPath: /mnt/test-fixtures
    readOnly: true
EOF
    
    echo "  Creating source-argocd cluster with mounted fixtures..."
    kind create cluster --name source-argocd --config "${kind_config}" --wait 60s
    
    echo "  Creating target-argocd cluster with mounted fixtures..."
    kind create cluster --name target-argocd --config "${kind_config}" --wait 60s
    
    echo "  Creating workload-cluster..."
    kind create cluster --name workload-cluster --wait 60s
    
    rm -f "${kind_config}"
    echo "✅ Clusters created"
}

# Install ArgoCD
install_argocd() {
    local cluster_name=$1
    local context="kind-${cluster_name}"
    
    echo ""
    echo "📦 Installing ArgoCD on ${cluster_name}..."
    
    kubectl config use-context "${context}"
    kubectl create namespace argocd 2>/dev/null || true
    # Use --server-side to bypass client-side validation for large CRDs
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side
    
    echo "  Waiting for ArgoCD to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-repo-server -n argocd
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-applicationset-controller -n argocd
    
    echo "✅ ArgoCD installed on ${cluster_name}"
}

# Register workload cluster
register_workload_cluster() {
    local control_plane=$1
    local context="kind-${control_plane}"
    local port=$2
    
    echo ""
    echo "🔗 Registering workload cluster in ${control_plane}..."
    
    kubectl config use-context "${context}"
    
    # Get ArgoCD admin password
    local password
    password=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "admin")
    
    # Port forward ArgoCD server in background
    kubectl port-forward svc/argocd-server -n argocd "${port}:443" > /dev/null 2>&1 &
    local pf_pid=$!
    sleep 5
    
    # Login to ArgoCD
    argocd login "localhost:${port}" --username admin --password "${password}" --insecure
    
    # Get workload cluster info and modify the server URL to use Kind network
    # Kind clusters can communicate via their container names
    local workload_server
    workload_server=$(kubectl config view -o jsonpath="{.clusters[?(@.name=='kind-workload-cluster')].cluster.server}")
    
    # Create service account and get token
    kubectl config use-context kind-workload-cluster
    kubectl create serviceaccount argocd-manager -n kube-system 2>/dev/null || true
    kubectl create clusterrolebinding argocd-manager --clusterrole=cluster-admin --serviceaccount=kube-system:argocd-manager 2>/dev/null || true
    
    # Create token secret
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF
    
    sleep 2
    local token
    token=$(kubectl get secret argocd-manager-token -n kube-system -o jsonpath='{.data.token}' | base64 -d)
    
    # Get CA cert
    local ca_cert
    ca_cert=$(kubectl get secret argocd-manager-token -n kube-system -o jsonpath='{.data.ca\.crt}')
    
    # Switch back to control plane context
    kubectl config use-context "${context}"
    
    # Manually create cluster secret in ArgoCD
    # Use the Kind container network address
    local cluster_server="https://workload-cluster-control-plane:6443"
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: cluster-workload-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: workload-cluster
  server: ${cluster_server}
  config: |
    {
      "bearerToken": "${token}",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "${ca_cert}"
      }
    }
EOF
    
    # Kill port forward
    kill "${pf_pid}" 2>/dev/null || true
    
    echo "✅ Workload cluster registered in ${control_plane}"
}

# Deploy Git server in source cluster
deploy_git_server() {
    echo ""
    echo "📦 Deploying Git server in source-argocd..."
    
    kubectl config use-context kind-source-argocd
    
    # Deploy Git server
    kubectl apply -f "${SCRIPT_DIR}/manifests/git-server.yaml"
    
    # Wait for Git server to be ready
    echo "  Waiting for Git server to be ready..."
    kubectl wait --for=condition=available --timeout=120s deployment/git-server -n default
    
    echo "✅ Git server deployed in source-argocd"
}

# Deploy Git server in target cluster (for path-based discovery tests)
deploy_git_server_target() {
    echo ""
    echo "📦 Deploying Git server in target-argocd..."
    
    kubectl config use-context kind-target-argocd
    
    # Deploy Git server
    kubectl apply -f "${SCRIPT_DIR}/manifests/git-server.yaml"
    
    # Wait for Git server to be ready
    echo "  Waiting for Git server to be ready..."
    kubectl wait --for=condition=available --timeout=120s deployment/git-server -n default
    
    echo "✅ Git server deployed in target-argocd"
}

# Create environment profile (for backward compatibility)
create_env_profile() {
    echo ""
    echo "⚙️  Creating test environment profile..."
    
    mkdir -p envs
    
    # Copy the standard test config to envs/ for backward compatibility
    cp "${SCRIPT_DIR}/test-configs/standard.env" envs/test-migration.env
    
    echo "✅ Environment profile created at envs/test-migration.env"
    echo "   (Copied from tests/test-configs/standard.env)"
}

# Main execution
main() {
    check_prerequisites
    create_clusters
    install_argocd "source-argocd"
    install_argocd "target-argocd"
    deploy_git_server
    deploy_git_server_target
    register_workload_cluster "source-argocd" 8080
    register_workload_cluster "target-argocd" 8081
    create_env_profile
    
    echo ""
    echo "🎉 Test environment setup complete!"
    echo ""
    echo "Clusters created:"
    echo "  - kind-source-argocd (ArgoCD on localhost:8080)"
    echo "  - kind-target-argocd (ArgoCD on localhost:8081)"
    echo "  - kind-workload-cluster"
    echo ""
    echo "In-cluster Git servers:"
    echo "  - Gitea deployed in source-argocd cluster"
    echo "  - Gitea deployed in target-argocd cluster"
    echo ""
    echo "Next steps:"
    echo "  make test-run                # Run standard migration test"
    echo "  make test-run-appset         # Run ApplicationSet migration test"
    echo "  make test-run-path-based     # Run path-based discovery test"
    echo "  make test-verify             # Verify results"
    echo ""
    echo "Or run complete test suites:"
    echo "  make test-full               # Standard migration (setup → test → verify → cleanup)"
    echo "  make test-full-appset        # ApplicationSet migration"
    echo "  make test-full-path-based    # Path-based discovery"
    echo ""
}

main "$@"
