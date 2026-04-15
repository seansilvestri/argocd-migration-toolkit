.PHONY: help test test-setup test-run test-run-appset test-run-path-based test-verify test-cleanup test-full test-full-appset test-full-path-based clean

# Default target
help:
	@echo "ArgoCD Migration Toolkit - Test Commands"
	@echo ""
	@echo "Usage:"
	@echo "  make test-full               Run complete test suite (setup → migrate → verify → cleanup)"
	@echo "  make test-full-appset        Run ApplicationSet test suite"
	@echo "  make test-full-path-based    Run path-based discovery test suite"
	@echo "  make test-setup              Setup test environment (Kind clusters + ArgoCD) - SLOW"
	@echo "  make test-run                Run migration test (single app) - FAST"
	@echo "  make test-run-appset         Run migration test (ApplicationSet) - FAST"
	@echo "  make test-run-path-based     Run path-based discovery test - FAST"
	@echo "  make test-verify             Verify migration results"
	@echo "  make test-cleanup            Cleanup test environment"
	@echo "  make clean                   Remove test artifacts and results"
	@echo ""
	@echo "Quick test:"
	@echo "  make test-full          # Test single Application migration"
	@echo "  make test-full-appset   # Test ApplicationSet migration"
	@echo "  make test-full-path-based # Test path-based discovery migration"
	@echo ""
	@echo "Iterative testing (setup once, iterate on migration):"
	@echo "  make test-setup         # Run once (5-10 min)"
	@echo "  make test-run           # Run standard migration (can repeat)"
	@echo "  make test-run-appset    # Run ApplicationSet migration (can repeat)"
	@echo "  make test-run-path-based # Run path-based migration (can repeat)"
	@echo "  make test-verify        # Verify results"
	@echo "  make test-cleanup       # Cleanup when done"

# Run complete test suite (single app)
test-full: test-setup test-run test-verify test-cleanup
	@echo "✅ Full test suite completed successfully!"

# Run complete test suite (ApplicationSet)
test-full-appset: test-setup test-run-appset test-verify test-cleanup
	@echo "✅ Full ApplicationSet test suite completed successfully!"

# Run complete test suite (path-based discovery)
test-full-path-based: test-setup test-run-path-based test-verify test-cleanup
	@echo "✅ Full path-based discovery test suite completed successfully!"

# Setup test environment (clusters + ArgoCD only)
test-setup:
	@echo "🚀 Setting up test environment..."
	@./tests/setup-test-env.sh

# Run migration test (single app)
test-run:
	@echo "🔄 Running migration test (single app)..."
	@./tests/run-migration-test.sh

# Run migration test (ApplicationSet)
test-run-appset:
	@echo "🔄 Running migration test (ApplicationSet)..."
	@./tests/run-migration-test-appset.sh

# Run migration test (path-based discovery)
test-run-path-based:
	@echo "🔄 Running path-based discovery test..."
	@./tests/run-migration-test-path-based.sh

test-argocd-validate:
	@echo "✅ Running argocd validate test..."
	@./tests/run-argocd-validation.sh

# Verify migration results
test-verify:
	@echo "✅ Verifying migration results..."
	@./tests/verify-migration.sh

# Cleanup test environment
test-cleanup:
	@echo "🧹 Cleaning up test environment..."
	@./tests/cleanup-test-env.sh

# Remove test artifacts
clean:
	@echo "🧹 Removing test artifacts..."
	@rm -rf test-results/
	@rm -rf snapshots/
	@rm -rf envs/test-*.env
	@rm -rf runbooks/test-*.md
	@echo "✅ Cleanup complete"

# Run unit tests
test-unit:
	@echo "🧪 Running unit tests..."
	@python3 tests/test_generate_runbook.py
	@python3 tests/test_prep_commit_a.py
	@python3 tests/test_disarm_source.py
	@python3 tests/test_cleanup_source.py
	@python3 tests/test_sync_target_apps.py
	@python3 tests/test_prep_commit_b_cleanup.py
	@python3 tests/test_argocd_validate.py
	@echo "✅ Unit tests completed successfully!"

# Alias for backward compatibility
test: test-full
