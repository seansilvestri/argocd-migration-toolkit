#!/usr/bin/env bash
set -euo pipefail

# Bash 4.0+ required for consistency with other migration tools
if ((BASH_VERSINFO[0] < 4)); then
    echo "❌ ERROR: Bash 4.0 or higher is required."
    exit 1
fi

# Ensure argocd CLI is available
if ! command -v argocd &> /dev/null; then
    echo "❌ ERROR: 'argocd' CLI is not found in PATH."
    exit 1
fi

# Automates "Hard Refresh" on the Source ArgoCD via `argocd app get --hard-refresh`.
#
# Use Cases:
# 1. Commit B0: Force Argo to recognize finalizers are removed from Git.
# 2. Commit B: Force Argo to recognize manifests are deleted from Git.
# Optional flags:
#   --dry-run : Skip the refresh and only show intent
#
# Usage:
#   ./refresh-source-apps.sh --source-argo-url <url> --app <name> [--app <name> ...] [--dry-run]

SOURCE_URL=""
APPS=()
DRY_RUN=false
REQUIRED_ARGO_MAJOR=3
REQUIRED_ARGO_MINOR=2

auto_set_source_context() {
    if [[ -z "${MIG_SOURCE_KUBECONTEXT:-}" ]]; then
        return
    fi
    if [[ "${MIG_DISABLE_AUTO_CONTEXT:-false}" == "true" ]]; then
        return
    fi
    if ! command -v kubectl >/dev/null 2>&1; then
        echo "⚠️  kubectl not found; skipping automatic context switch."
        return
    fi

    echo "→ Switching kubectl context to ${MIG_SOURCE_KUBECONTEXT} (from migration env)..."
    kubectl config use-context "${MIG_SOURCE_KUBECONTEXT}"
    echo ""
}

auto_login_source_argo() {
    if [[ -z "${MIG_SOURCE_ARGO_LOGIN_ARGS:-}" ]]; then
        return
    fi
    if [[ "${MIG_DISABLE_AUTO_ARGO_LOGIN:-false}" == "true" ]]; then
        return
    fi
    if [[ -n "${MIG_SOURCE_ARGO_URL:-}" && "$SOURCE_URL" != "$MIG_SOURCE_ARGO_URL" ]]; then
        echo "ℹ️  MIG_SOURCE_ARGO_URL (${MIG_SOURCE_ARGO_URL}) differs from --source-argo-url ($SOURCE_URL); skipping auto-login."
        return
    fi

    echo "→ Refreshing Source Argo session via MIG_SOURCE_ARGO_LOGIN_ARGS..."
    # shellcheck disable=SC2086
    if ! argocd login "$SOURCE_URL" ${MIG_SOURCE_ARGO_LOGIN_ARGS}; then
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
    echo "Usage: $0 --source-argo-url <url> --app <name> [--app <name> ...] [--dry-run]"
    echo "       (Defaults to MIG_SOURCE_ARGO_URL and MIG_SAFE_DELETE_PARENT_APPS when migration-env.sh is sourced.)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --source-argo-url)
            SOURCE_URL="$2"
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
        *)
            echo "Unknown argument: $1"
            usage
            ;;
    esac
done

if [[ -z "$SOURCE_URL" && -n "${MIG_SOURCE_ARGO_URL:-}" ]]; then
    SOURCE_URL="$MIG_SOURCE_ARGO_URL"
fi

if [[ ${#APPS[@]} -eq 0 && -n "${MIG_SAFE_DELETE_PARENT_APPS:-}" ]]; then
    # shellcheck disable=SC2206
    APPS=( ${MIG_SAFE_DELETE_PARENT_APPS} )
fi

if [[ -z "$SOURCE_URL" ]]; then
    echo "ERROR: --source-argo-url is required."
    usage
fi

if [[ ${#APPS[@]} -eq 0 ]]; then
    echo "ERROR: At least one --app is required."
    usage
fi

auto_set_source_context

ensure_argocd_cli_ready

auto_login_source_argo

echo "🚀 Starting Source Refresh Automation"
if [[ "$DRY_RUN" == "true" ]]; then
    echo "   MODE:   DRY-RUN (No changes will be applied)"
fi
echo "   Source: $SOURCE_URL"
echo "   Apps:   ${APPS[*]}"
echo ""

# 1. Verify Login
echo "→ Verifying authentication..."
if ! argocd account get-user-info --server "$SOURCE_URL" >/dev/null 2>&1; then
    echo "❌ ERROR: Unable to authenticate with $SOURCE_URL."
    echo "   Please log in first (e.g., argocd login $SOURCE_URL --sso)"
    exit 1
fi
echo "✅ Authenticated."
echo ""

# 2. Confirmation (Skip in Dry Run)
if [[ "$DRY_RUN" == "false" ]]; then
    echo "⚠️  WARNING: You are about to HARD REFRESH the following apps on $SOURCE_URL:"
    printf "   - %s\n" "${APPS[@]}"
    read -r -p "Are you sure? [y/N] " response
    if [[ ! "$response" =~ ^[yY]$ ]]; then
        echo "Aborted."
        exit 1
    fi
else
    echo "ℹ️  Dry Run enabled - skipping confirmation."
fi
echo ""

# 3. Process Apps
for app in "${APPS[@]}"; do
    echo "========================================="
    echo "Processing: $app"
    echo "========================================="

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "1. [DRY-RUN] Skipping Hard Refresh."
    else
        echo "1. Refreshing (Hard)..."
        if ! argocd app get "$app" --hard-refresh --server "$SOURCE_URL" >/dev/null; then
            echo "❌ Failed to hard refresh $app."
            exit 1
        fi
        echo "✅ Refreshed."
    fi
    echo ""
done

echo "🎉 Source applications refreshed."
