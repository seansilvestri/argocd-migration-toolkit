# Migration Runbook: Example Migration

**Env Profile**: `example-migration`  
**Source Cluster**: `source-cluster` (Argo: `argocd.source.example.com`)  
**Target Cluster**: `target-cluster` (Argo: `argocd.target.example.com`)

> **Prep Once**
>
> ```bash
> source ./scripts/migration/migration-env.sh example-migration
> # MIG_* variables now populate all scripts; kubectl + argocd context auto-switch.
> ```

## App-of-Apps Pairing

- Source control plane specs:
  - `app-of-apps/clusters/source-cluster/apps-target-cluster.yaml`
  - `app-of-apps/clusters/source-cluster/infra-apps-target-cluster.yaml`
- Target control plane specs (prepared via Commit A):
  - `app-of-apps/clusters/target-cluster/apps-target-cluster.yaml`
  - `app-of-apps/clusters/target-cluster/infra-apps-target-cluster.yaml`

---

## 1. Commit A – Prep & Bootstrap

```bash
scripts/migration/prep-commit-a.sh \
    --cluster target-cluster \
    --source app-of-apps/clusters/source-cluster \
    --target app-of-apps/clusters/target-cluster \
    --app-file apps-target-cluster.yaml \
    --app-file infra-apps-target-cluster.yaml
```

_Action: Review diff, Commit, Push._

_After push: Hard refresh `root-app-of-apps` in **BOTH** source AND target ArgoCD UI to immediately pick up the disabled auto-sync (otherwise wait ~3min for auto-sync). This is critical - the source must have auto-sync disabled before Pass 1._

---

## 2. Disarm Source (Pass 1)

_CRITICAL: Ensure source ArgoCD has synced the Commit A changes (auto-sync disabled) before running this step. The script will disarm parent App-of-Apps, freeze ApplicationSets, and remove finalizers in the correct order._

```bash
# Preview
scripts/migration/disarm-source.sh \
    --dry-run \
    --source app-of-apps/clusters/source-cluster \
    --cluster target-cluster \
    --parent-app target-cluster.apps \
    --parent-app target-cluster.infra-apps

# Disarm Source (auto context switches to source)
scripts/migration/disarm-source.sh \
    --source app-of-apps/clusters/source-cluster \
    --cluster target-cluster \
    --parent-app target-cluster.apps \
    --parent-app target-cluster.infra-apps
```

---

## 3. Target Manual Sync

_Prereq: migration-env sourced (auto login/context) or manual `argocd login argocd.target.example.com --sso`._

```bash
scripts/migration/sync-target-apps.sh --dry-run   # optional preview
scripts/migration/sync-target-apps.sh             # uses MIG_TARGET_* defaults
```

---

## 3.5. Deploy Kyverno Policy (Optional - K8s Team Only)

_**OPTIONAL**: Deploy Kyverno admission policy to workload cluster right before cleanup to prevent accidental ArgoCD deletions. This is an additional safety layer that can only be applied by the Kubernetes team._

```bash
# K8s team only: Deploy cluster-scoped policy to workload cluster
kubectl apply -f policies/kyverno-safeguard.yaml --context target-cluster

# Verify policy is active
kubectl get clusterpolicy argocd-migration-safeguard --context target-cluster
```

_Note: This ClusterPolicy blocks ArgoCD from deleting resources in workload namespaces during cleanup. **Migration can proceed safely without this policy** - the migration scripts already handle finalizer removal correctly._

---

## 4. Cleanup Source (Pass 2)

```bash
# Preview
scripts/migration/cleanup-source.sh \
    --dry-run \
    --source app-of-apps/clusters/source-cluster \
    --cluster target-cluster \
    --parent-app target-cluster.apps \
    --parent-app target-cluster.infra-apps

# Cleanup Source (deletes disarmed resources)
scripts/migration/cleanup-source.sh \
    --source app-of-apps/clusters/source-cluster \
    --cluster target-cluster \
    --parent-app target-cluster.apps \
    --parent-app target-cluster.infra-apps
```

---

## 5. Commit B0 – Source Hard Refresh

_Force source ArgoCD to realize the Applications are gone._

```bash
scripts/migration/refresh-source-apps.sh --dry-run  # optional preview
scripts/migration/refresh-source-apps.sh            # uses MIG_SOURCE_* defaults
```

_Check source ArgoCD UI: the App-of-Apps cards should disappear or show "Not Found"._

---

## 6. Finish Commit B – Cleanup & Enable

```bash
scripts/migration/prep-commit-b-cleanup.sh \
    --app-file apps-target-cluster.yaml \
    --app-file infra-apps-target-cluster.yaml
```

_Action: Review diff, Commit, Push._

_After push: Hard refresh `root-app-of-apps` in target ArgoCD UI._

---

## 7. Final Cleanup

_If any lingering Application cards remain in source ArgoCD UI:_

```bash
# Switch to source context
mig_use_source_context
mig_login_source_argo

# Delete any remaining cards (they should have no finalizers)
argocd app delete target-cluster.apps --cascade=false
argocd app delete target-cluster.infra-apps --cascade=false
```

---

## 8. Remove Kyverno Policy (If Deployed)

```bash
kubectl delete clusterpolicy argocd-migration-safeguard --context target-cluster
```

---

## 9. Post-Migration Verification

### Capture Post-Migration State

```bash
# Login to target ArgoCD
mig_login_target_argo

# Capture target state
python3 scripts/validation/argocd_snapshot.py capture \
    --app-of-apps target-cluster.apps target-cluster.infra-apps \
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
    --kube-context target-cluster \
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
kubectl get pods -A --context target-cluster

# Verify ArgoCD shows all apps healthy
argocd app list
```

---

## ✅ Migration Complete

- [ ] Source control plane cleaned up
- [ ] Target control plane healthy and managing workloads
- [ ] Zero workload pod restarts verified
- [ ] Snapshots captured for audit trail
- [ ] Kyverno policy removed (if deployed)
- [ ] Change ticket updated with runbook and results

---

## 🔄 Rollback Procedures

### If Issues During Commit A

```bash
git revert <commit-a-sha>
git push
```

### If Issues During Pass 1 Disarm

```bash
# Re-enable auto-sync on source
scripts/migration/toggle-autosync.sh --mode enable \
    --app-of-app app-of-apps/clusters/source-cluster/apps-target-cluster.yaml \
    --app-of-app app-of-apps/clusters/source-cluster/infra-apps-target-cluster.yaml
```

### If Issues During Pass 2 Cleanup

```bash
# Restore from backups captured in pre-migration
kubectl apply -f backups/target-cluster.apps.yaml
kubectl apply -f backups/target-cluster.infra-apps.yaml
```

### Full Rollback

```bash
# Revert both commits
git revert <commit-b-sha>
git revert <commit-a-sha>
git push

# Re-sync source control plane
mig_login_source_argo
argocd app sync root-app-of-apps
```
