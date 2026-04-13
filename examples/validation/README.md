# Validation Examples

Examples for validating new ArgoCD instances before migration.

## Pre-Migration Validation

Before migrating to a new ArgoCD control plane, validate that it's working correctly using smoke tests.

### Quick Start

```bash
# 1. Create smoke test definition
cp examples/validation/example-smoke-tests.yaml my-smoke-tests.yaml
vi my-smoke-tests.yaml  # Edit with your cluster details

# 2. Run validation
python3 scripts/validation/argocd_validate.py \
    --tests-file my-smoke-tests.yaml \
    --argo-instance my-new-control-plane \
    --active-only
```

## Smoke Test Structure

A smoke test file defines temporary Applications to create, sync, and verify:

```yaml
config:
  argoServer: argocd.new.example.com
  loginArgs: --sso
  repoURL: git@github.com:yourorg/k8s-deployments.git
  targetRevision: main
  project: default

tests:
  - name: busybox-smoke-test
    argoInstance: my-new-control-plane
    active: true
    destinationServer: https://kubernetes.default.svc
    destinationNamespace: default
    path: examples/busybox
```

## What Gets Validated

The validator:
1. ✅ Logs into the ArgoCD instance
2. ✅ Creates temporary Applications
3. ✅ Runs `argocd app sync --dry-run --prune`
4. ✅ Verifies connectivity and permissions
5. ✅ Cleans up temporary Applications
6. ✅ Reports success/failure

## Use Cases

### 1. New Control Plane Readiness

Validate a newly deployed ArgoCD instance before migrating production workloads:

```bash
python3 scripts/validation/argocd_validate.py \
    --tests-file validation/new-control-plane-tests.yaml \
    --argo-instance new-prod-argocd
```

### 2. Repository Access

Verify the control plane can access required Git repositories:

```bash
# Test with bootstrap repo config
python3 scripts/validation/argocd_validate.py \
    --tests-file validation/repo-access-tests.yaml \
    --argo-instance new-argocd \
    --bootstrap-repo-config '{
      "repoURL": "git@github.com:yourorg/k8s-deployments.git",
      "repoName": "k8s-deployments-smoke",
      "cleanup": true,
      "secret": {
        "namespace": "argocd",
        "name": "github-repo-secret",
        "kubeContext": "existing-cluster"
      }
    }'
```

### 3. Multi-Cluster Validation

Test that the control plane can deploy to multiple target clusters:

```yaml
tests:
  - name: cluster-1-test
    destinationServer: https://cluster-1.example.com
    # ...
  - name: cluster-2-test
    destinationServer: https://cluster-2.example.com
    # ...
```

## Configuration Options

### Global Config Block

```yaml
config:
  argoServer: argocd.example.com          # ArgoCD server URL
  loginArgs: --sso                        # Login arguments
  repoURL: git@github.com:org/repo.git   # Default repo URL
  targetRevision: main                    # Default branch/tag
  project: default                        # Default project
  destinationNamespace: default           # Default namespace
  
  # Optional: Pre-commands to run before validation
  preCommands:
    - echo "Starting validation"
  
  # Optional: Bootstrap repos that don't exist yet
  bootstrapRepos:
    - repoURL: git@github.com:org/private-repo.git
      repoName: private-repo-smoke
      cleanup: true
      secret:
        namespace: argocd
        name: github-ssh-key
        kubeContext: source-cluster
```

### Per-Test Config

```yaml
tests:
  - name: my-test
    argoInstance: control-plane-name      # Filter by instance
    active: true                          # Only run if true
    destinationServer: https://k8s.svc    # Target cluster
    destinationNamespace: my-namespace    # Target namespace
    path: path/to/manifests               # Manifest path in repo
    
    # Override global settings
    repoURL: git@github.com:other/repo.git
    targetRevision: v1.0.0
    project: my-project
```

## Filtering Tests

### By Instance

```bash
# Only run tests for specific ArgoCD instance
python3 scripts/validation/argocd_validate.py \
    --tests-file tests.yaml \
    --argo-instance prod-argocd
```

### By Active Flag

```bash
# Only run tests marked active: true
python3 scripts/validation/argocd_validate.py \
    --tests-file tests.yaml \
    --active-only
```

## Bootstrap Support

If the new ArgoCD instance doesn't have access to your Git repos yet, use bootstrap:

```bash
python3 scripts/validation/argocd_validate.py \
    --tests-file tests.yaml \
    --bootstrap-repo-config '{
      "repoURL": "git@github.com:yourorg/k8s-deployments.git",
      "repoName": "k8s-deployments-temp",
      "cleanup": true,
      "secret": {
        "namespace": "argocd",
        "name": "github-ssh-key",
        "kubeContext": "working-cluster"
      }
    }'
```

This:
1. Fetches SSH key from existing cluster
2. Registers repo in new ArgoCD instance
3. Runs smoke tests
4. Removes temporary repo registration

## Best Practices

1. **Test early**: Validate new control planes before migration day
2. **Keep tests simple**: Use lightweight apps (busybox, nginx)
3. **Test multiple clusters**: Verify connectivity to all target clusters
4. **Clean up**: Use `--keep-apps` flag only for debugging
5. **Document results**: Save validation output for audit trail

## Troubleshooting

### "Repository not found"

Add repository to ArgoCD or use `--bootstrap-repo-config`:
```bash
argocd repo add git@github.com:yourorg/repo.git --ssh-private-key-path ~/.ssh/id_rsa
```

### "Cluster not found"

Add cluster to ArgoCD:
```bash
argocd cluster add my-cluster-context
```

### "Permission denied"

Verify ArgoCD has RBAC permissions:
```bash
kubectl get clusterrole argocd-manager -o yaml
```

## Example Output

```
✅ Logged into ArgoCD: argocd.new.example.com
✅ Created Application: busybox-smoke-test
✅ Dry-run sync successful: busybox-smoke-test
✅ Deleted Application: busybox-smoke-test

Summary:
  Total tests: 3
  Passed: 3
  Failed: 0
  
✅ All smoke tests passed!
```

## Integration with Migration

Use validation as part of your migration workflow:

```bash
# 1. Validate new control plane
python3 scripts/validation/argocd_validate.py \
    --tests-file validation/pre-migration-tests.yaml \
    --argo-instance new-argocd

# 2. If validation passes, proceed with migration
scripts/migration/generate-runbook.sh my-migration

# 3. Follow generated runbook
```
