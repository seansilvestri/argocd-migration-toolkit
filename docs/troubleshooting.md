# Troubleshooting Guide

Common issues and solutions for ArgoCD migrations.

## Pre-Migration Issues

### "Repository not found" in Validation

**Symptom**: `argocd_validate.py` fails with repository not found error.

**Solution**:

```bash
# Add repository to ArgoCD
argocd repo add git@github.com:yourorg/repo.git --ssh-private-key-path ~/.ssh/id_rsa

# Or use bootstrap option
python3 scripts/validation/argocd_validate.py \
    --tests-file tests.yaml \
    --bootstrap-repo-config '{"repoURL": "git@github.com:org/repo.git", ...}'
```

### "Cluster not registered" in ArgoCD

**Symptom**: ArgoCD doesn't know about target cluster.

**Solution**:

```bash
# Add cluster to ArgoCD
argocd cluster add my-cluster-context

# Verify
argocd cluster list
```

### Environment Profile Not Loading

**Symptom**: `MIG_*` variables not set after sourcing.

**Solution**:

```bash
# Use correct path (relative to envs/ directory)
source scripts/migration/migration-env.sh my-migration

# Or use full path
source scripts/migration/migration-env.sh /path/to/my-migration.env

# Verify it loaded
mig_env_info
```

## During Migration Issues

### App-of-Apps Not Syncing After Commit A

**Symptom**: Source or target App-of-Apps shows OutOfSync but won't sync.

**Solution**:

```bash
# Hard refresh in ArgoCD UI, or:
argocd app get root-app-of-apps --hard-refresh

# Wait 30 seconds, then check
argocd app get <app-name>
```

**Why**: ArgoCD caches Git state. Hard refresh forces immediate Git poll.

### Finalizers Keep Reappearing

**Symptom**: After removing finalizers, they come back on next check.

**Solution**: This is normal for apps with post-delete hooks (like Kyverno). The cleanup script handles this by:

1. Checking finalizers immediately before each deletion
2. Removing any that reappeared
3. Deleting the resource immediately after

**No action needed** - the script handles this automatically.

### "Application has finalizers" Error During Cleanup

**Symptom**: `cleanup-source.sh` fails saying app still has finalizers.

**Solution**:

```bash
# Check if finalizers were re-added
kubectl get application <app-name> -n argocd -o jsonpath='{.metadata.finalizers}'

# If present, the script should have removed them
# This usually means the app was modified between disarm and cleanup

# Re-run disarm to remove finalizers again
scripts/migration/disarm-source.sh --source ... --cluster ... --parent-app ...

# Then retry cleanup
scripts/migration/cleanup-source.sh --source ... --cluster ... --parent-app ...
```

### Target Shows "Unknown" Health Status

**Symptom**: Target App-of-Apps shows health as "Unknown" or "Missing".

**Solution**: This is expected during migration:

1. **During Commit A**: Target apps are paused (auto-sync disabled)
2. **After Target Sync**: Apps should become Healthy

If still Unknown after sync:

```bash
# Check if apps exist in cluster
kubectl get application -n argocd

# Hard refresh
argocd app get <app-name> --hard-refresh

# Check for errors
argocd app get <app-name>
```

### ApplicationSets Recreating Deleted Apps

**Symptom**: Child apps keep coming back after deletion.

**Solution**: This is the `create-only` trap. The cleanup script handles this by:

1. Deleting ApplicationSets FIRST with `--cascade=orphan`
2. Then deleting orphaned children

If you see this:

```bash
# Verify ApplicationSets are deleted first
kubectl get applicationset -n argocd

# If still present, delete them manually
kubectl delete applicationset <name> -n argocd --cascade=orphan

# Then delete orphaned apps
kubectl delete application <name> -n argocd
```

## Post-Migration Issues

### Workload Pods Restarted

**Symptom**: `monitor-restarts.sh diff` shows non-zero restart delta.

**Investigation**:

```bash
# Check which pods restarted
kubectl get pods -A --context <cluster> -o wide

# Check pod events
kubectl describe pod <pod-name> -n <namespace>

# Check if it was ArgoCD-related
kubectl logs <pod-name> -n <namespace> --previous
```

**Common causes**:

- Unrelated deployment during migration window
- Node issues or evictions
- OOMKilled or CrashLoopBackOff (pre-existing)

**Verify**: Check pod age - if older than migration, restart was unrelated.

### Source ArgoCD Still Shows Apps

**Symptom**: Source ArgoCD UI still shows App-of-Apps cards.

**Solution**:

```bash
# Hard refresh source
scripts/migration/refresh-source-apps.sh

# Or manually
argocd app delete <app-name> --cascade=false
```

**Note**: Cards may persist in UI even after deletion. This is cosmetic - verify in cluster:

```bash
kubectl get application -n argocd --context <source-cluster>
```

### Snapshots Show Differences

**Symptom**: `argocd_snapshot.py diff` shows unexpected changes.

**Investigation**:

```bash
# Review the diff output
python3 scripts/validation/argocd_snapshot.py diff \
    --before snapshots/pre \
    --after snapshots/post

# Common expected differences:
# - metadata.managedFields (ArgoCD internal)
# - metadata.resourceVersion (cluster-specific)
# - status.reconciledAt (timestamp)

# Unexpected differences to investigate:
# - spec changes (should be identical)
# - Different number of apps
# - Missing resources
```

## Rollback Issues

### Need to Rollback After Commit A

**Solution**:

```bash
# Revert the Git commit
git revert <commit-a-sha>
git push

# Hard refresh both control planes
argocd app get root-app-of-apps --hard-refresh --server <source-url>
argocd app get root-app-of-apps --hard-refresh --server <target-url>
```

### Need to Rollback After Pass 1 Disarm

**Solution**:

```bash
# Re-enable auto-sync on source
scripts/migration/toggle-autosync.sh --mode enable \
    --app-of-app app-of-apps/clusters/<source>/apps.yaml

# Commit and push
git add app-of-apps/clusters/<source>/apps.yaml
git commit -m "Rollback: Re-enable auto-sync"
git push
```

### Need to Rollback After Pass 2 Cleanup

**Solution**: This is harder - source resources are deleted. Options:

**Option 1: Restore from backups**

```bash
# If you captured backups before cleanup
kubectl apply -f backups/<app-name>.yaml --context <source-cluster>
```

**Option 2: Revert both commits**

```bash
git revert <commit-b-sha>
git revert <commit-a-sha>
git push

# Manually recreate source Applications
# (They were deleted, so Git won't restore them)
```

**Prevention**: Always capture backups before cleanup:

```bash
scripts/migration/export-argo-apps.sh > backups/source-apps.yaml
```

## Performance Issues

### Scripts Running Slowly

**Symptom**: Disarm or cleanup taking 20+ minutes.

**Possible causes**:

1. Large number of applications (100+)
2. Slow API responses from ArgoCD or Kubernetes
3. Network latency

**Solutions**:

```bash
# Check number of apps
kubectl get applications -n argocd | wc -l

# Check API response time
time kubectl get applications -n argocd

# If slow, consider:
# - Running from closer network location
# - Increasing kubectl timeout
# - Running during off-peak hours
```

### Dry-Run Taking Too Long

**Solution**: Dry-run mode fetches all data but doesn't make changes. For large clusters:

```bash
# Skip dry-run if you're confident
scripts/migration/disarm-source.sh --source ... --cluster ... --parent-app ...

# Or test on subset first
scripts/migration/disarm-source.sh --dry-run --parent-app <single-app>
```

## Validation Issues

### Kyverno Policy Blocking Operations

**Symptom**: ArgoCD operations fail with admission webhook denied.

**Solution**: This is expected if Kyverno policy is active:

```bash
# Check policy status
kubectl get clusterpolicy argocd-migration-safeguard

# If migration is complete, remove it
kubectl delete clusterpolicy argocd-migration-safeguard

# If migration ongoing, this is working as intended
# The policy blocks ArgoCD deletions during migration window
```

### Health Check Failures

**Symptom**: `cleanup-source.sh` fails health check for target.

**Investigation**:

```bash
# Check target app status
argocd app get <app-name> --server <target-url>

# Common issues:
# - App still syncing (wait for sync to complete)
# - App degraded (check app events)
# - Network issues (check connectivity)

# Force proceed (not recommended)
# Edit cleanup-source.sh and comment out health check
# Or fix the underlying issue
```

## Getting Help

If you encounter issues not covered here:

1. **Check logs**: Review script output carefully
2. **Dry-run mode**: Always test with `--dry-run` first
3. **Verify state**: Use `kubectl` and `argocd` CLI to inspect actual state
4. **Snapshots**: Compare before/after snapshots to identify changes
5. **Open an issue**: [GitHub Issues](https://github.com/seansilvestri/argocd-migration-toolkit/issues)

## Debug Mode

Enable verbose output for troubleshooting:

```bash
# Bash scripts
bash -x scripts/migration/disarm-source.sh ...

# Python scripts
python3 -v scripts/validation/argocd_validate.py ...

# ArgoCD CLI
argocd app get <app-name> --loglevel debug
```

## Common Mistakes

1. ❌ **Running cleanup before target sync** → Always sync target first
2. ❌ **Not waiting for Commit A to sync** → Hard refresh both control planes
3. ❌ **Wrong kubectl context** → Use environment profiles to auto-switch
4. ❌ **Skipping dry-run** → Always preview changes first
5. ❌ **No backups** → Capture snapshots and exports before migration
6. ❌ **Ignoring health checks** → Don't force proceed if target unhealthy
