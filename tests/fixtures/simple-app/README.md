# Simple App Test Fixture

This fixture contains a **fully self-contained** test application with non-standard naming (no cluster prefix) to test path-based discovery.

## Structure

```
simple-app/
├── applications/
│   └── clusters/
│       ├── source-argocd/
│       │   ├── my-app.yaml          # Application named "my-app" (no cluster prefix)
│       │   └── kustomization.yaml   # Points to local mounted path
│       └── target-argocd/
│           └── kustomization.yaml
└── manifests/
    └── my-app/                       # Actual Kubernetes manifests (local)
        ├── deployment.yaml           # Simple nginx deployment
        ├── service.yaml              # Service for the deployment
        └── kustomization.yaml
```

## Key Features

- **No external dependencies**: All manifests are local, no GitHub repos needed
- **Non-standard naming**: Application is named `my-app` (not `<cluster>.my-app`)
- **Mounted in Kind**: Entire fixture is mounted at `/mnt/test-fixtures/simple-app/`
- **File-based source**: Application uses `file:///mnt/test-fixtures/simple-app` as repoURL

## Purpose

Tests that:

1. Kind clusters can mount and access local fixtures
2. ArgoCD can sync from `file://` URLs (mounted paths)
3. `--path-based-discovery` discovers apps without cluster-prefix naming
4. Migration works end-to-end with fully local manifests

## Usage

This fixture is used by `make test-full-path-based` to validate path-based discovery functionality.
