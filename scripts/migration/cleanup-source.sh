#!/usr/bin/env bash
#
# cleanup-source.sh - Pass 2: Delete disarmed source ArgoCD resources
#
# This script deletes Applications and ApplicationSets that were previously
# disarmed by disarm-source.sh. It validates that the target is healthy before
# proceeding.
#
# Prerequisites:
#   - disarm-source.sh has been run (resources are frozen and finalizers removed)
#   - Target ArgoCD has synced and is Healthy/Synced
#
# Usage:
#   ./cleanup-source.sh [--dry-run] --source PATH --cluster NAME [--parent-app APP ...] --target-argo-url URL --target-argo-app APP
#
# Examples:
#   ./cleanup-source.sh --dry-run --source app-of-apps/clusters/source-cluster --cluster target-cluster --parent-app target-cluster.apps
#   ./cleanup-source.sh --source app-of-apps/clusters/source-cluster --cluster target-cluster --parent-app target-cluster.apps --target-argo-url argocd.example.com --target-argo-app target-cluster.apps

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared library
# shellcheck source=migration-lib.sh
source "${SCRIPT_DIR}/migration-lib.sh"

#######################################
# Script-specific variables
#######################################

DRY_RUN=false
SOURCE_PATH=""
SOURCE_PATH_ORIGINAL=""
CLUSTER_NAME=""
PARENT_APPS=()
TARGET_ARGO_URL=""
TARGET_ARGO_APP=""
INCLUDE_UNTRACKED=false
PATH_BASED_DISCOVERY=false
SKIP_TARGET_CHECK=false

#######################################
# Usage
#######################################

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Delete disarmed source ArgoCD resources (Pass 2).
Requires target to be Healthy/Synced before proceeding.

OPTIONS:
  --dry-run              Show what would be done without making changes
  --source PATH          Path to App-of-Apps manifests (required)
  --cluster NAME         Cluster name prefix for discovery (required)
  --parent-app APP       Parent App-of-Apps name (can be repeated)
  --target-argo-url URL  Target ArgoCD server URL (required unless --skip-target-check)
  --target-argo-app APP  Target app to validate (required unless --skip-target-check)
  --skip-target-check    Skip target health validation (dangerous!)
  --include-untracked    Include Applications without tracking metadata
  --path-based-discovery Discover all resources from Git path without cluster-prefix filtering
                         (for ApplicationSets with non-standard naming, mutually exclusive with --parent-app)
  -h, --help             Show this help message

EXAMPLES:
  $0 --dry-run --source app-of-apps/clusters/source-cluster --cluster target-cluster --parent-app target-cluster.apps --target-argo-url argocd.example.com --target-argo-app target-cluster.apps
EOF
    exit 1
}

#######################################
# Parse Arguments
#######################################

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --source)
            SOURCE_PATH_ORIGINAL="$2"
            SOURCE_PATH="$2"
            shift 2
            ;;
        --cluster)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --parent-app)
            PARENT_APPS+=("$2")
            shift 2
            ;;
        --target-argo-url)
            TARGET_ARGO_URL="$2"
            shift 2
            ;;
        --target-argo-app)
            TARGET_ARGO_APP="$2"
            shift 2
            ;;
        --skip-target-check)
            SKIP_TARGET_CHECK=true
            shift
            ;;
        --include-untracked)
            INCLUDE_UNTRACKED=true
            shift
            ;;
        --path-based-discovery)
            PATH_BASED_DISCOVERY=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

# Load from migration env if not provided
if [[ -z "$SOURCE_PATH" && -n "${MIG_SOURCE_CLUSTER:-}" ]]; then
    SOURCE_PATH="app-of-apps/clusters/${MIG_SOURCE_CLUSTER}"
fi

if [[ ${#PARENT_APPS[@]} -eq 0 && -n "${MIG_SAFE_DELETE_PARENT_APPS:-}" ]]; then
    # shellcheck disable=SC2206
    PARENT_APPS=( ${MIG_SAFE_DELETE_PARENT_APPS} )
fi

if [[ -z "$TARGET_ARGO_URL" && -n "${MIG_TARGET_ARGO_URL:-}" ]]; then
    TARGET_ARGO_URL="$MIG_TARGET_ARGO_URL"
fi

if [[ -z "$TARGET_ARGO_APP" && -n "${MIG_TARGET_ARGO_APP:-}" ]]; then
    TARGET_ARGO_APP="$MIG_TARGET_ARGO_APP"
fi

# Default cluster name from target app (workload cluster is in the app name prefix)
if [[ -z "$CLUSTER_NAME" && -n "${MIG_TARGET_ARGO_APP:-}" ]]; then
    CLUSTER_NAME="${MIG_TARGET_ARGO_APP%%.*}"
fi

# Infer target app from single parent
if [[ -z "$TARGET_ARGO_APP" && ${#PARENT_APPS[@]} -eq 1 ]]; then
    TARGET_ARGO_APP="${PARENT_APPS[0]}"
fi

# Validate required arguments
if [[ -z "$SOURCE_PATH" ]]; then
    echo "Error: --source PATH is required" >&2
    usage
fi

if [[ -z "$CLUSTER_NAME" ]]; then
    echo "Error: --cluster NAME is required" >&2
    usage
fi

if [[ "$SKIP_TARGET_CHECK" != "true" ]]; then
    if [[ -z "$TARGET_ARGO_URL" ]]; then
        echo "Error: --target-argo-url is required (or use --skip-target-check)" >&2
        usage
    fi
    if [[ -z "$TARGET_ARGO_APP" ]]; then
        echo "Error: --target-argo-app is required (or use --skip-target-check)" >&2
        usage
    fi
fi

# Validate mutually exclusive flags
if [[ "$PATH_BASED_DISCOVERY" == "true" && ${#PARENT_APPS[@]} -gt 0 ]]; then
    echo "Error: --path-based-discovery and --parent-app are mutually exclusive" >&2
    echo "  --path-based-discovery: Discovers all resources from Git path (for AppSets)" >&2
    echo "  --parent-app: Discovers resources by parent tracking-id" >&2
    exit 1
fi

#######################################
# Resolve Paths
#######################################

MANIFEST_ROOT="$(resolve_manifest_root)"
SOURCE_PATH="$(resolve_source_path "$SOURCE_PATH" "$MANIFEST_ROOT")"

if [[ ! -d "$SOURCE_PATH" ]]; then
    echo "Error: Source path does not exist: ${SOURCE_PATH_ORIGINAL:-$SOURCE_PATH}" >&2
    exit 1
fi

SOURCE_CLUSTER="$CLUSTER_NAME"

#######################################
# Main
#######################################

echo "========================================"
echo "CLEANUP SOURCE - Pass 2"
echo "========================================"
echo "Source Path: $SOURCE_PATH"
echo "Cluster: $SOURCE_CLUSTER"
echo "Parent Apps: ${PARENT_APPS[*]:-none}"
echo "Target URL: ${TARGET_ARGO_URL:-N/A}"
echo "Target App: ${TARGET_ARGO_APP:-N/A}"
echo "Dry Run: $DRY_RUN"
echo ""

# Switch context
auto_set_source_context

# Validate target is healthy before proceeding (requires login)
if [[ "$SKIP_TARGET_CHECK" != "true" ]]; then
    # Auto-login to target Argo if needed
    if [[ -n "$TARGET_ARGO_URL" ]]; then
        auto_login_target_argo "$TARGET_ARGO_URL"
    fi
    echo "Validating target health..."
    if ! ensure_target_app_ready "$TARGET_ARGO_URL" "$TARGET_ARGO_APP"; then
        echo ""
        echo "❌ Target is not ready. Run sync-target-apps.sh first."
        exit 1
    fi
    echo ""
fi

# Fetch cluster state
fetch_cluster_state
populate_app_cache "$SOURCE_CLUSTER" "${PARENT_APPS[@]}"

# Discover resources
APPS=()
APPSETS=()

# Discovery strategy:
# - If --path-based-discovery: discover all resources from Git without cluster-prefix filtering
# - If --parent-app: use parent-based discovery (includes untracked if INCLUDE_UNTRACKED=true)
# - Otherwise: use Git-based discovery with cluster-prefix filtering
if [[ "$PATH_BASED_DISCOVERY" == "true" ]]; then
    # Path-based discovery: discover all resources from Git without cluster-prefix filtering
    # (for AppSets with non-standard naming like otel-logging-pipeline-kcp)
    discover_from_git_unfiltered "$SOURCE_PATH"
    APPS+=("${DISCOVERED_APPS_GIT[@]}")
    APPSETS+=("${DISCOVERED_APPSETS_GIT[@]}")
elif ((${#PARENT_APPS[@]})); then
    # Parent-based discovery: find apps by tracking-id (and untracked if INCLUDE_UNTRACKED=true)
    discover_apps_by_parent "$SOURCE_CLUSTER" "${PARENT_APPS[@]}"
    APPS+=("${DISCOVERED_APPS[@]}")
    APPSETS+=("${DISCOVERED_APPSETS[@]}")
else
    # Git-based discovery with cluster-prefix filtering
    discover_from_git "$SOURCE_PATH"
    APPS+=("${DISCOVERED_APPS_GIT[@]}")
    APPSETS+=("${DISCOVERED_APPSETS_GIT[@]}")
fi

# Deduplicate
if ((${#APPS[@]})); then
    mapfile -t APPS < <(printf '%s\n' "${APPS[@]}" | sort -u)
fi
if ((${#APPSETS[@]})); then
    mapfile -t APPSETS < <(printf '%s\n' "${APPSETS[@]}" | sort -u)
fi

TOTAL=$((${#APPS[@]} + ${#APPSETS[@]}))

if [[ $TOTAL -eq 0 ]]; then
    echo "No Applications or ApplicationSets found to delete."
    exit 0
fi

echo "Found ${#APPS[@]} Application(s) and ${#APPSETS[@]} ApplicationSet(s)"

# Display current status
display_status_table APPS[@] APPSETS[@]

# Check for resources that still have finalizers (warning)
echo "Checking for resources that may not be properly disarmed..."
WARNINGS=0
for app in "${APPS[@]}"; do
    if resource_exists application "$app"; then
        finals=$(get_finalizers application "$app")
        if [[ -n "$finals" ]]; then
            echo "  ⚠️  $app still has finalizers: $finals"
            ((WARNINGS++)) || true
        fi
    fi
done
for appset in "${APPSETS[@]}"; do
    if resource_exists applicationset "$appset"; then
        finals=$(get_finalizers applicationset "$appset")
        if [[ -n "$finals" ]]; then
            echo "  ⚠️  $appset still has finalizers: $finals"
            ((WARNINGS++)) || true
        fi
    fi
done

if ((WARNINGS > 0)); then
    echo ""
    echo "⚠️  $WARNINGS resource(s) still have finalizers."
    echo "   Consider running disarm-source.sh first to remove them."
    echo ""
fi

#######################################
# Dry Run
#######################################

if [[ "$DRY_RUN" == "true" ]]; then
    echo "========================================"
    echo "DRY RUN - No changes will be made"
    echo "========================================"
    echo ""
    
    # Build set of all AppSet children to identify in dry-run
    declare -A DRY_RUN_APPSET_CHILDREN
    for appset in "${APPSETS[@]}"; do
        if resource_exists applicationset "$appset"; then
            for child in $(child_apps_for_appset "$appset"); do
                DRY_RUN_APPSET_CHILDREN["$child"]=1
            done
        fi
    done
    
    echo "Would delete the following standalone Applications:"
    for app in "${APPS[@]}"; do
        if resource_exists application "$app"; then
            # Skip parent apps - they'll be pruned by root-app-of-apps
            is_parent=false
            for parent in "${PARENT_APPS[@]}"; do
                [[ "$app" == "$parent" ]] && is_parent=true && break
            done
            if [[ "$is_parent" == "true" ]]; then
                echo "  [$app] (parent - will be pruned by root-app-of-apps after Commit B)"
            elif [[ -n "${DRY_RUN_APPSET_CHILDREN[$app]:-}" ]]; then
                echo "  [$app] (AppSet child - will delete after AppSet removal)"
            else
                # Fresh finalizer check for dry-run display
                live_finals=$(kubectl_ns get application "$app" -o jsonpath='{.metadata.finalizers[*]}' 2>/dev/null || true)
                if [[ -n "$live_finals" ]]; then
                    echo "  [$app] has finalizers: $live_finals"
                    echo "    → kubectl patch application -n argocd $app --type=json -p='[{\"op\":\"remove\",\"path\":\"/metadata/finalizers\"}]'"
                    echo "    → kubectl delete application -n argocd $app"
                else
                    echo "  [$app] kubectl delete application -n argocd $app"
                fi
            fi
        else
            echo "  [$app] SKIP - not in cluster"
        fi
    done
    echo ""
    
    echo "Would delete the following ApplicationSets FIRST (to prevent child recreation):"
    for appset in "${APPSETS[@]}"; do
        if resource_exists applicationset "$appset"; then
            echo "  [$appset] kubectl delete applicationset -n argocd $appset --cascade=orphan"
        else
            echo "  [$appset] SKIP - not in cluster"
        fi
    done
    echo ""
    
    echo "Would then delete the following orphaned ApplicationSet child apps:"
    for appset in "${APPSETS[@]}"; do
        if resource_exists applicationset "$appset"; then
            child_apps=$(child_apps_for_appset "$appset")
            if [[ -n "$child_apps" ]]; then
                for child in $child_apps; do
                    if resource_exists application "$child"; then
                        # Fresh finalizer check for dry-run display
                        live_finals=$(kubectl_ns get application "$child" -o jsonpath='{.metadata.finalizers[*]}' 2>/dev/null || true)
                        if [[ -n "$live_finals" ]]; then
                            echo "  [$child] (orphan of $appset) has finalizers: $live_finals"
                            echo "    → kubectl patch application -n argocd $child --type=json -p='[{\"op\":\"remove\",\"path\":\"/metadata/finalizers\"}]'"
                            echo "    → kubectl delete application -n argocd $child"
                        else
                            echo "  [$child] (orphan of $appset) kubectl delete application -n argocd $child"
                        fi
                    else
                        echo "  [$child] SKIP - not in cluster"
                    fi
                done
            fi
        fi
    done
    echo ""
    
    echo "========================================"
    echo "Run without --dry-run to execute"
    echo "========================================"
    exit 0
fi

#######################################
# Confirmation
#######################################

echo ""
read -p "Delete $TOTAL resources from source cluster? (y/N) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

#######################################
# Delete Applications
#######################################

echo "========================================"
echo "Deleting Standalone Applications"
echo "========================================"
echo ""
echo "NOTE: Skipping ApplicationSet children here - they will be deleted"
echo "      after their parent ApplicationSets are removed."
echo ""

DELETED_APPS=0
SKIPPED_PARENTS=0
SKIPPED_CHILDREN=0

# Build set of all AppSet children to skip in this loop
declare -A ALL_APPSET_CHILDREN
for appset in "${APPSETS[@]}"; do
    if resource_exists applicationset "$appset"; then
        for child in $(child_apps_for_appset "$appset"); do
            ALL_APPSET_CHILDREN["$child"]=1
        done
    fi
done

for app in "${APPS[@]}"; do
    if ! resource_exists application "$app"; then
        echo "⚠️  $app not in cluster (skipping)"
        continue
    fi
    
    # Skip parent apps - they'll be pruned by root-app-of-apps after Commit B
    is_parent=false
    for parent in "${PARENT_APPS[@]}"; do
        if [[ "$app" == "$parent" ]]; then
            is_parent=true
            break
        fi
    done
    
    if [[ "$is_parent" == "true" ]]; then
        echo "→ Skipping parent $app (will be pruned after Commit B)"
        ((SKIPPED_PARENTS++)) || true
        continue
    fi
    
    # Skip AppSet children - they'll be deleted after AppSets are removed
    if [[ -n "${ALL_APPSET_CHILDREN[$app]:-}" ]]; then
        echo "→ Skipping AppSet child $app (will delete after AppSet removal)"
        ((SKIPPED_CHILDREN++)) || true
        continue
    fi
    
    # Fresh syncPolicy check (not from cache) - handles race where ArgoCD re-enables syncPolicy
    sync_policy=$(kubectl_ns get application "$app" -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null || true)
    if [[ -n "$sync_policy" ]]; then
        echo "  ⚠️  $app has syncPolicy.automated (disabling before delete)"
        kubectl_ns patch application "$app" --type=json -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]' 2>/dev/null || true
        # Verify removal
        remaining=$(kubectl_ns get application "$app" -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null || true)
        if [[ -n "$remaining" ]]; then
            echo "  ❌ Failed to disable syncPolicy on $app - skipping to avoid resource pruning"
            continue
        fi
    fi
    
    # Fresh finalizer check (not from cache) - handles race where ArgoCD re-adds finalizers
    live_finals=$(kubectl_ns get application "$app" -o jsonpath='{.metadata.finalizers[*]}' 2>/dev/null || true)
    if [[ -n "$live_finals" ]]; then
        echo "  ⚠️  $app has finalizers (removing before delete): $live_finals"
        kubectl_ns patch application "$app" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
        # Verify removal
        remaining=$(kubectl_ns get application "$app" -o jsonpath='{.metadata.finalizers[*]}' 2>/dev/null || true)
        if [[ -n "$remaining" ]]; then
            echo "  ❌ Failed to remove finalizers from $app - skipping to avoid cascade delete"
            continue
        fi
    fi
    
    echo "→ Deleting: $app"
    if delete_resource application "$app" "Application"; then
        ((DELETED_APPS++)) || true
    fi
done

echo ""
echo "Deleted $DELETED_APPS standalone Application(s), skipped $SKIPPED_PARENTS parent(s), $SKIPPED_CHILDREN AppSet children"
echo ""

#######################################
# Delete ApplicationSets FIRST
# (prevents controller from recreating children)
#######################################

echo "========================================"
echo "Deleting ApplicationSets"
echo "========================================"
echo ""
echo "NOTE: Deleting ApplicationSets first to prevent the controller from"
echo "      recreating child apps (create-only still allows creation)."
echo ""

DELETED_APPSETS=0

# Collect child apps BEFORE deleting ApplicationSets (uses cached cluster state)
declare -A APPSET_CHILDREN
for appset in "${APPSETS[@]}"; do
    if resource_exists applicationset "$appset"; then
        APPSET_CHILDREN["$appset"]=$(child_apps_for_appset "$appset")
    fi
done

# Now delete the ApplicationSets
for appset in "${APPSETS[@]}"; do
    if ! resource_exists applicationset "$appset"; then
        echo "⚠️  $appset not in cluster (skipping)"
        continue
    fi
    
    echo "→ Deleting: $appset"
    # Use --cascade=orphan to leave children intact (we'll delete them next)
    if delete_resource applicationset "$appset" "ApplicationSet" "--cascade=orphan"; then
        ((DELETED_APPSETS++)) || true
    fi
done

echo ""
echo "Deleted $DELETED_APPSETS ApplicationSet(s)"
echo ""

#######################################
# Delete ApplicationSet Child Apps
# (now orphaned, safe to delete)
#######################################

echo "========================================"
echo "Deleting Orphaned ApplicationSet Child Apps"
echo "========================================"
echo ""

DELETED_CHILDREN=0

for appset in "${APPSETS[@]}"; do
    child_apps="${APPSET_CHILDREN[$appset]:-}"
    if [[ -z "$child_apps" ]]; then
        continue
    fi
    
    echo "→ Orphaned children of $appset:"
    for child in $child_apps; do
        if ! resource_exists application "$child"; then
            echo "  ⚠️  $child not in cluster (skipping)"
            continue
        fi
        
        # Fresh syncPolicy check (not from cache) - handles race where ArgoCD re-enables syncPolicy
        sync_policy=$(kubectl_ns get application "$child" -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null || true)
        if [[ -n "$sync_policy" ]]; then
            echo "    ⚠️  $child has syncPolicy.automated (disabling before delete)"
            kubectl_ns patch application "$child" --type=json -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]' 2>/dev/null || true
            # Verify removal
            remaining=$(kubectl_ns get application "$child" -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null || true)
            if [[ -n "$remaining" ]]; then
                echo "    ❌ Failed to disable syncPolicy on $child - skipping to avoid resource pruning"
                continue
            fi
        fi
        
        # Fresh finalizer check (not from cache) - handles race where ArgoCD re-adds finalizers
        live_finals=$(kubectl_ns get application "$child" -o jsonpath='{.metadata.finalizers[*]}' 2>/dev/null || true)
        if [[ -n "$live_finals" ]]; then
            echo "  ⚠️  $child has finalizers (removing before delete): $live_finals"
            kubectl_ns patch application "$child" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
            # Verify removal
            remaining=$(kubectl_ns get application "$child" -o jsonpath='{.metadata.finalizers[*]}' 2>/dev/null || true)
            if [[ -n "$remaining" ]]; then
                echo "  ❌ Failed to remove finalizers from $child - skipping to avoid cascade delete"
                continue
            fi
        fi
        
        echo "  → Deleting: $child"
        if delete_resource application "$child" "child Application"; then
            ((DELETED_CHILDREN++)) || true
        fi
    done
done

echo ""
echo "Deleted $DELETED_CHILDREN orphaned ApplicationSet child Application(s)"
echo ""

#######################################
# Summary
#######################################

echo "========================================"
echo "✅ CLEANUP COMPLETE"
echo "========================================"
echo ""
echo "Deleted: $DELETED_APPS standalone Applications, $DELETED_APPSETS ApplicationSets, $DELETED_CHILDREN orphaned children"
if ((SKIPPED_PARENTS > 0)); then
    echo "Skipped: $SKIPPED_PARENTS parent App-of-Apps (will be pruned after Commit B)"
fi
echo ""
echo "Next steps:"
echo "  1. Run prep-commit-b-cleanup.sh to remove source manifests from Git"
echo "  2. Commit and push"
echo "  3. Refresh source root-app-of-apps to prune parent apps"
echo ""
