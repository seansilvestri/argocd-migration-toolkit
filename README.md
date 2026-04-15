# ArgoCD Migration Toolkit

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![ArgoCD](https://img.shields.io/badge/ArgoCD-Compatible-blue.svg)](https://argoproj.github.io/argo-cd/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.24+-326CE5.svg)](https://kubernetes.io/)

**Zero-downtime ArgoCD control plane migrations at scale.**

A comprehensive toolkit for migrating ArgoCD App-of-Apps between control planes without impacting workloads. Battle-tested across multiple production environments with hundreds of applications.

## 🎯 Features

- ✅ **Zero Downtime**: No workload pod restarts during migration
- ✅ **Production Ready**: Battle-tested across multiple environments with hundreds of applications
- ✅ **Complete Auditability**: Generated runbooks for compliance
- ✅ **Safety First**: Two-pass deletion, finalizer management, optional Kyverno policies
- ✅ **Automated Workflows**: 15+ scripts covering entire migration lifecycle
- ✅ **Validation Framework**: Pre/post migration snapshots and verification

## 🚀 Quick Start

### Test First (Recommended)

```bash
# Clone the repository
git clone https://github.com/seansilvestri/argocd-migration-toolkit.git
cd argocd-migration-toolkit

# Run automated tests (requires Docker)
make test-full

# Or step-by-step
make test-setup    # Create test environment
make test-cleanup  # Tear down
```

### Production Migration

```bash
# 1. Create environment profile
cp examples/env-profiles/example-migration.env envs/my-migration.env
# Edit with your source/target details

# 2. Source environment and generate runbook
source scripts/migration/migration-env.sh my-migration
scripts/migration/generate-runbook.sh my-migration

# 3. Follow the generated runbook
# See docs/quick-start.md for detailed walkthrough
```

## 📋 What Gets Migrated?

This toolkit migrates the **App-of-Apps control layer** - the ArgoCD Applications that manage other Applications. Individual workload manifests remain unchanged in Git.

```
App-of-Apps (e.g., cluster.apps)            ← We migrate THIS
  owns Workload Applications                ← These stay in place
    own Deployments/StatefulSets/etc.       ← These never know migration happened
```

## ⚙️ Prerequisites & Assumptions

### Repository Structure

- **Mono-repo required**: All ArgoCD Application manifests must be in a single Git repository
- Both source and target ArgoCD instances point to the **same Git repo**
- Migration works by modifying Application manifests in different directories (e.g., `app-of-apps/clusters/source/` → `app-of-apps/clusters/target/`)

### ArgoCD Setup

- Source and target ArgoCD instances must both have access to the workload cluster(s)
- Applications use GitOps (syncing from Git, not Helm repos or other sources)
- App-of-Apps pattern is in use (parent Applications managing child Applications)

### Access Requirements

- `kubectl` access to source, target, and workload clusters
- `argocd` CLI access to both ArgoCD instances
- Git repository write access for committing migration changes

**Note**: Multi-repo scenarios are not currently supported. If your Applications are spread across multiple Git repos, you'll need to migrate each repo's Applications separately.

## 🛠️ Toolkit Components

### Core Migration Scripts

| Script                | Purpose                                                                 |
| --------------------- | ----------------------------------------------------------------------- |
| `migration-env.sh`    | Environment profile management and context switching                    |
| `prep-commit-a.sh`    | Automates manifest preparation and retargeting                          |
| `disarm-source.sh`    | Pass 1: Disables auto-sync, freezes ApplicationSets, removes finalizers |
| `cleanup-source.sh`   | Pass 2: Safely deletes disarmed resources                               |
| `sync-target-apps.sh` | Hard refresh and sync target control plane                              |
| `toggle-autosync.sh`  | Manages auto-sync settings on App-of-Apps                               |
| `generate-runbook.sh` | Creates per-cluster migration runbooks                                  |
| `monitor-restarts.sh` | Tracks pod restarts during migration                                    |

### Validation & Analysis

| Script                               | Purpose                                                 |
| ------------------------------------ | ------------------------------------------------------- |
| `argocd_snapshot.py`                 | Captures and diffs App-of-Apps state pre/post migration |
| `argocd_validate.py`                 | Smoke tests new ArgoCD instances before migration       |
| `analyze-migration-compatibility.sh` | Pre-migration compatibility analysis                    |

### Operations Utilities

| Script                          | Purpose                                              |
| ------------------------------- | ---------------------------------------------------- |
| `bootstrap_repo_definitions.py` | Seeds new control planes with repository definitions |
| `hydrate_repo_credentials.py`   | Keeps Git/Helm credentials in sync                   |
| `fetch-argo-hook-logs.py`       | Troubleshoots sync issues via hook logs              |

## 📖 Documentation

- [Quick Start](docs/quick-start.md) - Get started in 5 minutes
- [Testing Guide](docs/testing-guide.md) - Test the toolkit safely before production
- [Test Quick Start](docs/test-quick-start.md) - Quick start guide for testing
- [Architecture](docs/architecture.md) - Design decisions and patterns
- [Troubleshooting](docs/troubleshooting.md) - Common issues and solutions
- [Contributing](CONTRIBUTING.md) - Contribution guidelines

## 🔑 Key Technical Insights

### The Finalizer Problem

ArgoCD adds `resources-finalizer.argocd.argoproj.io` to every Application. Removing an App-of-Apps manifest from Git without clearing finalizers causes cascade deletion of all child workloads.

**Solution**: Two-pass deletion strategy:

1. **Disarm**: Remove finalizers, freeze ApplicationSets
2. **Cleanup**: Delete disarmed resources with `--cascade=orphan`

### The `create-only` Trap

ApplicationSets with `applicationsSync: create-only` can still **recreate** deleted applications during cleanup.

**Solution**: Delete ApplicationSets FIRST, then orphaned children.

### Performance at Scale

Bulk fetching and Bash 4+ associative arrays reduce API calls from O(N) to O(1) for efficient processing at scale.

## 🔒 Safety Features

- **Two-pass deletion**: Prevents cascade deletions
- **Finalizer management**: Automated removal before deletion
- **Dry-run mode**: Preview all operations before execution
- **Health validation**: Verifies target before cleanup
- **Kyverno admission policy**: Optional additional safeguard
- **Automated rollback**: Procedures for quick recovery

## 📊 By the Numbers

- ✅ **0 production incidents** across all migrations
- ✅ **0 workload restarts** (verified via pod age monitoring)
- ✅ **Efficient at scale** with optimized bulk operations
- ✅ **100% auditability** with generated runbooks
- ✅ **15+ automation scripts** totaling 5,000+ lines of code

## 🎓 Use Cases

- Retiring end-of-life control plane infrastructure
- Moving between cloud providers or regions
- Adopting new deployment patterns or security models
- Consolidating control planes for better resource utilization

## 🔧 Requirements

- **ArgoCD CLI**: v3.2+ (for hard refresh support)
- **kubectl**: Configured for target clusters
- **yq**: v4+ (YAML processing)
- **jq**: For JSON parsing
- **Bash**: 4.0+ (for associative arrays)
- **Python**: 3.9+ (for validation scripts)

## 🤝 Contributing

Contributions welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

Built from real-world experience migrating hundreds of applications across multiple production environments. Special thanks to the ArgoCD community for building such a robust GitOps platform.

## 📧 Support

- **Issues**: [GitHub Issues](https://github.com/seansilvestri/argocd-migration-toolkit/issues)
- **Discussions**: [GitHub Discussions](https://github.com/seansilvestri/argocd-migration-toolkit/discussions)
- **LinkedIn**: [Your LinkedIn Profile](https://linkedin.com/in/seansilvestri)

---

**⭐ Star this repo** if you find it useful, and share your migration success stories!
