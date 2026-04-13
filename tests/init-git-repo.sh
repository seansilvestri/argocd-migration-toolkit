#!/bin/bash
set -euo pipefail

# Initialize a Git repository in the Gitea server and push fixtures to it
# Usage: ./init-git-repo.sh <fixture-dir> <repo-name>

FIXTURE_DIR="${1:-tests/fixtures/simple-app}"
REPO_NAME="${2:-test-repo}"

echo "🔧 Initializing Git repository in Gitea..."
echo "  Fixture: $FIXTURE_DIR"
echo "  Repo: $REPO_NAME"

# Wait for Gitea to be fully ready
echo "  Waiting for Gitea API..."
kubectl wait --for=condition=available --timeout=120s deployment/git-server -n default --context kind-source-argocd

# Port forward to Gitea
kubectl port-forward svc/git-server -n default 3000:3000 --context kind-source-argocd > /dev/null 2>&1 &
PF_PID=$!
sleep 5

cleanup() {
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

# Create admin user via kubectl exec
echo "  Creating Gitea admin user..."
kubectl exec -n default deployment/git-server --context kind-source-argocd -- \
    gitea admin user create --admin --username gitea --password gitea123 --email gitea@local.test --must-change-password=false 2>/dev/null || echo "  User already exists"

# Wait a moment for Gitea to be fully ready
sleep 2

# Delete existing repository if it exists (for idempotency)
echo "  Deleting existing repository if present..."
curl -s -X DELETE "http://localhost:3000/api/v1/repos/gitea/$REPO_NAME" \
    -u "gitea:gitea123" > /dev/null 2>&1 || true

# Create repository via API
echo "  Creating repository '$REPO_NAME' via API..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "http://localhost:3000/api/v1/user/repos" \
    -u "gitea:gitea123" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$REPO_NAME\",\"private\":false,\"auto_init\":false,\"default_branch\":\"master\"}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
if [ "$HTTP_CODE" = "201" ]; then
    echo "  Repository created successfully (HTTP $HTTP_CODE)"
elif [ "$HTTP_CODE" = "409" ]; then
    echo "  Repository already exists (HTTP $HTTP_CODE) - this shouldn't happen after delete"
else
    echo "  Warning: API returned HTTP $HTTP_CODE"
    echo "$RESPONSE" | head -n-1
fi

# Initialize fixture as Git repo and push
echo "  Initializing fixture as Git repo..."
TEMP_DIR=$(mktemp -d)
cp -r "$FIXTURE_DIR"/* "$TEMP_DIR/"
cd "$TEMP_DIR"

git init
git config user.email "test@test.local"
git config user.name "Test User"
git add .
git commit -m "Initial commit"

# Push to Gitea (with credentials in URL)
echo "  Pushing to Gitea..."
# URL encode the password if needed, but gitea123 doesn't have special chars
git remote add origin "http://gitea:gitea123@localhost:3000/gitea/$REPO_NAME.git"
GIT_TERMINAL_PROMPT=0 git push -u origin master 2>&1 | grep -v "warning:" || {
    echo "  Push failed, trying with explicit credentials..."
    git push -u origin master 2>&1 | grep -v "warning:" || true
}

cd -
rm -rf "$TEMP_DIR"

echo "✅ Git repository initialized!"
echo ""
echo "Repository URL (from within cluster):"
echo "  http://git-server.default.svc.cluster.local:3000/gitea/$REPO_NAME.git"
echo ""
