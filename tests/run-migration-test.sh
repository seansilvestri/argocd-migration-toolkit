#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURE_DIR="${SCRIPT_DIR}/fixtures/standard-app"

# Source common test library
# shellcheck source=tests/lib/test-common.sh
source "${SCRIPT_DIR}/lib/test-common.sh"

echo "🔄 Running Standard Migration Test"
echo "===================================="
echo ""

# Source environment
echo "📋 Loading test environment..."
cd "${REPO_ROOT}"
# shellcheck source=/dev/null
export MIG_ALLOW_EXTERNAL_ENV=true
source scripts/migration/migration-env.sh "${SCRIPT_DIR}/test-configs/standard.env"

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

# Step 1: Initialize Git repository and deploy root apps
initialize_git_repos "${FIXTURE_DIR}" "test-repo"
deploy_root_apps "${FIXTURE_DIR}" "$SOURCE_PASSWORD" "$TARGET_PASSWORD"

# Wait for workload-cluster.apps to be created
echo "  Waiting for workload-cluster.apps to be created..."
for i in {1..30}; do
    if kubectl get application workload-cluster.apps -n argocd --context kind-source-argocd > /dev/null 2>&1; then
        echo "  ✅ workload-cluster.apps created"
        break
    fi
    sleep 2
done

# Step 2: Capture baseline
capture_baseline

# Capture baseline ArgoCD state
echo "  Capturing baseline ArgoCD state..."
argocd login localhost:8080 --username admin --password "$SOURCE_PASSWORD" --insecure > /dev/null 2>&1
python3 scripts/migration/argocd_snapshot.py capture \
    --app-of-apps workload-cluster.apps \
    --output-dir test-results/snapshots/pre-migration

# Step 3: Prep Commit A (prepare target manifests)
echo ""
echo "🧰 Running toolkit script: prep-commit-a.sh"
WORK_DIR="${MIG_MANIFEST_ROOT}"
prep_commit_a "${FIXTURE_DIR}" "${WORK_DIR}" "workload-cluster" \
    "app-of-apps/clusters/source-argocd" \
    "app-of-apps/clusters/target-argocd" \
    "in-cluster" "apps-workload-cluster.yaml"

# Update paths to use working directory
SOURCE_PATH="${WORK_DIR}/app-of-apps/clusters/source-argocd"
TARGET_PATH="${WORK_DIR}/app-of-apps/clusters/target-argocd"

# Step 4: Apply Commit A changes
apply_commit_a_changes "${WORK_DIR}" "workload-cluster.apps"

# Step 5: Disarm source (Pass 1)
echo ""
echo "🔓 Step 5: Disarming source control plane (Pass 1)..."
echo "🧰 Running toolkit script: disarm-source.sh"

cd "${REPO_ROOT}"
echo "y" | bash scripts/migration/disarm-source.sh \
    --source "${SOURCE_PATH}" \
    --cluster workload-cluster \
    --parent-app workload-cluster.apps \
    --include-untracked || true

echo "✅ Source disarmed"

# Step 5.5: Verify disarm (check child app, parent keeps finalizers until Commit B)
verify_disarm "workload-cluster.guestbook"

# Step 6: Sync target
echo ""
echo "🎯 Step 6: Syncing target control plane..."
echo "🧰 Running toolkit script: sync-target-apps.sh"

# Target app should already exist from apply_commit_a_changes
# Now sync the target app itself
bash "${REPO_ROOT}/scripts/migration/sync-target-apps.sh" \
    --app workload-cluster.apps \
    --force

echo "✅ Target synced"

# Step 7: Cleanup source (Pass 2)
echo ""
echo "🧹 Step 7: Cleaning up source control plane (Pass 2)..."
echo "🧰 Running toolkit script: cleanup-source.sh"

# Set login args for cleanup script
export MIG_TARGET_ARGO_LOGIN_ARGS="--username admin --password $TARGET_PASSWORD --insecure"

echo "y" | bash scripts/migration/cleanup-source.sh \
    --source "${SOURCE_PATH}" \
    --cluster workload-cluster \
    --parent-app workload-cluster.apps \
    --include-untracked \
    --target-argo-url localhost:8081 \
    --target-argo-app workload-cluster.apps || true

echo "✅ Source cleaned up"

# Step 7.5: Verify cleanup (parent app is skipped, will be pruned after Commit B)
verify_cleanup "workload-cluster.apps" "kind-source-argocd" "true"

# Step 8: Finalizing migration (Commit B)
echo ""
echo "📝 Step 8: Finalizing migration (Commit B)..."
echo "🧰 Running toolkit script: prep-commit-b-cleanup.sh"

cd "${WORK_DIR}"

bash "${REPO_ROOT}/scripts/migration/prep-commit-b-cleanup.sh" \
    --cluster workload-cluster \
    --source app-of-apps/clusters/source-argocd \
    --target app-of-apps/clusters/target-argocd \
    --app-file apps-workload-cluster.yaml

echo "✅ Commit B complete"

# Step 9: Capture post-migration state
capture_post_migration

# Capture post-migration ArgoCD state
echo "  Capturing post-migration ArgoCD state..."
cd "${REPO_ROOT}"
argocd login localhost:8081 --username admin --password "$TARGET_PASSWORD" --insecure > /dev/null 2>&1
python3 scripts/migration/argocd_snapshot.py capture \
    --app-of-apps workload-cluster.apps \
    --output-dir test-results/snapshots/post-migration

# Step 10: Verify zero-downtime
verify_zero_downtime

print_summary "Standard Migration" \
    "Commit A: Disabled auto-sync and created target manifests" \
    "Disarm: Removed finalizers from source application" \
    "Target synced and healthy" \
    "Cleanup: Deleted source application" \
    "Commit B: Removed source manifests from Git" \
    "ZERO POD RESTARTS - True zero-downtime migration!"
