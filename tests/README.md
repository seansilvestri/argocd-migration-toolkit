# Test Scripts

Automated test scripts for validating the ArgoCD Migration Toolkit.

## Quick Start

```bash
# Run full test suite (requires Docker)
make test-full               # Test single Application migration
make test-full-appset        # Test ApplicationSet migration
make test-full-path-based    # Test path-based discovery migration

# Or run individual steps
make test-setup              # Setup Kind clusters + ArgoCD (one-time, ~5-10 min)
make test-run                # Execute standard migration test (fast)
make test-run-appset         # Execute ApplicationSet migration test (fast)
make test-run-path-based     # Execute path-based discovery test (fast)
make test-verify             # Verify results
make test-cleanup            # Tear down

# Or call scripts directly
./tests/setup-test-env.sh              # Setup Kind clusters + ArgoCD
./tests/run-migration-test.sh          # Execute standard migration
./tests/run-migration-test-appset.sh   # Execute ApplicationSet migration
./tests/run-migration-test-path-based.sh # Execute path-based migration
./tests/verify-migration.sh            # Verify results
./tests/cleanup-test-env.sh            # Tear down
```

## Iterative Testing Workflow

The test setup is designed for iteration:

```bash
# Setup once (slow - creates clusters and installs ArgoCD)
make test-setup

# Then iterate quickly (all tests use committed fixtures):
make test-run                # Run standard migration (repeatable)
make test-run-appset         # Run ApplicationSet migration (repeatable)
make test-run-path-based     # Run path-based discovery (repeatable)
make test-verify             # Check results

# When done:
make test-cleanup
```

This allows you to:

- Keep clusters running between test runs
- Modify migration scripts and re-test quickly
- Debug issues without recreating infrastructure
- Test all migration scenarios (standard, ApplicationSet, path-based)
- Use version-controlled fixtures for consistent testing

## Prerequisites

- Docker running
- kubectl installed
- ArgoCD CLI installed
- 8GB+ RAM available for Docker
- ~10GB disk space

## Test Environment

The test suite creates:

- **3 Kind clusters**: `kind-source-argocd`, `kind-target-argocd`, `kind-workload-cluster`
- **2 ArgoCD instances**: Installed with `--server-side` to handle large CRDs
- **In-cluster Git server**: Gitea running in both source and target clusters
- **Workload cluster registration**: Both ArgoCD instances can deploy to workload cluster
- **Test fixtures**: Version-controlled test manifests in `tests/fixtures/`
- **Environment profile**: `envs/test-migration.env` with all required variables
- **Port forwards**: ArgoCD servers accessible on localhost:8080 and localhost:8081

## Test Fixtures

All tests use committed fixtures for consistency:

- **`fixtures/standard-app/`** - Standard parent-based migration with cluster-prefix naming
- **`fixtures/simple-app/`** - Path-based discovery without cluster-prefix
- **`fixtures/appset-app/`** - ApplicationSet generating multiple child apps

Fixtures include complete application manifests and are pushed to the in-cluster Gitea server during test execution.

## What the Test Does

The automated test (`make test-run`) performs these steps:

1. **Capture Baseline**: Snapshots ArgoCD state and pod restart counts
2. **Commit A**: Prepares target manifests, disables source auto-sync
3. **Sync Changes**: Applies manifests to both ArgoCD instances
4. **Disarm Source**: Removes finalizers from source Applications
5. **Sync Target**: Ensures target ArgoCD manages workloads
6. **Cleanup Source**: Deletes disarmed Applications from source
7. **Commit B**: Removes source manifests, enables target auto-sync
8. **Capture Post-State**: Snapshots final state for verification

All output is logged to `test-results/test-run-final.log`.

## Test Scenarios

### Standard Migration (`make test-full`)

Tests parent-based migration with cluster-prefix naming:

- Parent app: `workload-cluster.apps`
- Uses `--parent-app` flag for discovery
- Validates auto-sync disabling and finalizer removal
- Verifies zero pod restarts during migration

### ApplicationSet Migration (`make test-full-appset`)

Tests ApplicationSet migration with multiple child apps:

- ApplicationSet: `workload-cluster.guestbook-appset`
- Generates 2 child apps: `workload-cluster.guestbook-dev` and `workload-cluster.guestbook-prod`
- Each deploys to its own namespace
- Validates owner reference management
- Ensures zero downtime across all child applications

### Path-Based Discovery (`make test-full-path-based`)

Tests path-based discovery without parent apps:

- Standalone app: `my-app` (no cluster prefix)
- Uses `--path-based-discovery` flag
- Scans Git directory for application manifests
- Validates migration without App-of-Apps pattern

All tests verify **zero pod restarts** to ensure true zero-downtime migration.

## Shared Test Library

All test scripts use a common library (`tests/lib/test-common.sh`) that provides:

**Git & Deployment:**

- `initialize_git_repos()` - Initialize Git repos in both Gitea servers
- `deploy_and_sync_app()` - Deploy and sync application in source ArgoCD

**Migration Workflow:**

- `prep_commit_a()` - Copy fixture and run prep-commit-a
- `apply_commit_a_changes()` - Apply updated manifests

**Verification:**

- `verify_disarm()` - Verify auto-sync disabled and finalizers removed
- `verify_cleanup()` - Verify application deleted from source
- `verify_zero_downtime()` - Compare restart counts

**Utilities:**

- `setup_port_forwards()` - Set up ArgoCD port forwards
- `capture_baseline()` - Capture pre-migration state
- `wait_for_target_healthy()` - Wait for target app health

See `tests/lib/README.md` for complete documentation.

## Manual Testing

See [Testing Guide](../docs/testing-guide.md) for detailed manual testing instructions.

## CI/CD Integration

These scripts can be integrated into CI/CD pipelines:

```yaml
# Example GitHub Actions
- name: Run migration tests
  run: ./tests/run-full-test.sh
```

## Test Results

Tests generate:

- `test-results/` - Test output and logs
- `test-results/snapshots/` - Pre/post migration snapshots
- `test-results/reports/` - Verification reports

## Troubleshooting

### "Docker not running"

```bash
# Start Docker Desktop or Docker daemon
systemctl start docker  # Linux
open -a Docker         # macOS
```

### "Kind cluster creation failed"

```bash
# Clean up any existing clusters
kind delete clusters --all

# Check Docker resources
docker system df
docker system prune  # If needed
```

### "ArgoCD installation timeout"

```bash
# Increase timeout
kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd

# Check pod status
kubectl get pods -n argocd
kubectl logs -n argocd deployment/argocd-server
```

## Contributing

To add new tests:

1. Create test script in `tests/`
2. Follow naming convention: `test-<scenario>.sh`
3. Update this README
4. Ensure cleanup on failure
