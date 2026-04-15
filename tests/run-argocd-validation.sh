#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source common test library
# shellcheck source=tests/lib/test-common.sh
source "${SCRIPT_DIR}/lib/test-common.sh"

echo "🔄 Running ArgoCD Validation Test"
echo "===================================="
echo ""

# Source environment
echo "📋 Loading test environment..."
cd "${REPO_ROOT}"
# shellcheck source=/dev/null
export MIG_ALLOW_EXTERNAL_ENV=true
source scripts/migration/migration-env.sh "${SCRIPT_DIR}/test-configs/standard.env"

# Setup port forwards and get passwords
setup_port_forwards
trap cleanup_port_forwards EXIT
get_argocd_passwords

# Step 1: Run validation script on target ArgoCD
echo ""
echo "🧪 Running ArgoCD validation script on target..."
cd "${REPO_ROOT}"
python3 scripts/validation/argocd_validate.py \
  --tests-file "${SCRIPT_DIR}/test-configs/validation-test.yaml" \
  --argocd-cli "argocd" \
  --login-argo-url "https://localhost:8081" \
  --login-argo-args "--username admin --password ${TARGET_PASSWORD} --insecure"

echo "✅ Validation script completed on target"

# Step 2: Verify results
echo ""
echo "🔍 Verifying results..."

# Check if the script ran successfully
if [ $? -eq 0 ]; then
    echo "✅ Validation test passed: Script executed successfully"
else
    echo "❌ Validation test failed: Script encountered errors"
    exit 1
fi

echo ""
echo "🎉 ArgoCD Validation Test completed successfully!"