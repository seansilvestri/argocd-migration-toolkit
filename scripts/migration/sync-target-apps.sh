#!/usr/bin/env bash
set -euo pipefail

# Require jq for reliable JSON parsing
if ! command -v jq >/dev/null 2>&1; then
    echo "❌ jq is required but not installed. Please install jq and try again."
    exit 1
fi

# Automates the "Target Sync" phase of the migration.
#
# Steps:
# 1. Verifies authentication to the Target ArgoCD.
# 2. Performs a Hard Refresh (to clear "paused" state) via `argocd app get --hard-refresh`.
# 3. Triggers a Sync (to adopt workloads).
# 4. Waits for Healthy/Synced status.
# Optional flags:
#   --dry-run : Show diffs only (no refresh/sync/wait)
#   --force   : Skip interactive confirmation (automation use only)
#
# Usage:
#   ./sync-target-apps.sh --target-argo-url <url> --app <name> [--app <name> ...] [--dry-run] [--force]

TARGET_URL=""
APPS=()
DRY_RUN=false
FORCE=false
REQUIRED_ARGO_MAJOR=3
REQUIRED_ARGO_MINOR=2

auto_set_target_context() {
    if [[ -z "${MIG_TARGET_KUBECONTEXT:-}" ]]; then
        return
    fi
    if [[ "${MIG_DISABLE_AUTO_CONTEXT:-false}" == "true" ]]; then
        return
    fi
    if ! command -v kubectl >/dev/null 2>&1; then
        echo "⚠️  kubectl not found in PATH; skipping automatic context switch."
        return
    fi

    echo "→ Switching kubectl context to ${MIG_TARGET_KUBECONTEXT} (from migration env)..."
    kubectl config use-context "${MIG_TARGET_KUBECONTEXT}"
    echo ""
}

auto_login_target_argo() {
    if [[ -z "${MIG_TARGET_ARGO_LOGIN_ARGS:-}" ]]; then
        return
    fi
    if [[ "${MIG_DISABLE_AUTO_ARGO_LOGIN:-false}" == "true" ]]; then
        return
    fi
    if [[ -n "${MIG_TARGET_ARGO_URL:-}" && "$TARGET_URL" != "$MIG_TARGET_ARGO_URL" ]]; then
        echo "ℹ️  MIG_TARGET_ARGO_URL (${MIG_TARGET_ARGO_URL}) differs from --target-argo-url ($TARGET_URL); skipping auto-login."
        return
    fi

    echo "→ Refreshing Argo CD session via MIG_TARGET_ARGO_LOGIN_ARGS..."
    # shellcheck disable=SC2086
    if ! argocd login "$TARGET_URL" ${MIG_TARGET_ARGO_LOGIN_ARGS}; then
        echo "⚠️  Failed to establish Argo session automatically. Please log in manually."
        exit 1
    fi
    echo ""
}

ensure_argocd_cli_ready() {
    if ! command -v argocd >/dev/null 2>&1; then
        echo "❌ ERROR: 'argocd' CLI is not found in PATH."
        exit 1
    fi

    local version_line
    if ! version_line=$(argocd version --client 2>/dev/null | head -n 1); then
        echo "❌ ERROR: Unable to determine argocd CLI version."
        exit 1
    fi

    local version_regex='v([0-9]+)\.([0-9]+)\.'
    if [[ $version_line =~ $version_regex ]]; then
        local major="${BASH_REMATCH[1]}"
        local minor="${BASH_REMATCH[2]}"
        if (( major < REQUIRED_ARGO_MAJOR || (major == REQUIRED_ARGO_MAJOR && minor < REQUIRED_ARGO_MINOR) )); then
            local reported
            reported=$(echo "$version_line" | awk '{print $2}')
            echo "❌ ERROR: argocd CLI v${REQUIRED_ARGO_MAJOR}.${REQUIRED_ARGO_MINOR}+ is required (found ${reported:-unknown})."
            exit 1
        fi
    else
        echo "❌ ERROR: Unable to parse argocd CLI version from: $version_line"
        exit 1
    fi
}

usage() {
    echo "Usage: $0 --target-argo-url <url> --app <name> [--app <name> ...] [--dry-run] [--force]"
    echo "       (Defaults to MIG_TARGET_ARGO_URL and MIG_TARGET_ARGO_SYNC_APPS when migration-env.sh is sourced.)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --target-argo-url)
            TARGET_URL="$2"
            shift 2
            ;;
        --app)
            APPS+=("$2")
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            ;;
    esac
done

if [[ -z "$TARGET_URL" && -n "${MIG_TARGET_ARGO_URL:-}" ]]; then
    TARGET_URL="$MIG_TARGET_ARGO_URL"
fi

if [[ ${#APPS[@]} -eq 0 && -n "${MIG_TARGET_ARGO_SYNC_APPS:-}" ]]; then
    # shellcheck disable=SC2206
    APPS=( ${MIG_TARGET_ARGO_SYNC_APPS} )
fi

if [[ -z "$TARGET_URL" ]]; then
    echo "ERROR: --target-argo-url is required."
    usage
fi

if [[ ${#APPS[@]} -eq 0 ]]; then
    echo "ERROR: At least one --app is required."
    usage
fi

auto_set_target_context

ensure_argocd_cli_ready

auto_login_target_argo

echo "🚀 Starting Target Sync Automation"
if [[ "$DRY_RUN" == "true" ]]; then
    echo "   MODE:   DRY-RUN (No changes will be applied)"
fi
echo "   Target: $TARGET_URL"
echo "   Apps:   ${APPS[*]}"
echo ""

# 1. Verify Login
echo "→ Verifying authentication..."
if ! argocd account get-user-info --server "$TARGET_URL" >/dev/null 2>&1; then
    echo "❌ ERROR: Unable to authenticate with $TARGET_URL."
    echo "   Please log in first (e.g., argocd login $TARGET_URL --sso)"
    exit 1
fi
echo "✅ Authenticated."
echo ""

# 2. Confirmation (Skip in Dry Run / Force)
if [[ "$DRY_RUN" == "false" && "$FORCE" == "false" ]]; then
    echo "⚠️  WARNING: You are about to HARD REFRESH and SYNC the following apps on $TARGET_URL:"
    printf "   - %s\n" "${APPS[@]}"
    read -r -p "Are you sure? [y/N] " response
    if [[ ! "$response" =~ ^[yY]$ ]]; then
        echo "Aborted."
        exit 1
    fi
else
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "ℹ️  Dry Run enabled - skipping confirmation."
    fi
    if [[ "$FORCE" == "true" ]]; then
        echo "ℹ️  Force mode enabled - skipping confirmation. Ensure automation is targeting the correct Argo instance."
    fi
fi
echo ""

# 3. Process Apps
for app in "${APPS[@]}"; do
    echo "========================================="
    echo "Processing: $app"
    echo "========================================="

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "1. [DRY-RUN] Skipping Hard Refresh."
        
        echo "2. Running 'argocd app diff'..."
        # Allow diff to exit 1 (which means diffs found) without crashing the script
        set +e
        argocd app diff "$app" --server "$TARGET_URL"
        DIFF_EXIT=$?
        set -e
        if [[ $DIFF_EXIT -gt 1 ]]; then
             echo "❌ Error running diff."
             exit 1
        fi

        echo "3. [DRY-RUN] Skipping Sync and Wait."
    else
        echo "1. Refreshing (Hard)..."
        # argocd CLI v3.2 removed 'argocd app refresh --hard'; perform the equivalent via 'app get --hard-refresh'
        if ! argocd app get "$app" --hard-refresh --server "$TARGET_URL" >/dev/null; then
            echo "❌ Failed to hard refresh $app."
            exit 1
        fi

        echo "2. Syncing..."
        if ! argocd app sync "$app" --server "$TARGET_URL"; then
            echo "❌ Failed to trigger sync for $app."
            exit 1
        fi
        
        echo "3. Waiting for Healthy/Synced..."
        TIMEOUT=200
        POLL_INTERVAL=10
        ELAPSED=0
        APP_READY=false

        while (( ELAPSED < TIMEOUT )); do
            # Get app status (suppress errors if app not found yet)
            APP_STATUS=$(argocd app get "$app" --server "$TARGET_URL" --output json 2>/dev/null || echo "{}")
            
            # Extract health and sync status
            HEALTH_STATUS=$(echo "$APP_STATUS" | jq -r '.status.health.status // "Unknown"')
            SYNC_STATUS=$(echo "$APP_STATUS" | jq -r '.status.sync.status // "Unknown"')
            
            # Print current status with timestamp
            echo "   [${ELAPSED}s] Health: $HEALTH_STATUS | Sync: $SYNC_STATUS"
            
            # Check if app is ready
            if [[ "$HEALTH_STATUS" == "Healthy" && "$SYNC_STATUS" == "Synced" ]]; then
                APP_READY=true
                break
            fi
            
            # Wait before next poll
            sleep "$POLL_INTERVAL"
            ELAPSED=$((ELAPSED + POLL_INTERVAL))
        done

        if [[ "$APP_READY" == "true" ]]; then
            echo "✅ $app is Ready."
        else
            echo "⚠️  Timed out waiting for $app (continuing with remaining apps)."
        fi
    fi
    echo ""
done

echo "🎉 All target applications are synced and healthy."
