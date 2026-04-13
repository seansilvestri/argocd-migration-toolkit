# Quick Start Guide

Get started with your first ArgoCD migration in under 10 minutes.

## Prerequisites

Before starting, ensure you have:

- ✅ **ArgoCD CLI** v3.2+ installed and configured
- ✅ **kubectl** access to both source and target clusters
- ✅ **yq** v4+ for YAML processing
- ✅ **jq** for JSON parsing
- ✅ **Bash** 4.0+ (check with `bash --version`)
- ✅ **Admin access** to both source and target ArgoCD instances

## Step 1: Clone the Repository

```bash
git clone https://github.com/seansilvestri/argocd-migration-toolkit.git
cd argocd-migration-toolkit
```

## Step 2: Create Environment Profile

```bash
# Create envs directory
mkdir -p envs

# Copy example profile
cp examples/env-profiles/example-migration.env envs/my-first-migration.env

# Edit with your details
vi envs/my-first-migration.env
```

**Required fields**:

```bash
SOURCE_CLUSTER=source-cluster-name
SOURCE_KUBECONTEXT=source-k8s-context
SOURCE_ARGO_URL=argocd.source.example.com
SOURCE_ARGO_LOGIN_ARGS="--sso"  # or "--username admin --password ..."

TARGET_CLUSTER=target-cluster-name
TARGET_KUBECONTEXT=target-k8s-context
TARGET_ARGO_URL=argocd.target.example.com
TARGET_ARGO_LOGIN_ARGS="--sso"

SAFE_DELETE_PARENT_APPS="target-cluster-name.apps target-cluster-name.infra-apps"
```

## Step 3: Source Environment

```bash
source scripts/migration/migration-env.sh my-first-migration

# Verify environment loaded
mig_env_info
```

You should see your source/target details printed.

## Step 4: Pre-Migration Validation

### Analyze Compatibility

```bash
# Check source control plane for potential issues
scripts/migration/analyze-migration-compatibility.sh \
    --context $MIG_SOURCE_KUBECONTEXT
```

Review the output for:

- ApplicationSet policies
- Existing finalizers
- Unhealthy applications

### Capture Baseline Snapshots

```bash
# Login to source ArgoCD
mig_login_source_argo

# Capture source state
python3 scripts/validation/argocd_snapshot.py capture \
    --app-of-apps ${MIG_SOURCE_CLUSTER}.apps ${MIG_SOURCE_CLUSTER}.infra-apps \
    --resource-kinds deployments,statefulsets \
    --output-dir snapshots/pre-migration

# Capture pod restart baseline
scripts/migration/monitor-restarts.sh capture \
    --kube-context $MIG_TARGET_KUBECONTEXT \
    --output-prefix snapshots/pre-restarts
```

### Validate Target Control Plane

```bash
# Login to target ArgoCD
mig_login_target_argo

# Run smoke tests (if you have test definitions)
python3 scripts/validation/argocd_validate.py \
    --tests-file your-smoke-tests.yaml \
    --argo-instance $MIG_TARGET_CLUSTER
```

## Step 5: Generate Migration Runbook

```bash
scripts/migration/generate-runbook.sh my-first-migration
```

This creates a detailed runbook at `runbooks/my-first-migration.md` with all commands pre-filled.

## Step 6: Execute Migration

Follow the generated runbook step-by-step. The high-level flow is:

### 6.1 Commit A - Preparation

```bash
scripts/migration/prep-commit-a.sh \
    --cluster ${MIG_SOURCE_CLUSTER} \
    --source app-of-apps/clusters/${MIG_SOURCE_CLUSTER} \
    --target app-of-apps/clusters/${MIG_TARGET_CLUSTER} \
    --app-file apps-${MIG_SOURCE_CLUSTER}.yaml \
    --app-file infra-apps-${MIG_SOURCE_CLUSTER}.yaml

# Review changes
git diff --staged

# Commit and push
git commit -m "Migration: Prepare ${MIG_TARGET_CLUSTER} App-of-Apps"
git push
```

**Wait for both source and target ArgoCD to sync the changes** (or hard refresh them).

### 6.2 Pass 1 - Disarm Source

```bash
# Preview
scripts/migration/disarm-source.sh --dry-run

# Execute
scripts/migration/disarm-source.sh
```

### 6.3 Target Sync

```bash
# Preview
scripts/migration/sync-target-apps.sh --dry-run

# Execute
scripts/migration/sync-target-apps.sh
```

**Verify target is healthy** in ArgoCD UI before proceeding.

### 6.4 Pass 2 - Cleanup Source

```bash
# Preview
scripts/migration/cleanup-source.sh --dry-run

# Execute (validates target health first)
scripts/migration/cleanup-source.sh
```

### 6.5 Commit B - Finalize

```bash
scripts/migration/prep-commit-b-cleanup.sh \
    --app-file apps-${MIG_SOURCE_CLUSTER}.yaml \
    --app-file infra-apps-${MIG_SOURCE_CLUSTER}.yaml

# Review changes
git diff --staged

# Commit and push
git commit -m "Migration: Cleanup ${MIG_TARGET_CLUSTER} legacy manifests"
git push
```

## Step 7: Post-Migration Verification

### Capture Post-Migration State

```bash
# Login to target ArgoCD
mig_login_target_argo

# Capture target state
python3 scripts/validation/argocd_snapshot.py capture \
    --app-of-apps ${MIG_TARGET_CLUSTER}.apps ${MIG_TARGET_CLUSTER}.infra-apps \
    --resource-kinds deployments,statefulsets \
    --output-dir snapshots/post-migration

# Compare before/after
python3 scripts/validation/argocd_snapshot.py diff \
    --before snapshots/pre-migration \
    --after snapshots/post-migration
```

### Verify Zero Downtime

```bash
# Capture post-migration pod restarts
scripts/migration/monitor-restarts.sh capture \
    --kube-context $MIG_TARGET_KUBECONTEXT \
    --output-prefix snapshots/post-restarts

# Compare restart counts
scripts/migration/monitor-restarts.sh diff \
    --before snapshots/pre-restarts.json \
    --after snapshots/post-restarts.json
```

**Expected result**: Zero pod restarts (restart count delta = 0).

### Spot Check Workloads

```bash
# Check pods are healthy
kubectl get pods -A --context $MIG_TARGET_KUBECONTEXT

# Verify ArgoCD shows all apps healthy
argocd app list
```

## 🎉 Success!

You've completed your first zero-downtime ArgoCD migration!

## Next Steps

- Review [Migration Guide](migration-guide.md) for detailed explanations
- Check [Troubleshooting](troubleshooting.md) if you hit issues
- Read [Architecture](architecture.md) to understand design decisions

## Common Issues

### "App-of-Apps not syncing"

**Solution**: Hard refresh the root App-of-Apps in ArgoCD UI or run:

```bash
argocd app get root-app-of-apps --hard-refresh
```

### "Finalizers keep reappearing"

**Solution**: This is normal for apps with post-delete hooks (like Kyverno). The cleanup script handles this automatically by checking finalizers immediately before deletion.

### "Target shows OutOfSync"

**Solution**: This is expected during Commit A phase. Target apps start paused (auto-sync disabled) and will sync during the "Target Sync" step.

## Need Help?

- Check [Troubleshooting Guide](troubleshooting.md)
- Open a [GitHub Issue](https://github.com/yourusername/argocd-migration-toolkit/issues)
- Start a [Discussion](https://github.com/yourusername/argocd-migration-toolkit/discussions)
