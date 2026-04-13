# Kyverno Admission Policy

Optional safety layer for ArgoCD migrations using Kyverno admission control.

## Overview

The `kyverno-safeguard.yaml` ClusterPolicy provides defense-in-depth by blocking ArgoCD service accounts from deleting workload resources during the migration window.

**Note**: This is an **optional** safety layer. The migration scripts already handle finalizer removal correctly. Use this policy for extra insurance on high-stakes production migrations.

## When to Use

✅ **Use when**:
- Migrating critical production workloads
- Regulatory compliance requires extra safeguards
- Team wants additional peace of mind
- Kyverno is already deployed in your cluster

❌ **Skip when**:
- Non-production environments
- Kyverno not available
- Confident in finalizer management
- Want to minimize dependencies

## How It Works

The policy blocks ArgoCD service accounts from:
1. Deleting any workload resources (Deployments, StatefulSets, etc.)
2. Deleting critical cluster resources (Namespaces, CRDs)

**Blocked service accounts**:
- `argocd-manager` (namespace: `argocd`)
- `argocd-manager-kcp` (namespace: `argocd`)
- `argocd-manager` (namespace: `kube-system`)

## Deployment

### Prerequisites

- Kyverno installed in the cluster
- Cluster-admin permissions
- kubectl access to workload cluster

### Apply Policy

```bash
# Deploy to WORKLOAD cluster (not control plane)
kubectl apply -f policies/kyverno-safeguard.yaml --context <workload-cluster>

# Verify policy is active
kubectl get clusterpolicy argocd-migration-safeguard
```

### Timing

**Deploy**: Before Pass 2 Cleanup (after Target Sync completes)

**Remove**: After migration verification completes

```bash
# Remove policy after migration
kubectl delete clusterpolicy argocd-migration-safeguard --context <workload-cluster>
```

## Policy Details

### Rule 1: Block Workload Deletion

Prevents ArgoCD from deleting resources in application namespaces:

```yaml
- name: block-argocd-workload-deletion
  match:
    resources:
      kinds: ['*']
      operations: [DELETE]
    subjects:
      - kind: ServiceAccount
        name: argocd-manager
  validate:
    deny: {}
```

**Excluded namespaces**:
- `kube-system`
- `kube-public`
- `kube-node-lease`

### Rule 2: Block Critical Resource Deletion

Prevents ArgoCD from deleting cluster-critical resources:

```yaml
- name: block-argocd-crd-namespace-deletion
  match:
    resources:
      kinds: [Namespace, CustomResourceDefinition]
      operations: [DELETE]
    subjects:
      - kind: ServiceAccount
        name: argocd-manager
  validate:
    deny: {}
```

## Impact

### During Migration

- ✅ Normal Kubernetes operations continue
- ✅ Manual deletions still work
- ✅ Non-ArgoCD controllers unaffected
- ⚠️ ArgoCD pruning/cleanup delayed until policy removed

### After Migration

Remove the policy to restore normal ArgoCD operations:
- Pruning resumes
- Cleanup operations work
- Auto-sync deletions proceed

**Recommendation**: Remove policy within 30 minutes of migration completion.

## Troubleshooting

### Policy Not Blocking Deletions

Check policy status:
```bash
kubectl get clusterpolicy argocd-migration-safeguard -o yaml
```

Verify Kyverno is running:
```bash
kubectl get pods -n kyverno
```

### ArgoCD Shows Errors

Expected during migration window. ArgoCD will show:
```
Error: admission webhook "validate.kyverno.svc" denied the request
```

This is **normal and desired** - the policy is working.

### Need to Allow Specific Deletion

Temporarily remove policy:
```bash
kubectl delete clusterpolicy argocd-migration-safeguard
# Perform deletion
# Reapply policy
kubectl apply -f policies/kyverno-safeguard.yaml
```

## Customization

### Add Service Accounts

Edit the policy to include additional ArgoCD service accounts:

```yaml
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: argocd
  - kind: ServiceAccount
    name: your-custom-sa
    namespace: your-namespace
```

### Exclude Specific Namespaces

Add to the namespace exclusion list:

```yaml
namespaces:
  - '!kube-system'
  - '!kube-public'
  - '!your-excluded-namespace'
  - '*'
```

### Change Validation Action

Switch from `Enforce` to `Audit` for testing:

```yaml
spec:
  validationFailureAction: Audit  # Logs violations without blocking
```

## Best Practices

1. **Test first**: Deploy in non-prod to verify behavior
2. **Time-bound**: Remove policy promptly after migration
3. **Monitor**: Watch Kyverno logs during migration
4. **Document**: Note policy deployment in migration runbook
5. **Communicate**: Inform team policy is active

## References

- [Kyverno Documentation](https://kyverno.io/docs/)
- [Kyverno Policy Samples](https://kyverno.io/policies/)
- [ArgoCD Security](https://argo-cd.readthedocs.io/en/stable/operator-manual/security/)
