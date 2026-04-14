#!/usr/bin/env python3
"""
Unit tests for sync-target-apps.sh script using Python for reliable error handling.
"""

import os
import subprocess
import tempfile
import shutil
import sys


def test_sync_target_apps():
    """Test the sync-target-apps.sh script."""
    # Create temporary directory
    temp_dir = tempfile.mkdtemp()
    try:
        # Create environment file
        env_file = os.path.join(temp_dir, "test-env.env")
        with open(env_file, "w") as f:
            f.write("""# Minimal test environment for migration
TARGET_CLUSTER=target-cluster
TARGET_KUBECONTEXT=target-context
TARGET_ARGO_URL=https://target.argocd.example.com
TARGET_ARGO_LOGIN_ARGS="--username admin --password test"
TARGET_ARGO_SYNC_APPS="test-cluster.apps"
""")
        
        # Test successful execution with dry-run
        env = os.environ.copy()
        env["MIG_ALLOW_EXTERNAL_ENV"] = "true"
        
        # Mock argocd command
        mock_argocd_script = os.path.join(temp_dir, "mock_argocd.sh")
        with open(mock_argocd_script, "w") as f:
            f.write("""#!/bin/bash
case "$1" in
    version)
        echo "v3.2.0"
        exit 0
        ;;
    account)
        # Mock account get-user-info command
        if [[ "$2" == "get-user-info" ]]; then
            echo '{"username":"admin"}'
            exit 0
        fi
        ;;
    app)
        # Mock app commands
        if [[ "$2" == "get" ]]; then
            if [[ "$3" == "--hard-refresh" ]]; then
                echo '{"status":{"health":{"status":"Healthy"},"sync":{"status":"Synced"}}}'
                exit 0
            elif [[ "$3" == "--output" ]]; then
                echo '{"status":{"health":{"status":"Healthy"},"sync":{"status":"Synced"}}}'
                exit 0
            else
                echo '{"status":{"health":{"status":"Healthy"},"sync":{"status":"Synced"}}}'
                exit 0
            fi
        elif [[ "$2" == "sync" ]]; then
            exit 0
        elif [[ "$2" == "diff" ]]; then
            exit 0
        fi
        ;;
esac
# Default behavior
echo "Mock argocd command called with args: $@"
exit 0""")
        os.chmod(mock_argocd_script, 0o755)
        
        # Create a symbolic link to mock_argocd.sh named argocd
        argocd_link = os.path.join(temp_dir, "argocd")
        os.symlink("mock_argocd.sh", argocd_link)
        
        # Add temp_dir to PATH
        env["PATH"] = f"{temp_dir}:{env.get('PATH', '')}"
        
        # Change to temp directory to use relative paths
        old_cwd = os.getcwd()
        os.chdir(temp_dir)
        
        try:
            # Use absolute path for the script
            script_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../scripts/migration/sync-target-apps.sh")
            
            cmd = [
                script_path,
                "--target-argo-url", "https://target.argocd.example.com",
                "--app", "test-cluster.apps",
                "--dry-run"
            ]
            
            result = subprocess.run(cmd, env=env, capture_output=True, text=True)
            
            if result.returncode != 0:
                print(f"❌ sync-target-apps.sh failed: {result.stderr}")
                print(f"stdout: {result.stdout}")
                return False
            
            print("✅ sync-target-apps.sh executed successfully in dry-run mode")
            
            # Test with missing target URL
            cmd = [
                script_path,
                "--app", "test-cluster.apps",
                "--dry-run"
            ]
            
            result = subprocess.run(cmd, env=env, capture_output=True, text=True)
            
            # The script should fail with a non-zero exit code for missing target URL
            if result.returncode == 0:
                print(f"❌ Script should fail with non-zero exit code for missing target URL")
                return False
            
            print("✅ Missing target URL error handled correctly")
            return True
        finally:
            os.chdir(old_cwd)
    
    finally:
        # Clean up
        shutil.rmtree(temp_dir)


if __name__ == "__main__":
    if test_sync_target_apps():
        print("🎉 All tests passed!")
        sys.exit(0)
    else:
        print("❌ Some tests failed")
        sys.exit(1)