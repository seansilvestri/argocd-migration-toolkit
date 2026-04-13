#!/usr/bin/env bash
set -euo pipefail

echo "🧹 Cleaning up ArgoCD Migration Test Environment"
echo ""

# Delete Kind clusters
delete_clusters() {
    echo "🗑️  Deleting Kind clusters..."
    
    kind delete cluster --name source-argocd 2>/dev/null || echo "  source-argocd already deleted"
    kind delete cluster --name target-argocd 2>/dev/null || echo "  target-argocd already deleted"
    kind delete cluster --name workload-cluster 2>/dev/null || echo "  workload-cluster already deleted"
    
    echo "✅ Clusters deleted"
}

# Kill any port forwards
kill_port_forwards() {
    echo ""
    echo "🔌 Killing port forwards..."
    
    pkill -f "kubectl port-forward.*argocd" 2>/dev/null || true
    
    echo "✅ Port forwards killed"
}

# Clean up test artifacts (optional)
clean_artifacts() {
    if [ "${KEEP_ARTIFACTS:-false}" = "true" ]; then
        echo ""
        echo "📦 Keeping test artifacts (KEEP_ARTIFACTS=true)"
        return
    fi
    
    echo ""
    echo "🧹 Cleaning up test artifacts..."
    
    rm -rf test-results/ 2>/dev/null || true
    rm -rf snapshots/ 2>/dev/null || true
    rm -f envs/test-*.env 2>/dev/null || true
    rm -f runbooks/test-*.md 2>/dev/null || true
    
    echo "✅ Artifacts cleaned"
}

# Main execution
main() {
    kill_port_forwards
    delete_clusters
    clean_artifacts
    
    echo ""
    echo "🎉 Cleanup complete!"
    echo ""
    echo "To preserve test artifacts, run:"
    echo "  KEEP_ARTIFACTS=true make test-cleanup"
    echo ""
}

main "$@"
