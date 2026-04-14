#!/usr/bin/env python3
"""
Unit tests for cleanup-source.sh script using Python for reliable error handling.
"""

import os
import subprocess
import tempfile
import shutil
import sys


def create_test_manifests(temp_dir):
    """Create test manifests in a temporary directory."""
    source_path = os.path.join(temp_dir, "source")
    os.makedirs(source_path, exist_ok=True)
    
    # Create dummy source manifest
    with open(os.path.join(source_path, "apps-test-cluster.yaml"), "w") as f:
        f.write("""apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: apps-test-cluster
spec:
  source:
    repoURL: 'https://github.com/example/repo'
    targetRevision: HEAD
  destination:
    server: 'https://kubernetes.default.svc'
    name: in-cluster
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
""")
    
    # Create target kustomization.yaml
    with open(os.path.join(source_path, "kustomization.yaml"), "w") as f:
        f.write("""apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - apps-test-cluster.yaml
""")
    
    return source_path


def test_cleanup_source():
    """Test the cleanup-source.sh script."""
    # Create temporary directory
    temp_dir = tempfile.mkdtemp()
    try:
        source_path = create_test_manifests(temp_dir)
        
        # Create environment file
        env_file = os.path.join(temp_dir, "test-env.env")
        with open(env_file, "w") as f:
            f.write("""# Minimal test environment for migration
SOURCE_CLUSTER=source-cluster
SOURCE_KUBECONTEXT=source-context
SOURCE_ARGO_URL=https://source.argocd.example.com
SOURCE_ARGO_LOGIN_ARGS="--username admin --password test"

TARGET_CLUSTER=target-cluster
TARGET_KUBECONTEXT=target-context
TARGET_ARGO_URL=https://target.argocd.example.com
TARGET_ARGO_LOGIN_ARGS="--username admin --password test"
TARGET_ARGO_APP=target-cluster.apps

SAFE_DELETE_PARENT_APPS="source-cluster.apps"
TARGET_ARGO_SYNC_APPS="target-cluster.apps"
""")
        
        # Test successful execution with dry-run
        env = os.environ.copy()
        env["MIG_ALLOW_EXTERNAL_ENV"] = "true"
        
        # Mock argocd command
        mock_argocd_script = os.path.join(temp_dir, "mock_argocd.sh")
        with open(mock_argocd_script, "w") as f:
            f.write("""#!/bin/bash
case "$1" in
    app)
        # Mock app get command
        if [[ "$2" == "get" ]]; then
            echo '{"status":{"health":{"status":"Healthy"},"sync":{"status":"Synced"}}}'
            exit 0
        fi
        ;;
esac
# Default behavior
echo "Mock argocd command called with args: $@"
exit 0""")
        os.chmod(mock_argocd_script, 0o755)
        env["ARGOCD_BIN"] = mock_argocd_script
        
        # Change to temp directory to use relative paths
        old_cwd = os.getcwd()
        os.chdir(temp_dir)
        
        try:
            # Use absolute path for the script
            script_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../scripts/migration/cleanup-source.sh")
            
            cmd = [
                script_path,
                "--dry-run",
                "--source", "source",
                "--cluster", "test-cluster",
                "--parent-app", "test-cluster.apps",
                "--target-argo-url", "https://target.argocd.example.com",
                "--target-argo-app", "test-cluster.apps"
            ]
            
            result = subprocess.run(cmd, env=env, capture_output=True, text=True)
            
            if result.returncode != 0:
                print(f"❌ cleanup-source.sh failed: {result.stderr}")
                print(f"stdout: {result.stdout}")
                return False
            
            print("✅ cleanup-source.sh executed successfully in dry-run mode")
            
            # Test with missing source directory
            os.remove(os.path.join(source_path, "apps-test-cluster.yaml"))
            os.remove(os.path.join(source_path, "kustomization.yaml"))
            os.rmdir(source_path)
            
            cmd = [
                script_path,
                "--dry-run",
                "--source", "source",
                "--cluster", "test-cluster",
                "--parent-app", "test-cluster.apps",
                "--target-argo-url", "https://target.argocd.example.com",
                "--target-argo-app", "test-cluster.apps"
            ]
            
            result = subprocess.run(cmd, env=env, capture_output=True, text=True)
            
            # The script should fail with a non-zero exit code for missing source directory
            if result.returncode == 0:
                print(f"❌ Script should fail with non-zero exit code for missing source directory")
                return False
            
            print("✅ Missing source directory error handled correctly")
            return True
        finally:
            os.chdir(old_cwd)
    
    finally:
        # Clean up
        shutil.rmtree(temp_dir)


if __name__ == "__main__":
    if test_cleanup_source():
        print("🎉 All tests passed!")
        sys.exit(0)
    else:
        print("❌ Some tests failed")
        sys.exit(1)