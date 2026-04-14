#!/usr/bin/env python3
"""
Unit tests for prep-commit-b-cleanup.sh script using Python for reliable error handling.
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
    
    # Create source manifests
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
    
    with open(os.path.join(source_path, "kustomization.yaml"), "w") as f:
        f.write("""apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - apps-test-cluster.yaml
""")
    
    # Create target manifests
    with open(os.path.join(target_path, "apps-test-cluster.yaml"), "w") as f:
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
    
    return source_path, target_path


def test_prep_commit_b_cleanup():
    """Test the prep-commit-b-cleanup.sh script."""
    # Create temporary directory
    temp_dir = tempfile.mkdtemp()
    try:
        source_path, target_path = create_test_manifests(temp_dir)
        
        # Initialize a git repository
        os.chdir(temp_dir)
        subprocess.run(["git", "init"], check=True, capture_output=True)
        subprocess.run(["git", "config", "user.name", "Test User"], check=True, capture_output=True)
        subprocess.run(["git", "config", "user.email", "test@example.com"], check=True, capture_output=True)
        
        # Add files to git
        subprocess.run(["git", "add", "."], check=True, capture_output=True)
        subprocess.run(["git", "commit", "-m", "Initial commit"], check=True, capture_output=True)
        
        # Mock yq command
        mock_yq_script = os.path.join(temp_dir, "mock_yq.sh")
        with open(mock_yq_script, "w") as f:
            f.write("""#!/bin/bash
case "$1" in
    --version)
        echo "yq version 4.35.2"
        exit 0
        ;;
    -i)
        # Mock yq -i command (in-place edit)
        if [[ "$2" == "del(.resources[]"* ]]; then
            # Create a copy of the file without the resource
            cp "$3" "$3.tmp"
            # Remove the line containing the resource
            sed -i '' '/apps-test-cluster.yaml/d' "$3.tmp"
            # Move back
            mv "$3.tmp" "$3"
            exit 0
        fi
        ;;
    eval)
        # Mock yq eval command
        if [[ "$2" == ".kind" ]]; then
            echo "Application"
            exit 0
        elif [[ "$2" == "documentIndex" ]]; then
            echo "1"
            exit 0
        elif [[ "$2" == ".spec.syncPolicy.automated.prune"* ]]; then
            echo "true"
            exit 0
        elif [[ "$2" == ".spec.syncPolicy.automated.selfHeal"* ]]; then
            echo "true"
            exit 0
        fi
        ;;
esac
# Default behavior
echo "Mock yq command called with args: $@"
exit 0""")
        os.chmod(mock_yq_script, 0o755)
        
        # Mock toggle-autosync.sh script
        mock_toggle_script = os.path.join(temp_dir, "mock_toggle-autosync.sh")
        with open(mock_toggle_script, "w") as f:
            f.write("""#!/bin/bash
echo "Mock toggle-autosync.sh called with args: $@"
exit 0""")
        os.chmod(mock_toggle_script, 0o755)
        
        # Set environment variables
        env = os.environ.copy()
        env["YQ_BIN"] = mock_yq_script
        env["PATH"] = f"{temp_dir}:{env.get('PATH', '')}"
        
        try:
            # Use absolute path for the script
            script_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../scripts/migration/prep-commit-b-cleanup.sh")
            
            cmd = [
                script_path,
                "--cluster", "test-cluster",
                "--source", "source",
                "--target", "target"
            ]
            
            result = subprocess.run(cmd, env=env, capture_output=True, text=True)
            
            if result.returncode != 0:
                print(f"❌ prep-commit-b-cleanup.sh failed: {result.stderr}")
                print(f"stdout: {result.stdout}")
                return False
            
            print("✅ prep-commit-b-cleanup.sh executed successfully")
            
            # Test with missing source directory
            if os.path.exists(os.path.join(source_path, "apps-test-cluster.yaml")):
                os.remove(os.path.join(source_path, "apps-test-cluster.yaml"))
            if os.path.exists(os.path.join(source_path, "kustomization.yaml")):
                os.remove(os.path.join(source_path, "kustomization.yaml"))
            if os.path.exists(source_path):
                os.rmdir(source_path)
            
            cmd = [
                script_path,
                "--cluster", "test-cluster",
                "--source", "source",
                "--target", "target"
            ]
            
            result = subprocess.run(cmd, env=env, capture_output=True, text=True)
            
            # The script should fail with a non-zero exit code for missing source directory
            if result.returncode == 0:
                print(f"❌ Script should fail with non-zero exit code for missing source directory")
                return False
            
            print("✅ Missing source directory error handled correctly")
            return True
        finally:
            os.chdir("/")
    
    finally:
        # Clean up
        shutil.rmtree(temp_dir)


if __name__ == "__main__":
    if test_prep_commit_b_cleanup():
        print("🎉 All tests passed!")
        sys.exit(0)
    else:
        print("❌ Some tests failed")
        sys.exit(1)