# Test Quick Start Guide

Get started with testing the ArgoCD Migration Toolkit in minutes.

## 🚀 Why Test?

Before using the toolkit in production, testing ensures:
- ✅ Migration scripts work as expected
- ✅ Zero-downtime guarantee holds true
- ✅ Your specific environment is compatible
- ✅ You understand the migration workflow

## 🛠️ Prerequisites

Install required tools:

```bash
# macOS
brew install kind kubectl argocd python3

# Linux
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
```

For detailed prerequisites and setup instructions, see the [Testing Guide](testing-guide.md).

## 🎯 Test Options

### Option 1: Fast Automated Test (Recommended)

```bash
# Run complete test (setup → migrate → verify → cleanup)
git clone https://github.com/seansilvestri/argocd-migration-toolkit.git
cd argocd-migration-toolkit
make test-full
```

**What this does:**
- Creates test environment with Kind clusters
- Runs standard App-of-Apps migration
- Verifies zero-downtime
- Cleans up when done

### Option 2: Iterative Testing

For faster iteration after initial setup:

```bash
# Setup once (takes ~5-10 minutes)
make test-setup

# Then run tests repeatedly (fast)
make test-run                # Standard migration
make test-run-appset         # ApplicationSet migration
make test-run-path-based     # Path-based discovery
make test-argocd-validate    # Run ArgoCD validation test (new)

# Verify results
make test-verify

# Cleanup when done
make test-cleanup
```

### Option 3: Manual Testing

For maximum control:

```bash
# Setup environment manually
./tests/setup-test-env.sh

# Run specific test scenarios
./tests/run-migration-test.sh
./tests/run-migration-test-appset.sh
./tests/run-migration-test-path-based.sh

# Verify and cleanup
./tests/verify-migration.sh
./tests/cleanup-test-env.sh
```

## 📊 What Gets Created

The test environment includes:

- **3 Kind clusters**: `kind-source-argocd`, `kind-target-argocd`, `kind-workload-cluster`
- **2 ArgoCD instances**: Source and target control planes
- **In-cluster Git servers**: Gitea for realistic GitOps workflow
- **Test workloads**: Guestbook applications
- **Environment profile**: Pre-configured test settings

For a detailed breakdown of what gets created, see the [Testing Guide](testing-guide.md).

## 🎯 Test Scenarios

The toolkit supports 3 test scenarios:

1. **Standard**: App-of-Apps with child Applications
2. **ApplicationSet**: App-of-Apps with ApplicationSets
3. **Path-based**: Path discovery without App-of-Apps

## 📝 Test Results

After running tests, you'll find results in:
- `test-results/` directory
- Kind clusters (accessible via `kubectl`)
- ArgoCD UIs (accessible via `argocd login`)

For detailed information on interpreting test results, see the [Testing Guide](testing-guide.md).

## 💡 Tips for Success

1. **Start with automated tests** - They're the fastest way to verify functionality
2. **Keep clusters running** - Between test iterations for faster testing
3. **Check logs** - If tests fail, review logs in `test-results/`
4. **Clean up** - Always run `make test-cleanup` when done
5. **Read the documentation** - For detailed test explanations

## 🚨 Troubleshooting

Common issues and solutions:

- **Docker not running**: Start Docker before running tests
- **Kind clusters exist**: Run `make test-cleanup` first
- **Permission errors**: Use `sudo` for Docker commands if needed
- **Port conflicts**: Ensure no other services use ports 3000-3002
- **Slow performance**: Use `--no-snapshot` flag for faster tests

For detailed troubleshooting, see the [Testing Guide](testing-guide.md).

## � Validation Testing

For quick validation of ArgoCD control plane health:

```bash
# Run validation test only
make test-argocd-validate

# Or run as part of unit tests
make test-unit
```

The validation test verifies that:
- ArgoCD can connect to repositories
- ArgoCD can connect to clusters
- Application dry-run syncs work correctly
- Target ArgoCD is ready for migration

## �🎉 Next Steps

After successful testing:
1. **Review test results** in `test-results/`
2. **Read the architecture guide** to understand how it works
3. **Prepare your production environment** following the quick start guide
4. **Generate a runbook** for your specific migration

Happy testing! 🚀