#!/usr/bin/env python3
"""
Unit tests for prep-commit-a.sh script using Python for reliable error handling.
"""

import os
import subprocess
import tempfile
import shutil
import sys


def create_test_manifests(temp_dir):
    """Create test manifests in a temporary directory."""
    source_path = os.path.join(temp_dir, "source")
    target_path = os.path.join(temp_dir, "target")
    os.makedirs(source_path, exist_ok=True)
    os.makedirs(target_path, exist_ok=True)
    
    # Initialize git repository
    subprocess.run(["git", "init"], cwd=temp_dir, capture_output=True)
    subprocess.run(["git", "config", "user.name", "Test User"], cwd=temp_dir, capture_output=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=temp_dir, capture_output=True)
    
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
    with open(os.path.join(target_path, "kustomization.yaml"), "w") as f:
        f.write("""apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - apps-test-cluster.yaml
""")
    
    return source_path, target_path


def test_prep_commit_a():
    """Test the prep-commit-a.sh script."""
    # Create temporary directory
    temp_dir = tempfile.mkdtemp()
    try:
        source_path, target_path = create_test_manifests(temp_dir)
        
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
        
        # Test successful execution
        env = os.environ.copy()
        env["MIG_ALLOW_EXTERNAL_ENV"] = "true"
        
        # Change to temp directory to use relative paths
        old_cwd = os.getcwd()
        os.chdir(temp_dir)
        
        try:
            # Use absolute path for the script
            script_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../scripts/migration/prep-commit-a.sh")
            
            cmd = [
                script_path,
                "--cluster", "test-cluster",
                "--source", "source",
                "--target", "target"
            ]
            
            result = subprocess.run(cmd, env=env, capture_output=True, text=True)
            
            if result.returncode != 0:
                print(f"❌ prep-commit-a.sh failed: {result.stderr}")
                return False
            
            print("✅ prep-commit-a.sh executed successfully")
            
            # Test with missing source file
            os.remove(os.path.join(source_path, "apps-test-cluster.yaml"))
            
            cmd = [
                script_path,
                "--cluster", "test-cluster",
                "--source", "source",
                "--target", "target"
            ]
            
            result = subprocess.run(cmd, env=env, capture_output=True, text=True)
            
            # The script should fail with a non-zero exit code for missing source file
            if result.returncode == 0:
                print(f"❌ Script should fail with non-zero exit code for missing source file")
                return False
            
            print("✅ Missing source file error handled correctly")
            return True
        finally:
            os.chdir(old_cwd)
    
    finally:
        # Clean up
        shutil.rmtree(temp_dir)


if __name__ == "__main__":
    if test_prep_commit_a():
        print("🎉 All tests passed!")
        sys.exit(0)
    else:
        print("❌ Some tests failed")
        sys.exit(1)