# ArgoCD Migration Toolkit - AI Assistant Instructions

## Project Overview
Zero-downtime ArgoCD control plane migration toolkit. Migrates App-of-Apps between ArgoCD instances without workload restarts.

**See [PRD.md](../PRD.md) for the full product vision, module breakdown, and roadmap.**

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

## Quality Standards

### Documentation
- **README.md**: Must follow open-source best practices:
  - Badges (ArgoCD compatibility, Kubernetes version, License, Tests)
  - Clear value proposition ("Zero-downtime ArgoCD control plane migrations")
  - Features table with ✅ icons
  - ASCII Architecture diagram
  - Quick Start (3 minutes max)
  - Detailed component guides
  - Environment variables table
  - Testing instructions with Makefile support
  - Project structure tree
  - Roadmap table
  - Contributing & License sections
- **Code Comments**: Every function/script must have comments explaining *what* it does and *why*.
- **Commit Messages**: Use conventional commits (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`).

### Code Quality
- **Bash Scripts**: Follow shellcheck standards, use `set -euo pipefail`, quote variables
- **Python Scripts**: Include type hints, proper error handling
- **Error Handling**: Graceful degradation when services are unavailable
- **Testing**: Every new feature must include tests. Aim for >80% coverage
- **Security**: Never commit secrets. Use `.env.example` for templates

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Scripting | Bash 4+, Python 3.9+ |
| Configuration | yq v4+, jq |
| Containerization | Docker, Docker Compose |
| Infrastructure | Kubernetes, ArgoCD |
| Testing | Kind clusters, Gitea servers |
| Dev Tools | VS Code, GitHub Copilot, Make

## Project Structure

```
argocd-migration-toolkit/
├── scripts/                    # Core migration scripts
│   ├── migration/              # Migration lifecycle scripts
│   │   ├── prep-commit-a.sh      # Manifest preparation
│   │   ├── disarm-source.sh     # Pass 1: Disarm resources
│   │   ├── cleanup-source.sh    # Pass 2: Cleanup
│   │   ├── sync-target-apps.sh  # Sync target control plane
│   │   └── migration-env.sh     # Environment management
│   ├── operations/             # Operations utilities
│   │   ├── bootstrap_repo_definitions.py  # Repository setup
│   │   └── hydrate_repo_credentials.py     # Credential management
│   └── validation/             # Validation scripts
│       ├── argocd_validate.py  # Smoke tests
│       └── validate_runbooks.py # Runbook validation
├── tests/                      # Test infrastructure
│   ├── fixtures/                # Test fixtures (standard, appset, path-based)
│   ├── run-migration-test.sh    # Main test runner
│   └── setup-test-env.sh       # Test environment setup
├── docs/                       # Documentation
│   ├── architecture.md          # Design decisions
│   ├── quick-start.md          # Quick start guide
│   ├── testing-guide.md         # Testing documentation
│   └── troubleshooting.md       # Common issues
├── examples/                   # Example configurations
│   ├── env-profiles/            # Environment profile templates
│   ├── runbooks/                # Example runbooks
│   └── validation/              # Example test configurations
├── policies/                   # Safety policies
│   └── kyverno-safeguard.yaml  # Optional admission control
├── Makefile                    # Test automation
├── README.md                   # Main documentation
└── .github/                    # GitHub workflows
    └── copilot-instructions.md # This file
```

## General Development Guidelines

When working on the ArgoCD Migration Toolkit:

- **Focus Areas**: Bash scripting best practices, Kubernetes resource management, ArgoCD API interactions, GitOps workflows
- **Code Writing**: Use declarative configurations, include comments explaining complex operations, suggest safety best practices, optimize for reliability
- **Question Handling**: Provide production-ready solutions, explain trade-offs between options, reference official documentation when relevant

## Migration Script Patterns

### Core Migration Workflow

The migration follows a strict safety-first approach:

1. **Preparation**: Create target manifests, disable source auto-sync
2. **Disarm**: Remove finalizers, freeze ApplicationSets
3. **Sync**: Hard refresh target control plane
4. **Cleanup**: Delete disarmed source resources
5. **Finalization**: Remove source manifests, enable target auto-sync

### Key Concepts

#### The Finalizer Problem

ArgoCD adds `resources-finalizer.argocd.argoproj.io` to every Application. Removing an App-of-Apps manifest without clearing finalizers causes cascade deletion.

**Solution**: Two-pass deletion strategy:
1. **Disarm**: Remove finalizers, freeze ApplicationSets
2. **Cleanup**: Delete disarmed resources with `--cascade=orphan`

#### The `create-only` Trap

ApplicationSets with `applicationsSync: create-only` can recreate deleted applications during cleanup.

**Solution**: Delete ApplicationSets FIRST, then orphaned children.

#### Performance at Scale

Bulk fetching and Bash associative arrays reduce API calls from O(N) to O(1) for efficient processing.

## Script Organization

### Migration Scripts

| Script | Purpose |
|--------|---------|
| `prep-commit-a.sh` | Creates target manifests, disables source auto-sync |
| `disarm-source.sh` | Pass 1: Disables auto-sync, freezes ApplicationSets, removes finalizers |
| `cleanup-source.sh` | Pass 2: Safely deletes disarmed resources |
| `sync-target-apps.sh` | Hard refresh and sync target control plane |
| `toggle-autosync.sh` | Manages auto-sync settings |
| `generate-runbook.sh` | Creates per-cluster migration runbooks |
| `monitor-restarts.sh` | Tracks pod restarts during migration |

### Validation Scripts

| Script | Purpose |
|--------|---------|
| `argocd_snapshot.py` | Captures and diffs App-of-Apps state pre/post migration |
| `argocd_validate.py` | Smoke tests new ArgoCD instances before migration |
| `analyze-migration-compatibility.sh` | Pre-migration compatibility analysis |

### Operations Utilities

| Script | Purpose |
|--------|---------|
| `bootstrap_repo_definitions.py` | Seeds new control planes with repository definitions |
| `hydrate_repo_credentials.py` | Keeps Git/Helm credentials in sync |
| `fetch-argo-hook-logs.py` | Troubleshoots sync issues via hook logs |

## Testing Strategy

For each migration scenario, include:

```bash
# tests/test_standard_migration.sh
function test_standard_migration() {
    """Test standard app-of-apps migration"""
    # Setup
    # Execute migration
    # Verify no pod restarts
    # Validate target state
}

# tests/test_appset_migration.sh
function test_appset_migration() {
    """Test ApplicationSet migration"""
    # Setup
    # Execute migration
    # Verify ApplicationSet transformation
    # Validate target state
}
```

## Best Practices

- **Commit early and often** — especially after each script milestone
- **Use git commit messages** that reference the migration stage: `feat: prep-commit-a - add dry-run support`
- **Tag with migration concepts** when committing: `feat(migration): improve finalizer removal`
- **Document script evolution** in commit messages: `refactor: optimize bulk fetching in disarm-source.sh`
- **Keep scripts focused** — they should do one thing well
- **Test thoroughly** — use the test environment with Kind clusters

## Safety Features

- **Two-pass deletion**: Prevents cascade deletions
- **Finalizer management**: Automated removal before deletion
- **Dry-run mode**: Preview all operations before execution
- **Health validation**: Verifies target before cleanup
- **Kyverno admission policy**: Optional additional safeguard
- **Automated rollback**: Procedures for quick recovery

## Requirements

- **ArgoCD CLI**: v3.2+ (for hard refresh support)
- **kubectl**: Configured for target clusters
- **yq**: v4+ (YAML processing)
- **jq**: For JSON parsing
- **Bash**: 4.0+ (for associative arrays)
- **Python**: 3.9+ (for validation scripts)

## When Working on Specific Scripts

### prep-commit-a.sh
- Task: Prepare target manifests and disable source auto-sync
- Key: Path-based parameter handling (`--source` and `--target`)
- Files: `scripts/migration/prep-commit-a.sh`, `scripts/migration/migration-lib.sh`

### disarm-source.sh
- Task: Remove finalizers and freeze ApplicationSets
- Key: Bulk operations, safety checks
- Files: `scripts/migration/disarm-source.sh`, `scripts/migration/migration-lib.sh`

### cleanup-source.sh
- Task: Safely delete disarmed resources
- Key: Two-pass deletion, cascade management
- Files: `scripts/migration/cleanup-source.sh`, `scripts/migration/migration-lib.sh`

## Example Script Structure

```bash
#!/bin/bash
# scripts/migration/prep-commit-a.sh

set -euo pipefail

# Load common functions and validation
source "$(dirname "${BASH_SOURCE[0]}")/migration-lib.sh"

# Main function
main() {
    parse_args "$@"
    validate_environment
    create_target_manifests
    disable_source_autosync
    echo "Migration preparation complete. Ready for disarm phase."
}

# Argument parsing
parse_args() {
    # Handle --source, --target, --dry-run flags
}

# Environment validation
validate_environment() {
    # Check required tools, clusters, git repo
}

# Target manifest creation
create_target_manifests() {
    # Copy and transform source manifests for target
}

# Source autosync management
disable_source_autosync() {
    # Use ArgoCD API to disable autosync
}

# Execute main function
main "$@"
```

This enhanced copilot-instructions file provides comprehensive guidance for working on the ArgoCD Migration Toolkit, including project-specific patterns, testing strategies, and development best practices.