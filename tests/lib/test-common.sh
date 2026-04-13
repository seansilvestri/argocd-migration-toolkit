#!/usr/bin/env bash
# Common functions for ArgoCD migration tests

# Cleanup previous test run for idempotency
cleanup_previous_test() {
    echo "🧹 Cleaning up previous test run..."
    # Standard and appset test apps
    kubectl delete application root.apps workload-cluster.apps -n argocd --context kind-source-argocd 2>/dev/null || true
    kubectl delete application root.apps workload-cluster.apps -n argocd --context kind-target-argocd 2>/dev/null || true
    kubectl delete applicationset workload-cluster.guestbook-appset -n argocd --context kind-source-argocd 2>/dev/null || true
    # Path-based test app
    kubectl delete application my-app -n argocd --context kind-source-argocd 2>/dev/null || true
    kubectl delete application my-app -n argocd --context kind-target-argocd 2>/dev/null || true
    # Clean Git repos
    kubectl exec -n default deployment/git-server --context kind-source-argocd -- \
        rm -rf /var/lib/gitea/repositories/gitea/test-repo.git 2>/dev/null || true
    kubectl exec -n default deployment/git-server --context kind-target-argocd -- \
        rm -rf /var/lib/gitea/repositories/gitea/test-repo.git 2>/dev/null || true
    echo "✅ Cleanup complete"
    echo ""
}

# Initialize Git repository in both source and target Gitea servers
initialize_git_repos() {
    local fixture_dir=$1
    local repo_name=${2:-test-repo}
    
    echo ""
    echo "📸 Initializing Git repository and deploying application..."
    
    # Initialize Git repo in source Gitea with fixtures
    echo "  Initializing repo in source Git server..."
    bash "${SCRIPT_DIR}/init-git-repo.sh" "${fixture_dir}" "${repo_name}"
    
    # Also initialize in target Gitea (for migration)
    echo "  Initializing repo in target Git server..."
    kubectl port-forward svc/git-server -n default 3001:3000 --context kind-target-argocd > /dev/null 2>&1 &
    local target_git_pf_pid=$!
    sleep 3
    
    # Create repo in target Gitea
    kubectl exec -n default deployment/git-server --context kind-target-argocd -- \
        gitea admin user create --admin --username gitea --password gitea123 --email gitea@local.test --must-change-password=false 2>/dev/null || true
    
    curl -s -X DELETE "http://localhost:3001/api/v1/repos/gitea/${repo_name}" -u "gitea:gitea123" > /dev/null 2>&1 || true
    curl -s -X POST "http://localhost:3001/api/v1/user/repos" -u "gitea:gitea123" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${repo_name}\",\"private\":false,\"auto_init\":false}" > /dev/null 2>&1
    
    # Push to target Gitea
    local temp_dir=$(mktemp -d)
    cp -r "${fixture_dir}"/* "$temp_dir/"
    cd "$temp_dir"
    git init > /dev/null 2>&1
    git config user.email "test@test.local"
    git config user.name "Test User"
    git add .
    git commit -m "Initial commit" > /dev/null 2>&1
    git remote add target "http://gitea:gitea123@localhost:3001/gitea/${repo_name}.git"
    GIT_TERMINAL_PROMPT=0 git push -u target master > /dev/null 2>&1
    cd - > /dev/null
    rm -rf "$temp_dir"
    
    kill $target_git_pf_pid 2>/dev/null || true
}

# Deploy root app-of-apps on both source and target ArgoCD
deploy_root_apps() {
    local fixture_dir=$1
    local source_password=$2
    local target_password=$3
    
    # Deploy root app-of-apps on source ArgoCD (it will create workload-cluster.apps)
    echo "  Deploying root app-of-apps on source ArgoCD..."
    kubectl config use-context kind-source-argocd
    kubectl apply -f "${fixture_dir}/app-of-apps/root-apps-source.yaml" > /dev/null
    deploy_and_sync_app "${fixture_dir}/app-of-apps/root-apps-source.yaml" "root.apps" "$source_password"
    
    # Deploy root app-of-apps on target ArgoCD (it will create workload-cluster.apps after Commit A)
    echo "  Deploying root app-of-apps on target ArgoCD..."
    kubectl config use-context kind-target-argocd
    kubectl apply -f "${fixture_dir}/app-of-apps/root-apps-target.yaml" > /dev/null
    argocd login localhost:8081 --username admin --password "$target_password" --insecure > /dev/null 2>&1
    argocd app sync root.apps --timeout 120 > /dev/null 2>&1 || true
}

# Deploy and sync application in source ArgoCD
deploy_and_sync_app() {
    local app_manifest=$1
    local app_name=$2
    local source_password=$3
    
    kubectl config use-context kind-source-argocd
    kubectl apply -f "${app_manifest}"
    
    # Wait for app to sync
    echo "  Waiting for application to sync..."
    sleep 10
    argocd login localhost:8080 --username admin --password "$source_password" --insecure
    argocd app sync "${app_name}" --timeout 120
    
    echo "✅ Application deployed"
}

# Run prep-commit-a workflow (copy fixture to working dir and prepare migration)
prep_commit_a() {
    local fixture_dir=$1
    local work_dir=$2
    local cluster=$3
    local source_path=$4
    local target_path=$5
    local dest_name=$6
    local app_file=$7
    
    echo ""
    echo "📝 Preparing migration (Commit A)..."
    
    # Copy fixture to working directory (prep-commit-a modifies files)
    rm -rf "${work_dir}"
    cp -r "${fixture_dir}" "${work_dir}"
    
    cd "${work_dir}"
    
    # Initialize as Git repo that tracks the existing Gitea repo
    echo "  Initializing work dir as Git repo..."
    git init > /dev/null 2>&1
    git config user.email "test@test.local"
    git config user.name "Test User"
    
    # Ensure port forward to Gitea is active
    if ! nc -z localhost 3000 2>/dev/null; then
        kubectl port-forward svc/git-server -n default 3000:3000 --context kind-source-argocd > /dev/null 2>&1 &
        sleep 2
    fi
    
    # Fetch current state from Gitea
    echo "  Fetching current state from Gitea..."
    git remote add origin "http://gitea:gitea123@localhost:3000/gitea/test-repo.git"
    GIT_TERMINAL_PROMPT=0 git fetch origin > /dev/null 2>&1
    GIT_TERMINAL_PROMPT=0 git reset --hard origin/master > /dev/null 2>&1
    
    # Run prep-commit-a to create target manifests
    bash "${REPO_ROOT}/scripts/migration/prep-commit-a.sh" \
        --cluster "${cluster}" \
        --source "${source_path}" \
        --target "${target_path}" \
        --dest-name "${dest_name}" \
        --app-file "${app_file}"
    
    echo "✅ Commit A prepared (files modified, ready to commit)"
}

# Commit and push changes to Git (both source and target servers)
commit_and_push() {
    local work_dir=$1
    local commit_msg=$2
    
    cd "${work_dir}"
    
    # Set up port forward to source Gitea (if not already active)
    if ! nc -z localhost 3000 2>/dev/null; then
        kubectl port-forward svc/git-server -n default 3000:3000 --context kind-source-argocd > /dev/null 2>&1 &
        sleep 2
    fi
    
    # Set up port forward to target Gitea (if not already active)
    if ! nc -z localhost 3001 2>/dev/null; then
        kubectl port-forward svc/git-server -n default 3001:3000 --context kind-target-argocd > /dev/null 2>&1 &
        sleep 2
    fi
    
    git add .
    git commit -m "${commit_msg}" > /dev/null 2>&1
    
    # Push to source Git server
    GIT_TERMINAL_PROMPT=0 git push origin master > /dev/null 2>&1 || true
    
    # Also push to target Git server (force push since initial commits differ)
    if ! git remote | grep -q "^target$" 2>/dev/null; then
        git remote add target "http://gitea:gitea123@localhost:3001/gitea/test-repo.git" 2>/dev/null || true
    fi
    GIT_TERMINAL_PROMPT=0 git push --force target master > /dev/null 2>&1 || true
    
    sleep 2
}

# Hard refresh and sync root app on both source and target ArgoCD
refresh_root_apps() {
    echo "  Hard refreshing and syncing root app on source and target..."
    
    echo "    Syncing source root app..."
    argocd login localhost:8080 --username admin --password "$SOURCE_PASSWORD" --insecure > /dev/null 2>&1 || true
    argocd app get root.apps --refresh --hard > /dev/null 2>&1 || true
    argocd app sync root.apps --timeout 60 > /dev/null 2>&1 || true
    
    echo "    Syncing target root app..."
    argocd login localhost:8081 --username admin --password "$TARGET_PASSWORD" --insecure > /dev/null 2>&1 || true
    argocd app get root.apps --refresh hard --hard-refresh > /dev/null 2>&1 || true
    sleep 3
    argocd app sync root.apps --timeout 120 > /dev/null 2>&1 || true
    sleep 3
    
    sleep 5
}

# Wait for app auto-sync to be disabled
wait_for_autosync_disabled() {
    local app_name=$1
    
    echo "  Waiting for ${app_name} auto-sync to be disabled..."
    for i in {1..30}; do
        if ! kubectl get application "${app_name}" -n argocd --context kind-source-argocd -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null | grep -q .; then
            echo "  ✅ Auto-sync disabled"
            return 0
        fi
        sleep 2
    done
    
    echo "  ⚠️  Timeout waiting for auto-sync to be disabled"
    return 1
}

# Wait for app to be created on target
wait_for_target_app() {
    local app_name=$1
    
    echo "  Ensuring ${app_name} exists on target..."
    
    # Force another hard refresh and sync of target root app
    argocd login localhost:8081 --username admin --password "$TARGET_PASSWORD" --insecure > /dev/null 2>&1 || true
    argocd app get root.apps --refresh hard --hard-refresh > /dev/null 2>&1 || true
    sleep 3
    argocd app sync root.apps --timeout 120 > /dev/null 2>&1 || true
    sleep 5
    
    # Wait for the app to be created by the root app
    echo "  Waiting for root app to create ${app_name}..."
    for i in {1..60}; do
        if kubectl get application "${app_name}" -n argocd --context kind-target-argocd > /dev/null 2>&1; then
            echo "  ✅ Target app created"
            return 0
        fi
        sleep 3
    done
    
    echo "  ❌ Target app not created after syncing root app"
    echo "  Checking target root app status:"
    argocd app get root.apps 2>&1 | tail -15 || true
    return 1
}

# Apply Commit A changes via Git
apply_commit_a_changes() {
    local work_dir=$1
    local app_name=$2
    
    echo ""
    echo "⏳ Applying Commit A changes..."
    
    # Commit and push to both Git servers
    commit_and_push "${work_dir}" "feat: Commit A - disable auto-sync and create target manifests"
    
    # Hard refresh root apps to pick up changes
    refresh_root_apps
    
    # Wait for auto-sync to be disabled on source
    wait_for_autosync_disabled "${app_name}"
    
    # Wait for target app to be created
    wait_for_target_app "${app_name}"
    
    echo "✅ Commit A changes applied via Git"
}

# Apply Commit B changes via Git
apply_commit_b_changes() {
    local work_dir=$1
    
    echo ""
    echo "⏳ Applying Commit B changes..."
    
    # Commit and push to both Git servers
    commit_and_push "${work_dir}" "feat: Commit B - remove source manifests and enable target auto-sync"
    
    # Hard refresh root apps to pick up changes
    refresh_root_apps
    
    echo "✅ Commit B changes applied via Git"
}

# Setup port forwards for ArgoCD
setup_port_forwards() {
    echo "🔌 Setting up port forwards..."
    kubectl config use-context kind-source-argocd
    kubectl port-forward svc/argocd-server -n argocd 8080:443 > /dev/null 2>&1 &
    SOURCE_PF_PID=$!
    
    kubectl config use-context kind-target-argocd
    kubectl port-forward svc/argocd-server -n argocd 8081:443 > /dev/null 2>&1 &
    TARGET_PF_PID=$!
    
    sleep 5
    echo "✅ Port forwards active"
    
    # Export for cleanup
    export SOURCE_PF_PID TARGET_PF_PID
}

# Cleanup port forwards
cleanup_port_forwards() {
    echo "🔌 Killing port forwards..."
    kill $SOURCE_PF_PID $TARGET_PF_PID 2>/dev/null || true
}

# Get ArgoCD admin passwords
get_argocd_passwords() {
    SOURCE_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" --context kind-source-argocd | base64 -d)
    TARGET_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" --context kind-target-argocd | base64 -d)
    export SOURCE_PASSWORD TARGET_PASSWORD
}

# Capture baseline pod restart counts
capture_baseline() {
    echo ""
    echo "📸 Capturing baseline state..."
    echo "  Capturing baseline pod restart counts..."
    kubectl config use-context kind-workload-cluster
    bash "${REPO_ROOT}/scripts/migration/monitor-restarts.sh" capture \
        --kube-context kind-workload-cluster \
        --output-prefix "${REPO_ROOT}/test-results/snapshots/pre-restarts"
    echo "✅ Baseline captured"
}

# Capture post-migration pod restart counts
capture_post_migration() {
    echo ""
    echo "📸 Capturing post-migration state..."
    echo "  Capturing post-migration pod state..."
    kubectl config use-context kind-workload-cluster
    bash "${REPO_ROOT}/scripts/migration/monitor-restarts.sh" capture \
        --output-prefix "${REPO_ROOT}/test-results/snapshots/post-restarts" 2>/dev/null || true
    echo "✅ Post-migration state captured"
}

# Verify disarm worked (auto-sync disabled, finalizers removed)
verify_disarm() {
    local app_name=$1
    local context=${2:-kind-source-argocd}
    
    echo ""
    echo "🔍 Verifying disarm..."
    
    kubectl config use-context "$context"
    APP_SYNC=$(kubectl get application "$app_name" -n argocd -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null || echo "null")
    APP_FINALIZERS=$(kubectl get application "$app_name" -n argocd -o jsonpath='{.metadata.finalizers}' 2>/dev/null || echo "[]")
    
    if [ "$APP_SYNC" = "null" ] || [ "$APP_SYNC" = "" ]; then
        echo "  ✅ Application auto-sync disabled"
    else
        echo "  ❌ Application auto-sync still enabled: $APP_SYNC"
        echo "  This is a CRITICAL failure - auto-sync must be disabled for zero-downtime migration"
        return 1
    fi
    
    if [ "$APP_FINALIZERS" = "[]" ] || [ "$APP_FINALIZERS" = "null" ] || [ "$APP_FINALIZERS" = "" ]; then
        echo "  ✅ Application finalizers removed"
    else
        echo "  ❌ Application finalizers still present: $APP_FINALIZERS"
        echo "  This is a CRITICAL failure - finalizers must be removed for zero-downtime migration"
        return 1
    fi
    
    echo "✅ Disarm verification complete"
}

# Verify cleanup (app deleted from source)
# For parent apps, they are intentionally skipped and will be pruned after Commit B
verify_cleanup() {
    local app_name=$1
    local context=${2:-kind-source-argocd}
    local is_parent=${3:-false}
    
    echo ""
    echo "🔍 Verifying cleanup..."
    
    APP_EXISTS=$(kubectl get application "$app_name" -n argocd --context "$context" 2>/dev/null && echo "exists" || echo "deleted")
    
    if [ "$is_parent" = "true" ]; then
        # Parent apps are intentionally skipped during cleanup (pruned after Commit B)
        if [ "$APP_EXISTS" = "exists" ]; then
            echo "  ✅ Parent app still exists (will be pruned after Commit B)"
        else
            echo "  ⚠️  Parent app already deleted (unexpected but not critical)"
        fi
    else
        # Standalone apps should be deleted
        if [ "$APP_EXISTS" = "deleted" ]; then
            echo "  ✅ Application deleted from source"
        else
            echo "  ❌ Application still exists in source - cleanup failed"
            return 1
        fi
    fi
    
    echo "✅ Cleanup verification complete"
}

# Verify zero-downtime (no pod restarts)
verify_zero_downtime() {
    echo ""
    echo "🔬 Verifying zero-downtime migration..."
    
    cd "${REPO_ROOT}"
    
    # Compare restart counts
    echo "  Comparing pod restart counts..."
    bash scripts/migration/monitor-restarts.sh diff \
        --before test-results/snapshots/pre-restarts.json \
        --after test-results/snapshots/post-restarts.json \
        --output test-results/snapshots/restart-comparison.txt
    
    # Check if any pods restarted
    if [ -f test-results/snapshots/restart-comparison.txt ]; then
        # Count lines containing "RESTARTED" (grep returns 1 if no match, so handle gracefully)
        RESTART_COUNT=$(grep "RESTARTED" test-results/snapshots/restart-comparison.txt 2>/dev/null | wc -l | tr -d ' ') || RESTART_COUNT=0
        if [ -z "$RESTART_COUNT" ]; then
            RESTART_COUNT=0
        fi
        
        if [ "$RESTART_COUNT" -gt 0 ]; then
            echo "  ❌ CRITICAL FAILURE: $RESTART_COUNT pod(s) restarted during migration!"
            cat test-results/snapshots/restart-comparison.txt
            return 1
        else
            echo "  ✅ Zero pod restarts - true zero-downtime migration achieved!"
        fi
    fi
}

# Wait for target app to be healthy
wait_for_target_healthy() {
    local app_name=$1
    local max_wait=${2:-60}  # Increased to 60 attempts (2 minutes)
    
    echo "  Waiting for target to be healthy..."
    for i in $(seq 1 "$max_wait"); do
        HEALTH=$(argocd app get "$app_name" -o json 2>/dev/null | jq -r '.status.health.status // "Unknown"')
        if [ "$HEALTH" = "Healthy" ]; then
            echo "  ✅ Target is healthy"
            return 0
        fi
        sleep 2
    done
    
    echo "  ❌ Target did not become healthy within ${max_wait} attempts"
    return 1
}

# Print test summary
print_summary() {
    local test_name=$1
    shift
    local -a summary_items=("$@")
    
    echo ""
    echo "🎉 ${test_name} Test Complete!"
    echo ""
    echo "Summary:"
    for item in "${summary_items[@]}"; do
        echo "  ✅ $item"
    done
    echo ""
}
