#!/usr/bin/env python3
"""
Unit tests for argocd_validate.py script using Python for reliable error handling.
"""

import os
import subprocess
import tempfile
import shutil
import sys
import json


def create_test_config():
    """Create a test configuration file for argocd_validate.py."""
    config = {
        "config": {
            "repoURL": "https://github.com/example/repo",
            "path": ".",
            "targetRevision": "HEAD",
            "project": "default",
            "destinationNamespace": "default"
        },
        "tests": [
            {
                "name": "test-app",
                "repoURL": "https://github.com/example/repo",
                "path": ".",
                "targetRevision": "HEAD",
                "destination": {
                    "name": "test-cluster",
                    "namespace": "default"
                },
                "active": True
            }
        ]
    }
    return config


def test_argocd_validate():
    """Test the argocd_validate.py script."""
    # Create temporary directory
    temp_dir = tempfile.mkdtemp()
    try:
        # Create test config file
        config = create_test_config()
        config_file = os.path.join(temp_dir, "test-config.json")
        with open(config_file, "w") as f:
            json.dump(config, f, indent=2)
        
        # Mock argocd command
        mock_argocd_script = os.path.join(temp_dir, "mock_argocd.sh")
        with open(mock_argocd_script, "w") as f:
            f.write("""#!/bin/bash
case "$1" in
    version)
        echo "argocd CLI 3.2.0"
        exit 0
        ;;
    repo)
        # Mock repo commands
        if [[ "$2" == "list" ]]; then
            echo '[{"name": "test-repo", "repo": "https://github.com/example/repo", "connectionState": {"status": "Success"}}]' | jq '.'
            exit 0
        elif [[ "$2" == "get" ]]; then
            echo '{"name": "test-repo", "repo": "https://github.com/example/repo", "connectionState": {"status": "Success"}}' | jq '.'
            exit 0
        fi
        ;;
    cluster)
        # Mock cluster commands
        if [[ "$2" == "list" ]]; then
            echo '[{"name": "test-cluster", "server": "https://test-cluster.example.com", "connectionState": {"status": "Success"}}]' | jq '.'
            exit 0
        fi
        ;;
    app)
        # Mock app commands
        if [[ "$2" == "create" ]]; then
            exit 0
        elif [[ "$2" == "sync" ]]; then
            if [[ "$3" == "--dry-run" ]]; then
                echo "Application test-app would be synced with the following changes:"
                exit 0
            fi
        elif [[ "$2" == "delete" ]]; then
            exit 0
        fi
        ;;
esac
# Default behavior
echo "Mock argocd command called with args: $@"
exit 0""")
        os.chmod(mock_argocd_script, 0o755)
        
        # Set environment variables
        env = os.environ.copy()
        env["PATH"] = f"{temp_dir}:{env.get('PATH', '')}"
        
        # Change to temp directory to use relative paths
        old_cwd = os.getcwd()
        os.chdir(temp_dir)
        
        try:
            # Use absolute path for the script
            script_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../scripts/validation/argocd_validate.py")
            
            cmd = [
                sys.executable, script_path,
                "--tests-file", "test-config.json",
                "--argocd-cli", "mock_argocd.sh"
            ]
            
            result = subprocess.run(cmd, env=env, capture_output=True, text=True)
            
            if result.returncode != 0:
                print(f"❌ argocd_validate.py failed: {result.stderr}")
                print(f"stdout: {result.stdout}")
                return False
            
            print("✅ argocd_validate.py executed successfully")
            
            # Test with missing config file
            os.remove(config_file)
            
            cmd = [
                sys.executable, script_path,
                "--tests-file", "test-config.json",
                "--argocd-cli", "mock_argocd.sh"
            ]
            
            result = subprocess.run(cmd, env=env, capture_output=True, text=True)
            
            # The script should fail with a non-zero exit code for missing config file
            if result.returncode == 0:
                print(f"❌ Script should fail with non-zero exit code for missing config file")
                return False
            
            print("✅ Missing config file error handled correctly")
            return True
        finally:
            os.chdir(old_cwd)
    
    finally:
        # Clean up
        shutil.rmtree(temp_dir)


if __name__ == "__main__":
    if test_argocd_validate():
        print("🎉 All tests passed!")
        sys.exit(0)
    else:
        print("❌ Some tests failed")
        sys.exit(1)