# Environment Profiles

Environment profiles centralize all configuration for a migration, eliminating manual context switching and reducing operator errors.

## Quick Start

```bash
# 1. Copy example profile
cp examples/env-profiles/example-migration.env envs/my-migration.env

# 2. Edit with your details
vi envs/my-migration.env

# 3. Source the profile
source scripts/migration/migration-env.sh my-migration

# 4. Verify it loaded
mig_env_info
```

## Profile Structure

### Required Fields

| Field | Description | Example |
|-------|-------------|---------|
| `SOURCE_CLUSTER` | Source cluster name | `legacy-gke-cluster` |
| `SOURCE_KUBECONTEXT` | kubectl context for source | `gke_project_us-central1_legacy` |
| `SOURCE_ARGO_URL` | Source ArgoCD URL | `argocd.legacy.example.com` |
| `SOURCE_ARGO_LOGIN_ARGS` | ArgoCD login arguments | `--sso` or `--username admin --password xyz` |
| `TARGET_CLUSTER` | Target cluster name | `new-aws-cluster` |
| `TARGET_KUBECONTEXT` | kubectl context for target | `arn:aws:eks:us-east-1:123:cluster/new` |
| `TARGET_ARGO_URL` | Target ArgoCD URL | `argocd.new.example.com` |
| `TARGET_ARGO_LOGIN_ARGS` | ArgoCD login arguments | `--sso` |
| `SAFE_DELETE_PARENT_APPS` | App-of-Apps to migrate | `new-aws-cluster.apps new-aws-cluster.infra-apps` |

### Optional Fields

| Field | Description | Default |
|-------|-------------|---------|
| `TARGET_ARGO_SYNC_APPS` | Apps to sync on target | Same as `SAFE_DELETE_PARENT_APPS` |
| `SAFE_DELETE_INCLUDE_UNTRACKED` | Include apps without tracking IDs | `false` |
| `MIG_MANIFEST_ROOT` | Custom manifest directory | Current repo root |
| `RUNBOOK_APP_FILES` | Custom app file names | `apps-<cluster>.yaml infra-apps-<cluster>.yaml` |
| `MIG_DISABLE_AUTO_CONTEXT` | Disable auto kubectl context switch | `false` |
| `MIG_DISABLE_AUTO_ARGO_LOGIN` | Disable auto ArgoCD login | `false` |

## Helper Functions

After sourcing a profile, these functions are available:

```bash
# Display current environment
mig_env_info

# Switch to source context and login
mig_use_source_context
mig_login_source_argo

# Switch to target context and login
mig_use_target_context
mig_login_target_argo
```

## Environment Variables

The profile exports these variables for scripts:

```bash
MIG_SOURCE_CLUSTER
MIG_SOURCE_KUBECONTEXT
MIG_SOURCE_ARGO_URL
MIG_SOURCE_ARGO_LOGIN_ARGS

MIG_TARGET_CLUSTER
MIG_TARGET_KUBECONTEXT
MIG_TARGET_ARGO_URL
MIG_TARGET_ARGO_LOGIN_ARGS

MIG_SAFE_DELETE_PARENT_APPS
MIG_TARGET_ARGO_SYNC_APPS
MIG_SAFE_DELETE_INCLUDE_UNTRACKED
MIG_MANIFEST_ROOT
```

All migration scripts automatically use these variables.

## Examples

### Basic Migration

```bash
SOURCE_CLUSTER=old-cluster
SOURCE_KUBECONTEXT=old-cluster-context
SOURCE_ARGO_URL=argocd.old.example.com
SOURCE_ARGO_LOGIN_ARGS="--sso"

TARGET_CLUSTER=new-cluster
TARGET_KUBECONTEXT=new-cluster-context
TARGET_ARGO_URL=argocd.new.example.com
TARGET_ARGO_LOGIN_ARGS="--sso"

SAFE_DELETE_PARENT_APPS="new-cluster.apps new-cluster.infra-apps"
```

### Multi-Parent Migration

```bash
# Multiple App-of-Apps in same migration
SAFE_DELETE_PARENT_APPS="cluster.apps cluster.infra-apps cluster.platform-apps"
TARGET_ARGO_SYNC_APPS="cluster.apps cluster.infra-apps cluster.platform-apps"
```

### Cross-Repo Migration

```bash
# Working from dev repo but editing prod manifests
MIG_MANIFEST_ROOT=/path/to/k8s-deployments-prod
```

### Include Untracked Apps

```bash
# Clean up Applications without tracking IDs
SAFE_DELETE_INCLUDE_UNTRACKED=true
```

## Best Practices

1. **One profile per migration**: Create separate profiles for each cluster pair
2. **Descriptive names**: Use `<source>-to-<target>.env` naming
3. **Version control**: Store profiles in `envs/` (gitignored by default)
4. **Test first**: Validate profile with `mig_env_info` before migration
5. **Document**: Add comments explaining non-obvious settings

## Troubleshooting

### "Profile not found"

```bash
# Use relative path from envs/ directory
source scripts/migration/migration-env.sh prod/us/my-cluster

# Or use full filename if in envs/ root
source scripts/migration/migration-env.sh my-cluster.env
```

### "Context switch failed"

Ensure kubectl contexts exist:
```bash
kubectl config get-contexts
```

### "ArgoCD login failed"

Verify URL and credentials:
```bash
argocd login $SOURCE_ARGO_URL $SOURCE_ARGO_LOGIN_ARGS
```

## Security Notes

- **Never commit profiles with real credentials** to version control
- Profiles are gitignored by default
- Use SSO (`--sso`) instead of passwords when possible
- Rotate credentials after migration completes
