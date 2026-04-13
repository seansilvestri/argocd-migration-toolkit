# Test Configuration Files

This directory contains environment configuration files for different test scenarios.

## Available Configurations

### `standard.env`

**Standard parent-based discovery test**

Tests the typical migration scenario with:

- Cluster-prefix naming convention (`workload-cluster.apps`)
- Parent app-based discovery
- Uses `fixtures/standard-app/` fixture

**Usage:**

```bash
source tests/test-configs/standard.env
make test-run
```

### `appset.env`

**ApplicationSet migration test**

Tests migration of ApplicationSets and their generated children with:

- Parent app-based discovery
- `--include-untracked` flag for ApplicationSet children
- Cluster-prefix naming for ApplicationSet and children

**Usage:**

```bash
source tests/test-configs/appset.env
make test-run-appset
```

### `path-based.env`

**Path-based discovery test**

Tests migration without parent apps or naming conventions with:

- Path-based discovery (scans Git manifests directly)
- No parent app required
- Non-standard naming (e.g., `my-app` instead of `workload-cluster.my-app`)
- Uses committed fixture directory

**Usage:**

```bash
source tests/test-configs/path-based.env
make test-run-path-based
```

## Key Differences

| Feature           | Standard                      | ApplicationSet         | Path-Based             |
| ----------------- | ----------------------------- | ---------------------- | ---------------------- |
| Discovery Method  | Parent app                    | Parent app + untracked | Git manifest scan      |
| Naming Convention | Required (`<cluster>.<name>`) | Required               | Not required           |
| Parent App        | ✅ Required                   | ✅ Required            | ❌ Not used            |
| Fixture           | `fixtures/standard-app/`      | `fixtures/appset-app/` | `fixtures/simple-app/` |
| Use Case          | Standard apps                 | ApplicationSets        | Non-standard naming    |

## How Tests Use These

Each test script sources the appropriate env file:

```bash
# Standard test
source tests/test-configs/standard.env
./scripts/migration/disarm-source.sh --parent-app workload-cluster.apps ...

# ApplicationSet test
source tests/test-configs/appset.env
./scripts/migration/disarm-source.sh --parent-app workload-cluster.apps --include-untracked ...

# Path-based test
source tests/test-configs/path-based.env
./scripts/migration/disarm-source.sh --path-based-discovery --source $MIG_MANIFEST_ROOT ...
```

## Notes

- These files are **committed to Git** (whitelisted in `.gitignore`)
- They contain **test credentials only** (admin/admin for local Kind clusters)
- Real environment files go in `envs/` (gitignored)
