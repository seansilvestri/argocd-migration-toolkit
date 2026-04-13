# Testing Guide

How to test the ArgoCD Migration Toolkit in a safe environment before using it in production.

## Overview

Testing the migration toolkit requires:

1. Two ArgoCD instances (source and target)
2. A test workload to migrate
3. Access to both control planes and the workload cluster

## Testing Approaches

### Option 1: Automated Testing with Make (Recommended)

The toolkit includes fully automated testing using Makefile targets. This is the fastest and easiest way to test.

#### Prerequisites

```bash
# Install required tools
brew install kind kubectl argocd python3

# Or on Linux
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# Python 3 is required for snapshot comparison (no additional packages needed)
```

#### Quick Start

```bash
# Run complete test suite (setup → migrate → verify → cleanup)
make test-full               # Standard parent-based migration
make test-full-appset        # ApplicationSet migration
make test-full-path-based    # Path-based discovery migration

# Or run step-by-step for iterative testing:

# 1. Setup clusters and ArgoCD (one-time, ~5-10 minutes)
make test-setup

# 2. Run migration test (fast, can repeat - uses committed fixtures)
make test-run                # Standard migration
make test-run-appset         # ApplicationSet migration
make test-run-path-based     # Path-based discovery

# 3. Verify zero-downtime migration
make test-verify

# 4. Cleanup when done
make test-cleanup
```

#### What Gets Created

The automated test creates:

- **3 Kind clusters**: `kind-source-argocd`, `kind-target-argocd`, `kind-workload-cluster`
- **2 ArgoCD instances**: Installed with `--server-side` to handle large CRDs
- **In-cluster Git servers**: Gitea running in both source and target clusters
- **Workload cluster registration**: Both ArgoCD instances can deploy to workload cluster
- **Test fixtures**: Version-controlled manifests in `tests/fixtures/` (standard-app, simple-app, appset-app)
- **Environment profile**: `envs/test-migration.env` with all required variables

#### Iterative Testing Workflow

The test setup is designed for iteration:

```bash
# Setup once (slow - creates clusters and installs ArgoCD)
make test-setup

# Then iterate quickly (tests use committed fixtures):
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
- Test all migration scenarios with consistent fixtures
- No need to regenerate test repos (fixtures are version-controlled)

### Option 2: Manual Testing with Kind

For more control, you can manually set up the test environment.

#### Setup Test Environment

```bash
# 1. Create three Kind clusters
kind create cluster --name source-argocd
kind create cluster --name target-argocd
kind create cluster --name workload-cluster

# 2. Install ArgoCD on source control plane
kubectl config use-context kind-source-argocd
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Port forward to access UI
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# 3. Install ArgoCD on target control plane
kubectl config use-context kind-target-argocd
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Port forward to access UI (different port)
kubectl port-forward svc/argocd-server -n argocd 8081:443 &

# 4. Register workload cluster in both ArgoCD instances
kubectl config use-context kind-source-argocd
argocd login localhost:8080 --username admin --password <password> --insecure
argocd cluster add kind-workload-cluster --name workload-cluster

kubectl config use-context kind-target-argocd
argocd login localhost:8081 --username admin --password <password> --insecure
argocd cluster add kind-workload-cluster --name workload-cluster
```

#### Create Test Workload

```bash
# Create a simple test application in Git
mkdir -p test-apps/busybox
cat > test-apps/busybox/deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: busybox-test
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: busybox-test
  template:
    metadata:
      labels:
        app: busybox-test
    spec:
      containers:
      - name: busybox
        image: busybox:latest
        command: ['sh', '-c', 'while true; do sleep 3600; done']
EOF

# Initialize Git repo
cd test-apps
git init
git add .
git commit -m "Initial test app"

# Push to GitHub (or use local Git server)
# git remote add origin <your-test-repo>
# git push -u origin main
```

#### Create App-of-Apps Structure

```bash
# Create App-of-Apps manifests
mkdir -p app-of-apps/clusters/source-argocd
mkdir -p app-of-apps/clusters/target-argocd

cat > app-of-apps/clusters/source-argocd/apps-workload-cluster.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: workload-cluster.apps
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: <your-test-repo>
    targetRevision: main
    path: test-apps/busybox
  destination:
    server: https://workload-cluster
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

# Commit App-of-Apps
git add app-of-apps/
git commit -m "Add App-of-Apps structure"
git push
```

#### Run Test Migration (Manual)

If you set up the environment manually, run the migration like this:

```bash
# 1. Environment profile is created automatically by test-setup
# Or create manually:
cat > envs/test-migration.env <<EOF
SOURCE_CLUSTER=source-argocd
SOURCE_KUBECONTEXT=kind-source-argocd
SOURCE_ARGO_URL=localhost:8080
SOURCE_ARGO_LOGIN_ARGS="--username admin --password <password> --insecure"

TARGET_CLUSTER=target-argocd
TARGET_KUBECONTEXT=kind-target-argocd
TARGET_ARGO_URL=localhost:8081
TARGET_ARGO_LOGIN_ARGS="--username admin --password <password> --insecure"

SAFE_DELETE_PARENT_APPS="workload-cluster.apps"
TARGET_ARGO_APP=workload-cluster.apps
EOF

# 2. Run the automated test
./tests/run-migration-test.sh

# 3. Verify results
./tests/verify-migration.sh

# Expected: Zero pod restarts, successful migration
```

#### What the Test Does

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

#### Cleanup Test Environment

```bash
# Delete Kind clusters
kind delete cluster --name source-argocd
kind delete cluster --name target-argocd
kind delete cluster --name workload-cluster
```

### Option 3: Cloud-Based Testing

Use existing cloud infrastructure for more realistic testing.

#### Setup

1. **Create two test ArgoCD instances** in non-production namespaces:

   ```bash
   # Source: argocd-test-source namespace
   # Target: argocd-test-target namespace
   ```

2. **Use a dedicated test cluster** for workloads

3. **Create test applications** that mirror production structure but with minimal resources

#### Test Scenarios

**Scenario 1: Single Application**

- Migrate one simple app (busybox, nginx)
- Verify zero downtime
- Practice rollback

**Scenario 2: Multiple Applications**

- Migrate 5-10 test apps
- Include ApplicationSets
- Test with different sync policies

**Scenario 3: Complex Setup**

- Include apps with finalizers
- Include apps with post-delete hooks
- Test Kyverno policy deployment

### Option 4: Staging Environment

Use your actual staging environment to test before production.

#### Best Practices

1. **Mirror production structure** as closely as possible
2. **Test during business hours** so team can observe
3. **Document everything** - capture screenshots, logs, metrics
4. **Practice rollback** - intentionally trigger rollback scenarios
5. **Time the migration** - understand how long it takes

## Testing Checklist

### Pre-Migration Testing

- [ ] Environment profile loads correctly
- [ ] Both ArgoCD instances are accessible
- [ ] Workload cluster is registered in both instances
- [ ] Test applications deploy successfully
- [ ] Validation smoke tests pass
- [ ] Compatibility analysis runs without errors

### Migration Testing

- [ ] Prep-commit-a.sh generates correct manifests
- [ ] Both control planes sync Commit A changes
- [ ] Disarm-source.sh removes all finalizers
- [ ] Target sync completes successfully
- [ ] Target shows all apps healthy
- [ ] Cleanup-source.sh deletes source resources
- [ ] Source shows no remaining applications

### Post-Migration Testing

- [ ] Zero workload pod restarts
- [ ] Snapshots show identical state
- [ ] Target control plane manages workloads
- [ ] Manual sync/refresh works on target
- [ ] Auto-sync works on target
- [ ] Rollback procedure works (if tested)

## Test Workload Examples

### Minimal Test App

```yaml
# Simple busybox for basic testing
apiVersion: apps/v1
kind: Deployment
metadata:
  name: busybox-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: busybox
  template:
    metadata:
      labels:
        app: busybox
    spec:
      containers:
        - name: busybox
          image: busybox:latest
          command: ["sh", "-c", "while true; do sleep 3600; done"]
```

### Test App with Finalizers

```yaml
# App that has finalizers (like Kyverno)
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-with-finalizer
  finalizers:
    - test-finalizer.example.com
data:
  test: "value"
```

### Test ApplicationSet

```yaml
# ApplicationSet for testing multi-app scenarios
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: test-appset
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - name: app1
          - name: app2
  template:
    metadata:
      name: "{{name}}"
    spec:
      project: default
      source:
        repoURL: <your-repo>
        targetRevision: main
        path: "test-apps/{{name}}"
      destination:
        server: https://workload-cluster
        namespace: default
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

## Automated Testing

### CI/CD Integration

Create a test pipeline that:

1. Spins up Kind clusters
2. Installs ArgoCD
3. Runs migration
4. Validates results
5. Tears down

Example GitHub Actions workflow:

```yaml
name: Test Migration Toolkit

on:
  pull_request:
    branches: [main]

jobs:
  test-migration:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Install tools
        run: |
          curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
          chmod +x ./kind
          sudo mv ./kind /usr/local/bin/kind

          curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
          chmod +x argocd
          sudo mv argocd /usr/local/bin/argocd

      - name: Setup test environment
        run: ./tests/setup-test-env.sh

      - name: Run migration test
        run: ./tests/run-migration-test.sh

      - name: Verify results
        run: ./tests/verify-migration.sh

      - name: Cleanup
        if: always()
        run: ./tests/cleanup-test-env.sh
```

## Troubleshooting Tests

### Kind Cluster Issues

**Problem**: Kind cluster won't start

**Solution**:

```bash
# Check Docker is running
docker ps

# Increase Docker resources (8GB RAM minimum)
# Docker Desktop → Settings → Resources

# Use specific Kind version
kind create cluster --image kindest/node:v1.27.3
```

### ArgoCD Installation Issues

**Problem**: ArgoCD pods crash or won't start

**Solution**:

```bash
# Check pod status
kubectl get pods -n argocd

# Check logs
kubectl logs -n argocd deployment/argocd-server

# Increase resources if needed
kubectl patch deployment argocd-server -n argocd -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-server","resources":{"requests":{"memory":"256Mi","cpu":"100m"}}}]}}}}'
```

### Migration Test Failures

**Problem**: Test migration fails

**Solution**:

1. Check all prerequisites are met
2. Verify Git repository is accessible
3. Ensure clusters are registered correctly
4. Run with `--dry-run` first
5. Check logs in `~/.argocd/` directory

## Best Practices

1. **Start small**: Test with 1-2 apps before scaling up
2. **Use dry-run**: Always preview changes first
3. **Capture everything**: Snapshots, logs, screenshots
4. **Test rollback**: Practice failure scenarios
5. **Document learnings**: Keep notes on what worked/didn't work
6. **Automate**: Create scripts to set up test environments
7. **Repeat**: Run tests multiple times to build confidence

## Next Steps

After successful testing:

1. Document your test results
2. Share findings with team
3. Plan production migration
4. Schedule migration window
5. Prepare rollback plan
6. Execute with confidence!
