# ApplicationSet App Fixture

This fixture represents an ApplicationSet migration scenario with:
- **ApplicationSet**: Generates multiple child applications (dev, prod)
- **Cluster-prefix naming**: `workload-cluster.guestbook-appset` and children
- **Parent app**: App-of-Apps pattern with ApplicationSet as child
- **Auto-sync enabled**: Tests disabling auto-sync during migration
- **Finalizers**: Tests removing finalizers for zero-downtime

## Structure

```
appset-app/
├── app-of-apps/
│   └── clusters/
│       ├── source-argocd/
│       │   ├── kustomization.yaml
│       │   └── apps-workload-cluster.yaml  # Parent app (placeholder)
│       └── target-argocd/
│           └── kustomization.yaml
├── appsets/
│   └── guestbook-appset.yaml  # ApplicationSet generating dev/prod apps
└── apps/
    └── guestbook/
        ├── kustomization.yaml
        ├── deployment.yaml
        └── service.yaml
```

## Usage

This fixture is used by the ApplicationSet migration test to test:
1. ApplicationSet discovery and migration
2. Child application handling
3. Owner reference management
4. Zero-downtime migration with multiple apps

## ApplicationSet Pattern

The ApplicationSet generates two child applications:
- `workload-cluster.guestbook-dev` → namespace `guestbook-dev`
- `workload-cluster.guestbook-prod` → namespace `guestbook-prod`

Both children use the same guestbook manifests but deploy to different namespaces.
