# Test Library

Common functions shared across all ArgoCD migration tests.

## Functions

### Git & Deployment

- `initialize_git_repos(fixture_dir, [repo_name])` - Initialize Git repository in both source and target Gitea servers
- `deploy_and_sync_app(app_manifest, app_name, source_password)` - Deploy and sync application in source ArgoCD

### Migration Workflow

- `prep_commit_a(fixture_dir, work_dir, cluster, source_argo, target_argo, dest_name, app_file)` - Copy fixture and run prep-commit-a
- `apply_commit_a_changes(source_path, target_path, app_file)` - Apply updated source and new target manifests

### Setup & Teardown

- `setup_port_forwards()` - Set up port forwards to ArgoCD servers on localhost:8080 and localhost:8081
- `cleanup_port_forwards()` - Kill port forward processes
- `get_argocd_passwords()` - Retrieve ArgoCD admin passwords from both clusters

### State Capture

- `capture_baseline()` - Capture baseline pod restart counts before migration
- `capture_post_migration()` - Capture post-migration pod restart counts

### Verification

- `verify_disarm(app_name, [context])` - Verify auto-sync disabled and finalizers removed
- `verify_cleanup(app_name, [context], [is_parent])` - Verify application deleted (or skipped if parent)
- `verify_zero_downtime()` - Compare restart counts and verify zero pod restarts

### Utilities

- `wait_for_target_healthy(app_name, [max_wait])` - Wait for target app to become healthy
- `print_summary(test_name, ...items)` - Print formatted test summary

## Usage

Source the library at the beginning of your test script:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source common test library
source "${SCRIPT_DIR}/lib/test-common.sh"

# Your test code here...
setup_port_forwards
trap cleanup_port_forwards EXIT
get_argocd_passwords

# ... run migration steps ...

verify_disarm "my-app"
verify_cleanup "my-app"
verify_zero_downtime

print_summary "My Test" \
    "Step 1 completed" \
    "Step 2 completed" \
    "ZERO POD RESTARTS!"
```

## DRY Principle

This library follows the DRY (Don't Repeat Yourself) principle by extracting common test logic into reusable functions. This:

- **Reduces code duplication** across test scripts
- **Ensures consistency** in verification logic
- **Makes tests easier to maintain** - fix once, apply everywhere
- **Improves readability** - test scripts focus on test-specific logic

## Tests Using This Library

- `run-migration-test.sh` - Standard parent-based migration test
- `run-migration-test-path-based.sh` - Path-based discovery migration test
- `run-migration-test-appset.sh` - ApplicationSet migration test (future)
