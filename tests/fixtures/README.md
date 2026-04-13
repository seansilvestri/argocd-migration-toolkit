# Test Fixtures

This directory contains test fixtures for the ArgoCD Migration Toolkit automated tests.

## Overview

Test fixtures are complete, self-contained ArgoCD application structures that mirror real-world deployments. They are used to test migration scenarios without requiring external dependencies.

## How It Works

### In-Cluster Git Server

Tests use an in-cluster Gitea server to provide a realistic Git-based workflow:

1. **Setup** (`make test-setup`): Deploys Gitea in the source-argocd cluster
2. **Initialization** (`init-git-repo.sh`): Pushes fixtures to Gitea as Git repositories
3. **ArgoCD Sync**: Applications sync from `http://git-server.default.svc.cluster.local:3000/gitea/<repo>.git`
4. **Migration**: Scripts scan local fixture directories for path-based discovery

### Benefits

- ✅ **No external dependencies**: Everything runs locally in Kind
- ✅ **Realistic**: Mirrors production Git-based workflows
- ✅ **Repeatable**: Each test run gets a fresh Git server
- ✅ **Fast**: No network calls to external Git providers
- ✅ **Self-contained**: Fixtures include both App-of-Apps and application manifests

## Available Fixtures

### `simple-app/`

Tests path-based discovery with non-standard naming (no cluster prefix).

**Structure:**

```
simple-app/
├── applications/clusters/source-argocd/
│   └── my-app.yaml              # Application named "my-app" (no cluster prefix)
└── manifests/my-app/
    ├── deployment.yaml           # Simple nginx deployment
    ├── service.yaml
    └── kustomization.yaml
```

**Tests:**

- Path-based discovery without cluster-prefix naming
- In-cluster Git server functionality
- Zero-downtime migration with local manifests

**Usage:**

```bash
make test-full-path-based
```

## Adding New Fixtures

1. Create a new directory under `tests/fixtures/`
2. Follow the structure:
   ```
   my-fixture/
   ├── app-of-apps/clusters/
   │   ├── source-argocd/
   │   │   └── *.yaml
   │   └── target-argocd/
   │       └── kustomization.yaml
   └── apps/
       └── my-app/
           └── *.yaml
   ```
3. Update Application manifests to use: `repoURL: http://git-server.default.svc.cluster.local:3000/gitea/<repo-name>.git`
4. Create a test script that calls `init-git-repo.sh` with your fixture
5. Add Makefile target

## Technical Details

### Git Server

- **Image**: `gitea/gitea:1.21-rootless`
- **Service**: `git-server.default.svc.cluster.local:3000`
- **Credentials**: `gitea / gitea123` (auto-created)
- **Storage**: 1Gi PVC in default namespace

### Initialization Script

`init-git-repo.sh` handles:

- Creating Gitea admin user
- Creating repository via API
- Initializing fixture as Git repo
- Pushing to Gitea

### ArgoCD Integration

Applications reference the in-cluster Git server:

```yaml
spec:
  source:
    repoURL: http://git-server.default.svc.cluster.local:3000/gitea/test-repo.git
    path: apps/my-app
```

ArgoCD can access the Git server because they're in the same cluster network.

## Troubleshooting

### Git server not ready

```bash
kubectl logs -n default deployment/git-server
kubectl get pods -n default
```

### Repository not found

```bash
# Check if repo was created
kubectl port-forward -n default svc/git-server 3000:3000
# Visit http://localhost:3000 (login: gitea/gitea123)
```

### ArgoCD can't sync

```bash
# Check ArgoCD repo-server logs
kubectl logs -n argocd deployment/argocd-repo-server
```
