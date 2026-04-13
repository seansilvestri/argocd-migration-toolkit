#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURE_DIR="${SCRIPT_DIR}/fixtures/simple-app"

# Source common test library
# shellcheck source=tests/lib/test-common.sh
source "${SCRIPT_DIR}/lib/test-common.sh"

echo "🧪 Running Path-Based Discovery Migration Test"
echo "=============================================="
echo ""

# Use the committed fixture instead of generating
FIXTURE_DIR="${SCRIPT_DIR}/fixtures/simple-app"
SOURCE_PATH="${FIXTURE_DIR}/applications/clusters/source-argocd"
TARGET_PATH="${FIXTURE_DIR}/applications/clusters/target-argocd"

# Source path-based test environment via migration-env.sh
echo "📋 Loading test environment..."
cd "${REPO_ROOT}"
export MIG_ALLOW_EXTERNAL_ENV=true
# shellcheck source=/dev/null
source scripts/migration/migration-env.sh "${SCRIPT_DIR}/test-configs/path-based.env"

# Create test results directory
mkdir -p test-results/snapshots

# Cleanup any previous test run (for idempotency)
cleanup_previous_test

# Setup port forwards and get passwords
setup_port_forwards
trap cleanup_port_forwards EXIT
get_argocd_passwords

# Update migration env with actual passwords
export MIG_TARGET_ARGO_LOGIN_ARGS="--username admin --password $TARGET_PASSWORD --insecure"
export MIG_SOURCE_ARGO_LOGIN_ARGS="--username admin --password $SOURCE_PASSWORD --insecure"

# Step 1: Initialize Git repository and deploy application
initialize_git_repos "${FIXTURE_DIR}" "test-repo"

# Deploy the app (it will sync from Gitea)
SOURCE_PATH="${FIXTURE_DIR}/applications/clusters/source-argocd"
deploy_and_sync_app "${SOURCE_PATH}/my-app.yaml" "my-app" "$SOURCE_PASSWORD"

# Step 2: Capture baseline
capture_baseline

# Step 3: Prep Commit A (prepare target manifests)
echo ""
echo "🧰 Running toolkit script: prep-commit-a.sh"
WORK_DIR="${MIG_MANIFEST_ROOT}"
prep_commit_a "${FIXTURE_DIR}" "${WORK_DIR}" "workload-cluster" \
    "applications/clusters/source-argocd" \
    "applications/clusters/target-argocd" \
    "workload-cluster" "my-app.yaml"

# Update paths to use working directory
SOURCE_PATH="${WORK_DIR}/applications/clusters/source-argocd"
TARGET_PATH="${WORK_DIR}/applications/clusters/target-argocd"

# Step 4: Apply Commit A changes
echo ""
echo "⏳ Applying Commit A changes..."

# Commit and push to both Git servers (no root apps to refresh for path-based)
echo "  Committing and pushing changes to Git..."
commit_and_push "${WORK_DIR}" "feat: Commit A - disable auto-sync and create target manifests"

# Update the Application CRD in the cluster (path-based doesn't use root apps)
echo "  Updating source Application CRD with disabled auto-sync..."
kubectl apply -f "${WORK_DIR}/applications/clusters/source-argocd/my-app.yaml" --context kind-source-argocd

# Wait for auto-sync to be disabled on source
wait_for_autosync_disabled "my-app"

# Create target app from the manifest that's now in Git
# (Path-based test doesn't use root apps, so we apply the Application CRD directly)
kubectl apply -f "${WORK_DIR}/applications/clusters/target-argocd/my-app.yaml" --context kind-target-argocd

echo "✅ Commit A changes applied via Git"

# Step 5: Disarm source with path-based discovery (Pass 1)
echo ""
echo "🔓 Step 5: Disarming source with path-based discovery (Pass 1)..."
echo "🧰 Running toolkit script: disarm-source.sh"

cd "${REPO_ROOT}"

# Use --path-based-discovery instead of --parent-app, auto-confirm with echo "y"
echo "y" | bash scripts/migration/disarm-source.sh \
    --source "${SOURCE_PATH}" \
    --cluster workload-cluster \
    --path-based-discovery

echo "✅ Path-based discovery disarm complete"

# Step 6: Verify disarm worked
verify_disarm "my-app"

# Step 7: Sync target
echo ""
echo "🎯 Step 7: Syncing target control plane..."
echo "🧰 Running toolkit script: sync-target-apps.sh"

# Target app should already exist from apply_commit_a_changes
# Now sync the target app itself
bash "${REPO_ROOT}/scripts/migration/sync-target-apps.sh" \
    --app my-app \
    --force

echo "✅ Target synced"

# Step 8: Cleanup source with path-based discovery (Pass 2)
echo ""
echo "🧹 Step 8: Cleaning up source with path-based discovery (Pass 2)..."
echo "🧰 Running toolkit script: cleanup-source.sh"

# Set login args for cleanup script
export MIG_TARGET_ARGO_LOGIN_ARGS="--username admin --password $TARGET_PASSWORD --insecure"

echo "y" | bash scripts/migration/cleanup-source.sh \
    --source "${SOURCE_PATH}" \
    --cluster workload-cluster \
    --path-based-discovery \
    --target-argo-url localhost:8081 \
    --target-argo-app my-app || true

echo "✅ Path-based discovery cleanup complete"

# Step 9: Verify cleanup
verify_cleanup "my-app"

# Step 10: Commit B - Finalize migration
echo ""
echo "📝 Step 10: Finalizing migration (Commit B)..."
echo "🧰 Running toolkit script: prep-commit-b-cleanup.sh"

cd "${WORK_DIR}"

# Run prep-commit-b to remove source manifests
bash "${REPO_ROOT}/scripts/migration/prep-commit-b-cleanup.sh" \
    --cluster workload-cluster \
    --source applications/clusters/source-argocd \
    --target applications/clusters/target-argocd \
    --app-file my-app.yaml

# Apply Commit B changes via Git (no root apps to refresh for path-based)
echo ""
echo "⏳ Applying Commit B changes..."
commit_and_push "${WORK_DIR}" "feat: Commit B - remove source manifests and enable target auto-sync"

# Update the target Application CRD to re-enable auto-sync (path-based doesn't use root apps)
echo "  Updating target Application CRD to re-enable auto-sync..."
kubectl apply -f "${WORK_DIR}/applications/clusters/target-argocd/my-app.yaml" --context kind-target-argocd

echo "✅ Commit B changes applied via Git"
echo "✅ Commit B complete - source manifests removed"

# Step 11: Capture post-migration state
capture_post_migration

# Step 12: CRITICAL - Verify zero-downtime (no pod restarts)
verify_zero_downtime

print_summary "Path-Based Discovery" \
    "In-cluster Git server (Gitea) working" \
    "ArgoCD syncing from Gitea" \
    "Path-based discovery found application without cluster-prefix" \
    "Commit A: Disabled auto-sync and created target manifests" \
    "Disarm: Removed finalizers from source application" \
    "Target synced and healthy" \
    "Cleanup: Deleted source application" \
    "Commit B: Removed source manifests from Git" \
    "ZERO POD RESTARTS - True zero-downtime migration!"
