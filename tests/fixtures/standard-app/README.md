# Standard App Fixture

This fixture represents a standard App-of-Apps migration scenario with:
- **Cluster-prefix naming**: `workload-cluster.apps`
- **Parent app**: App-of-Apps pattern
- **Auto-sync enabled**: Tests disabling auto-sync during migration
- **Finalizers**: Tests removing finalizers for zero-downtime

## Structure

```
standard-app/
├── app-of-apps/
│   └── clusters/
│       ├── source-argocd/
│       │   ├── kustomization.yaml
│       │   └── apps-workload-cluster.yaml  # Parent app with cluster prefix
│       └── target-argocd/
│           └── kustomization.yaml
└── apps/
    └── guestbook/
        ├── kustomization.yaml
        ├── deployment.yaml
        └── service.yaml
```

## Usage

This fixture is used by the standard migration test (`run-migration-test.sh`) to test:
1. Parent-based discovery (using `--parent-app workload-cluster.apps`)
2. Cluster-prefix naming convention
3. Auto-sync disabling
4. Finalizer removal
5. Zero-downtime migration

## Differences from simple-app

- **Naming**: Uses `workload-cluster.apps` (cluster-prefix) vs `my-app` (no prefix)
- **Discovery**: Uses parent-based discovery vs path-based discovery
- **App**: Uses guestbook vs busybox

## Git Server

Like `simple-app`, this fixture is pushed to the in-cluster Gitea server during test execution.
