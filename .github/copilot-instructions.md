# ArgoCD Migration Toolkit - AI Assistant Instructions

## Project Overview
Zero-downtime ArgoCD control plane migration toolkit. Migrates App-of-Apps between ArgoCD instances without workload restarts.

## Key Constraints
- **Mono-repo only**: All Application manifests in single Git repo
- **GitOps workflow**: Changes via Git commits, not direct kubectl
- **Safety first**: Two-pass deletion, finalizer management, rollback points
- **Zero downtime**: No workload pod restarts during migration

## Architecture Decisions
- **Bash for orchestration**: kubectl, argocd CLI, file manipulation
- **Python for data processing**: Snapshots, API interactions, parallel ops
- **Path-based parameters**: Scripts use `--source <path>` and `--target <path>` for flexibility
- **No hardcoded structure**: Works with any repo layout (not just `app-of-apps/`)

## Code Style
- **Shell scripts**: Follow shellcheck, use `set -euo pipefail`, quote variables
- **No emojis in code**: Only in user-facing output
- **Comments explain "why"**: Not "what" the code does
- **Test coverage**: 80%+ for new features, zero pod restarts required

## Testing
- **3 test types**: Standard (app-of-apps), ApplicationSet, Path-based
- **Test environment**: 3 Kind clusters (source-argocd, target-argocd, workload-cluster)
- **In-cluster Git**: Gitea servers for realistic GitOps workflow
- **Working directories**: `test-results/standard/`, `test-results/appsets/`, `test-results/path-based/`

## Migration Scripts
1. **prep-commit-a.sh**: Creates target manifests, disables source auto-sync
2. **disarm-source.sh**: Removes finalizers, freezes ApplicationSets
3. **sync-target-apps.sh**: Syncs target control plane
4. **cleanup-source.sh**: Deletes disarmed source resources
5. **prep-commit-b-cleanup.sh**: Removes source manifests, enables target auto-sync

## Common Patterns
- Use `migration-env.sh` for environment management
- Always test with `make test-full` before production changes
- Scripts accept both CLI args and env vars (env vars as fallback)
- Path-based test uses `applications/` and `manifests/` directories (not `app-of-apps/` and `apps/`)

## Recent Changes
- Refactored `prep-commit-a.sh` and `prep-commit-b-cleanup.sh` to use `--source` and `--target` paths
- Renamed test working directories for clarity
- Updated path-based fixture to use `applications/` and `manifests/` directories
- All tests passing with zero pod restarts

## Documentation
- Main README: Overview, quick start, prerequisites
- `docs/quick-start.md`: Step-by-step migration guide
- `docs/architecture.md`: Design decisions, trade-offs
- `docs/testing-guide.md`: Test environment setup
- `examples/runbooks/`: Example migration runbooks
