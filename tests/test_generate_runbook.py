#!/usr/bin/env python3
"""
Unit tests for generate-runbook.sh script using Python for reliable error handling.
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
    
    # Create dummy source manifest
    with open(os.path.join(source_path, "app1.yaml"), "w") as f:
        f.write("""apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app1
spec:
  source:
    repoURL: 'https://github.com/example/repo'
    targetRevision: HEAD
  destination:
    server: 'https://kubernetes.default.svc'
""")
    
    # Create dummy target manifest
    with open(os.path.join(target_path, "app1.yaml"), "w") as f:
        f.write("""apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app1
spec:
  source:
    repoURL: 'https://github.com/example/repo'
    targetRevision: HEAD
  destination:
    server: 'https://kubernetes.default.svc'
""")
    
    return source_path, target_path


def test_generate_runbook():
    """Test the generate-runbook.sh script."""
    # Create temporary directory
    temp_dir = tempfile.mkdtemp()
    try:
        source_path, target_path = create_test_manifests(temp_dir)
        output_file = os.path.join(temp_dir, "runbook.md")
        
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
        
        # Test successful runbook generation
        env = os.environ.copy()
        env["MIG_ALLOW_EXTERNAL_ENV"] = "true"
        
        cmd = [
            "./scripts/migration/generate-runbook.sh",
            env_file,
            "--output", output_file,
            "--app-file", os.path.join(source_path, "app1.yaml")
        ]
        
        result = subprocess.run(cmd, env=env, capture_output=True, text=True)
        
        if result.returncode != 0:
            print(f"❌ Runbook generation failed: {result.stderr}")
            return False
        
        if not os.path.exists(output_file):
            print("❌ Runbook output file not created")
            return False
        
        print("✅ Runbook generated successfully")
        
        # Test with missing app file
        os.remove(os.path.join(source_path, "app1.yaml"))
        
        # Create a non-existent file path
        nonexistent_file = os.path.join(temp_dir, "nonexistent.yaml")
        
        cmd = [
            "./scripts/migration/generate-runbook.sh",
            env_file,
            "--output", output_file,
            "--app-file", nonexistent_file
        ]
        
        result = subprocess.run(cmd, env=env, capture_output=True, text=True)
        
        # The script should fail with a non-zero exit code for missing files
        # and generate an error message
        if result.returncode != 1:
            print(f"❌ Script should fail with non-zero exit code for missing files, got {result.returncode}")
            return False
        if "App file not found" not in result.stdout:
            print(f"❌ Missing source error not handled correctly: {result.stdout}")
            return False
        
        print("✅ Missing source error handled correctly")
        return True
    
    finally:
        # Clean up
        shutil.rmtree(temp_dir)


if __name__ == "__main__":
    if test_generate_runbook():
        print("🎉 All tests passed!")
        sys.exit(0)
    else:
        print("❌ Some tests failed")
        sys.exit(1)