#!/usr/bin/env bash
#
# disarm-source.sh - Pass 1: Freeze and disarm source ArgoCD resources
#
# This script prepares source Applications and ApplicationSets for migration by:
#   Phase 1: Disabling auto-sync on parent App-of-Apps
#   Phase 2: Freezing ApplicationSets (applicationsSync: create-only)
#   Phase 3: Disarming ApplicationSet templates (remove syncPolicy.automated)
#   Phase 4: Removing finalizers from all Applications and ApplicationSets
#
# NO DELETIONS are performed - resources are only patched to neutralize reconciliation.
# Run cleanup-source.sh after target is healthy to delete the disarmed resources.
#
# Usage:
#   ./disarm-source.sh [--dry-run] --source PATH --cluster NAME [--parent-app APP ...]
#
# Examples:
#   ./disarm-source.sh --dry-run --source app-of-apps/clusters/source-cluster --cluster target-cluster --parent-app target-cluster.apps
#   ./disarm-source.sh --source app-of-apps/clusters/source-cluster --cluster target-cluster --parent-app target-cluster.apps --parent-app target-cluster.infra-apps

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
INCLUDE_UNTRACKED=false
PATH_BASED_DISCOVERY=false

#######################################
# Usage
#######################################

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Disarm source ArgoCD resources for migration (Pass 1).
Freezes ApplicationSets and removes finalizers WITHOUT deleting anything.

OPTIONS:
  --dry-run              Show what would be done without making changes
  --source PATH          Path to App-of-Apps manifests (required)
  --cluster NAME         Cluster name prefix for discovery (required)
  --parent-app APP       Parent App-of-Apps name (can be repeated)
  --include-untracked    Include Applications without tracking metadata
  --path-based-discovery Discover all resources from Git path without cluster-prefix filtering
                         (for ApplicationSets with non-standard naming, mutually exclusive with --parent-app)
  -h, --help             Show this help message

EXAMPLES:
  $0 --dry-run --source app-of-apps/clusters/source-cluster --cluster target-cluster --parent-app target-cluster.apps
  $0 --source app-of-apps/clusters/source-cluster --cluster target-cluster --parent-app target-cluster.apps --parent-app target-cluster.infra-apps
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

# Default cluster name from target app (workload cluster is in the app name prefix)
if [[ -z "$CLUSTER_NAME" && -n "${MIG_TARGET_ARGO_APP:-}" ]]; then
    CLUSTER_NAME="${MIG_TARGET_ARGO_APP%%.*}"
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
echo "DISARM SOURCE - Pass 1"
echo "========================================"
echo "Source Path: $SOURCE_PATH"
echo "Cluster: $SOURCE_CLUSTER"
echo "Parent Apps: ${PARENT_APPS[*]:-none}"
echo "Dry Run: $DRY_RUN"
echo ""

# Switch context
auto_set_source_context

# Fetch cluster state (bulk operation for performance)
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
    echo "No Applications or ApplicationSets found to disarm."
    exit 0
fi

echo "Found ${#APPS[@]} Application(s) and ${#APPSETS[@]} ApplicationSet(s)"

# Display current status
display_status_table APPS[@] APPSETS[@]

#######################################
# Dry Run
#######################################

if [[ "$DRY_RUN" == "true" ]]; then
    echo "========================================"
    echo "DRY RUN - No changes will be made"
    echo "========================================"
    echo ""
    
    # Phase 1: Parent App-of-Apps
    if ((${#PARENT_APPS[@]})); then
        echo "PHASE 1: Disarm Parent App-of-Apps"
        echo "-----------------------------------"
        for parent in "${PARENT_APPS[@]}"; do
            if resource_exists application "$parent"; then
                echo "  [$parent] kubectl patch application -n argocd --type=json -p='[{\"op\":\"remove\",\"path\":\"/spec/syncPolicy/automated\"}]'"
            else
                echo "  [$parent] SKIP - not in cluster"
            fi
        done
        echo ""
    fi
    
    # Phase 2 & 3: ApplicationSets
    if ((${#APPSETS[@]})); then
        echo "PHASE 2: Freeze ApplicationSets"
        echo "-------------------------------"
        for appset in "${APPSETS[@]}"; do
            if resource_exists applicationset "$appset"; then
                echo "  [$appset] kubectl patch applicationset -n argocd --type=merge -p='{\"spec\":{\"syncPolicy\":{\"applicationsSync\":\"create-only\"}}}'"
            else
                echo "  [$appset] SKIP - not in cluster"
            fi
        done
        echo ""
        
        echo "PHASE 3: Disarm ApplicationSet Templates"
        echo "----------------------------------------"
        for appset in "${APPSETS[@]}"; do
            if resource_exists applicationset "$appset"; then
                echo "  [$appset] kubectl patch applicationset -n argocd --type=json -p='[{\"op\":\"remove\",\"path\":\"/spec/template/spec/syncPolicy/automated\"}]'"
            fi
        done
        echo ""
    fi
    
    # Phase 4: Remove finalizers
    echo "PHASE 4: Remove Finalizers"
    echo "--------------------------"
    for app in "${APPS[@]}"; do
        if resource_exists application "$app"; then
            finals=$(get_finalizers application "$app")
            if [[ -n "$finals" ]]; then
                echo "  [$app] kubectl patch application -n argocd --type=json -p='[{\"op\":\"remove\",\"path\":\"/metadata/finalizers\"}]'"
            else
                echo "  [$app] (no finalizers)"
            fi
        else
            echo "  [$app] SKIP - not in cluster"
        fi
    done
    
    for appset in "${APPSETS[@]}"; do
        if resource_exists applicationset "$appset"; then
            finals=$(get_finalizers applicationset "$appset")
            if [[ -n "$finals" ]]; then
                echo "  [$appset] kubectl patch applicationset -n argocd --type=json -p='[{\"op\":\"remove\",\"path\":\"/metadata/finalizers\"}]'"
            else
                echo "  [$appset] (no finalizers)"
            fi
            
            # Child apps
            child_apps=$(child_apps_for_appset "$appset")
            for child in $child_apps; do
                child_finals=$(get_finalizers application "$child")
                if [[ -n "$child_finals" ]]; then
                    echo "  [$child] (child) kubectl patch application -n argocd --type=json -p='[{\"op\":\"remove\",\"path\":\"/metadata/finalizers\"}]'"
                fi
            done
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
read -p "Disarm $TOTAL resources? (y/N) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

#######################################
# Phase 1: Disarm Parent App-of-Apps
#######################################

if ((${#PARENT_APPS[@]})); then
    echo "========================================"
    echo "PHASE 1: Disarming Parent App-of-Apps"
    echo "========================================"
    echo "(Prevents self-heal from undoing changes)"
    echo ""
    
    for parent in "${PARENT_APPS[@]}"; do
        if resource_exists application "$parent"; then
            echo "→ Disabling auto-sync on: $parent"
            disable_sync_policy "$parent"
            echo "✅ $parent disarmed"
        else
            echo "⚠️  $parent not in cluster (skipping)"
        fi
    done
    echo ""
fi

#######################################
# Phase 2: Freeze ApplicationSets
#######################################

if ((${#APPSETS[@]})); then
    echo "========================================"
    echo "PHASE 2: Freezing ApplicationSets"
    echo "========================================"
    echo "(Prevents controller from re-applying template specs)"
    echo ""
    
    for appset in "${APPSETS[@]}"; do
        if ! resource_exists applicationset "$appset"; then
            echo "⚠️  $appset not in cluster (skipping)"
            continue
        fi
        
        echo "→ Freezing: $appset"
        if freeze_applicationset "$appset"; then
            echo "✅ $appset frozen"
        fi
    done
    echo ""
fi

#######################################
# Phase 3: Disarm ApplicationSet Templates
#######################################

if ((${#APPSETS[@]})); then
    echo "========================================"
    echo "PHASE 3: Disarming ApplicationSet Templates"
    echo "========================================"
    echo "(Removes syncPolicy.automated from template)"
    echo ""
    
    for appset in "${APPSETS[@]}"; do
        if ! resource_exists applicationset "$appset"; then
            continue
        fi
        
        echo "→ Disarming template: $appset"
        disarm_applicationset_template "$appset"
    done
    echo ""
fi

#######################################
# Phase 4: Remove Finalizers
#######################################

echo "========================================"
echo "PHASE 4: Removing Finalizers"
echo "========================================"
echo ""

# Applications (including those discovered by parent)
for app in "${APPS[@]}"; do
    if ! resource_exists application "$app"; then
        echo "⚠️  $app not in cluster (skipping)"
        continue
    fi
    
    echo "→ Processing Application: $app"
    disable_sync_policy "$app"
    remove_finalizers application "$app" "Application"
done

# ApplicationSets and their children
for appset in "${APPSETS[@]}"; do
    if ! resource_exists applicationset "$appset"; then
        continue
    fi
    
    echo "→ Processing ApplicationSet: $appset"
    
    # Process child apps
    child_apps=$(child_apps_for_appset "$appset")
    if [[ -n "$child_apps" ]]; then
        echo "  Children: $child_apps"
        for child in $child_apps; do
            echo "  → $child"
            disable_sync_policy "$child"
            remove_finalizers application "$child" "child Application"
        done
    fi
    
    remove_finalizers applicationset "$appset" "ApplicationSet"
done

# Parent App-of-Apps finalizers (last, so they can still manage during disarm)
if ((${#PARENT_APPS[@]})); then
    echo ""
    echo "→ Removing finalizers from parent App-of-Apps"
    for parent in "${PARENT_APPS[@]}"; do
        if resource_exists application "$parent"; then
            remove_finalizers application "$parent" "parent Application"
        fi
    done
fi

echo ""
echo "========================================"
echo "✅ DISARM COMPLETE"
echo "========================================"
echo ""
echo "All resources have been disarmed. Next steps:"
echo "  1. Run sync-target-apps.sh to sync the target"
echo "  2. Verify target is Healthy/Synced"
echo "  3. Run cleanup-source.sh to delete disarmed resources"
echo ""
