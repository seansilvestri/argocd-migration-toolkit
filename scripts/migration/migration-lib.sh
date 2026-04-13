#!/usr/bin/env bash
# migration-lib.sh - Shared library for ArgoCD migration scripts
#
# This library provides common functions for:
# - Cluster state caching (bulk fetch for performance)
# - Application/ApplicationSet discovery
# - Helper functions for patching and deletion
#
# Usage: source this file from disarm-source.sh or cleanup-source.sh
#
# Requires: Bash 4+, kubectl, yq v4+

# Prevent multiple sourcing
[[ -n "${_MIGRATION_LIB_LOADED:-}" ]] && return 0
_MIGRATION_LIB_LOADED=1

# Exit on error, undefined vars, pipe failures
set -euo pipefail
IFS=$'\n\t'

#######################################
# Version Checks
#######################################

check_bash_version() {
    if ((BASH_VERSINFO[0] < 4)); then
        echo "Error: Bash v4+ is required (found ${BASH_VERSION})" >&2
        exit 1
    fi
}

check_yq_version() {
    local yq_bin="${YQ_BIN:-yq}"
    if ! command -v "$yq_bin" >/dev/null 2>&1; then
        echo "Error: $yq_bin not found in PATH" >&2
        exit 1
    fi

    local raw version major
    raw=$("$yq_bin" --version 2>/dev/null)
    
    if [[ "$raw" =~ version[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        version="${BASH_REMATCH[1]}"
    elif [[ "$raw" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        version="${BASH_REMATCH[1]}"
    else
        echo "Error: Unable to determine yq version (got '$raw'); yq v4+ is required" >&2
        exit 1
    fi
    
    if [[ "$version" =~ ^([0-9]+)\. ]]; then
        major="${BASH_REMATCH[1]}"
    else
        echo "Error: Unable to parse yq version (got '$version'); yq v4+ is required" >&2
        exit 1
    fi
    
    if (( major < 4 )); then
        echo "Error: yq v4+ is required (found $version)" >&2
        exit 1
    fi
}

check_kubectl() {
    local kubectl_bin="${KUBECTL_BIN:-kubectl}"
    if ! command -v "$kubectl_bin" >/dev/null 2>&1; then
        echo "Error: $kubectl_bin not found in PATH" >&2
        exit 1
    fi
}

#######################################
# Context and Login Helpers
#######################################

auto_set_source_context() {
    local kubectl_bin="${KUBECTL_BIN:-kubectl}"
    
    [[ -z "${MIG_SOURCE_KUBECONTEXT:-}" ]] && return
    [[ "${MIG_DISABLE_AUTO_CONTEXT:-false}" == "true" ]] && return
    
    if ! command -v "$kubectl_bin" >/dev/null 2>&1; then
        echo "⚠️  $kubectl_bin not found; skipping automatic context switch."
        return
    fi

    echo "→ Switching kubectl context to ${MIG_SOURCE_KUBECONTEXT}..."
    "$kubectl_bin" config use-context "${MIG_SOURCE_KUBECONTEXT}"
    echo ""
}

auto_login_target_argo() {
    local argocd_bin="${ARGOCD_BIN:-argocd}"
    local target_url="${1:-${TARGET_ARGO_URL:-}}"
    
    [[ -z "${MIG_TARGET_ARGO_LOGIN_ARGS:-}" ]] && return
    [[ "${MIG_DISABLE_AUTO_ARGO_LOGIN:-false}" == "true" ]] && return
    [[ -z "$target_url" ]] && return
    
    if [[ -n "${MIG_TARGET_ARGO_URL:-}" && "$target_url" != "$MIG_TARGET_ARGO_URL" ]]; then
        echo "ℹ️  MIG_TARGET_ARGO_URL differs from provided URL; skipping auto-login."
        return
    fi

    echo "→ Refreshing Target Argo session..."
    local login_args=()
    local _old_ifs="$IFS"
    IFS=$' \t\n'
    read -r -a login_args <<< "${MIG_TARGET_ARGO_LOGIN_ARGS}"
    IFS="$_old_ifs"
    
    if ! "$argocd_bin" login "$target_url" "${login_args[@]}"; then
        echo "⚠️  Failed to establish Argo session. Please log in manually." >&2
        exit 1
    fi
    echo ""
}

#######################################
# Path Resolution
#######################################

resolve_manifest_root() {
    if [[ -n "${MIG_MANIFEST_ROOT:-}" ]]; then
        echo "$MIG_MANIFEST_ROOT"
    elif git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
        echo "$git_root"
    else
        echo "$(pwd)"
    fi
}

resolve_source_path() {
    local input="$1"
    local manifest_root="$2"
    
    [[ -z "$input" ]] && { echo ""; return; }
    
    if [[ "$input" == /* ]]; then
        echo "$input"
    else
        echo "${manifest_root%/}/$input"
    fi
}

#######################################
# Kubectl Helpers
#######################################

kubectl_ns() {
    local kubectl_bin="${KUBECTL_BIN:-kubectl}"
    local namespace="${NAMESPACE:-argocd}"
    "$kubectl_bin" -n "$namespace" "$@"
}

#######################################
# Cluster State Caching
#######################################

# Global cache arrays - declared here, populated by fetch_cluster_state
declare -gA APP_EXISTS=()
declare -gA APP_FINALIZERS=()
declare -gA APP_SYNC_STATUS=()
declare -gA APPSET_EXISTS=()
declare -gA APPSET_FINALIZERS=()
declare -gA APPSET_TEMPLATE_SYNC_STATUS=()
declare -gA APP_PARENTS=()

# Raw cluster data
declare -ga CLUSTER_APPS=()
declare -ga CLUSTER_APPSETS=()

fetch_cluster_state() {
    echo "Fetching cluster state (Applications)..."
    mapfile -t CLUSTER_APPS < <(kubectl_ns get applications \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"|"}{.metadata.labels.argocd\.argoproj\.io/application-set-name}{"|"}{range .metadata.ownerReferences[?(@.kind=="ApplicationSet")]}{.name}{","}{end}{"|"}{.metadata.finalizers[*]}{"|"}{.spec.syncPolicy.automated}{"\n"}{end}' \
        2>/dev/null || true)

    echo "Fetching cluster state (ApplicationSets)..."
    mapfile -t CLUSTER_APPSETS < <(kubectl_ns get applicationsets \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"|"}{.metadata.finalizers[*]}{"|"}{.spec.template.spec.syncPolicy.automated}{"\n"}{end}' \
        2>/dev/null || true)
    
    echo "  Found ${#CLUSTER_APPS[@]} Applications, ${#CLUSTER_APPSETS[@]} ApplicationSets in cluster"
}

populate_app_cache() {
    local source_cluster="$1"
    shift
    local -a parent_apps=("$@")
    
    # Track which parents we found children for
    declare -A parent_app_found=()
    for parent in "${parent_apps[@]}"; do
        parent_app_found["$parent"]=0
    done
    
    # Process Applications
    for record in "${CLUSTER_APPS[@]}"; do
        [[ -z "${record:-}" ]] && continue
        
        IFS='|' read -r name tracking appset owners finals sync_status <<<"$record"
        [[ -z "$name" ]] && continue
        
        # Populate cache
        APP_EXISTS["$name"]=1
        APP_FINALIZERS["$name"]="$finals"
        APP_SYNC_STATUS["$name"]="$sync_status"
    done
    
    # Process ApplicationSets
    for record in "${CLUSTER_APPSETS[@]}"; do
        [[ -z "${record:-}" ]] && continue
        
        IFS='|' read -r name tracking finals sync_status <<<"$record"
        [[ -z "$name" ]] && continue
        
        APPSET_EXISTS["$name"]=1
        APPSET_FINALIZERS["$name"]="$finals"
        APPSET_TEMPLATE_SYNC_STATUS["$name"]="$sync_status"
    done
}

#######################################
# Discovery Functions
#######################################

# Discover Applications and ApplicationSets from Git manifests
discover_from_git() {
    local source_path="$1"
    local yq_bin="${YQ_BIN:-yq}"
    
    local -a apps_git=()
    local -a appsets_git=()
    
    while IFS= read -r entry; do
        [[ -z "${entry:-}" ]] && continue
        local kind="${entry%%|*}"
        local name="${entry#*|}"
        [[ -z "$name" ]] && continue

        case "$kind" in
            ApplicationSet) appsets_git+=("$name") ;;
            Application) apps_git+=("$name") ;;
        esac
    done < <(find "$source_path" -type f \( -name "*.yaml" -o -name "*.yml" \) ! -name "kustomization.yaml" -print0 | \
             xargs -0 "$yq_bin" eval-all 'select(.kind == "Application" or .kind == "ApplicationSet") | .kind + "|" + (.metadata.name // "")' 2>/dev/null || true)
    
    # Return via global arrays (bash limitation)
    DISCOVERED_APPS_GIT=("${apps_git[@]}")
    DISCOVERED_APPSETS_GIT=("${appsets_git[@]}")
}

# Discover Applications and ApplicationSets from Git manifests WITHOUT cluster-prefix filtering
# Used for AppSets with non-standard naming (e.g., otel-logging-pipeline-kcp)
discover_from_git_unfiltered() {
    local source_path="$1"
    local yq_bin="${YQ_BIN:-yq}"

    local -a apps_git=()
    local -a appsets_git=()

    while IFS= read -r entry; do
        [[ -z "${entry:-}" ]] && continue
        local kind="${entry%%|*}"
        local name="${entry#*|}"
        [[ -z "$name" ]] && continue

        case "$kind" in
            ApplicationSet) appsets_git+=("$name") ;;
            Application) apps_git+=("$name") ;;
        esac
    done < <(find "$source_path" -type f \( -name "*.yaml" -o -name "*.yml" \) ! -name "kustomization.yaml" -print0 | \
             xargs -0 "$yq_bin" eval-all 'select(.kind == "Application" or .kind == "ApplicationSet") | .kind + "|" + (.metadata.name // "")' 2>/dev/null || true)

    # Return via global arrays (bash limitation)
    DISCOVERED_APPS_GIT=("${apps_git[@]}")
    DISCOVERED_APPSETS_GIT=("${appsets_git[@]}")
}

# Discover Applications by parent tracking-id
# Args: source_cluster [parent_apps...] 
# Globals: INCLUDE_UNTRACKED (optional, set by caller)
discover_apps_by_parent() {
    local source_cluster="$1"
    shift
    local -a parent_apps=("$@")
    local include_untracked="${INCLUDE_UNTRACKED:-false}"
    
    local -a discovered_apps=()
    local -a discovered_appsets=()
    
    declare -A parent_app_found=()
    for parent in "${parent_apps[@]}"; do
        parent_app_found["$parent"]=0
    done
    
    for record in "${CLUSTER_APPS[@]}"; do
        [[ -z "${record:-}" ]] && continue
        
        IFS='|' read -r name tracking appset owners finals sync_status <<<"$record"
        [[ -z "$name" ]] && continue
        
        local owner_appset=""
        owners="${owners%,}"
        owner_appset="${owners%%,*}"
        
        # Check tracking-id matches a parent
        if [[ -n "$tracking" ]] && ((${#parent_apps[@]})); then
            local tracking_parent="${tracking%%:*}"
            for parent in "${parent_apps[@]}"; do
                if [[ "$tracking_parent" == "$parent" ]]; then
                    parent_app_found["$parent"]=1
                    record_parent_relation "$name" "$parent"
                    discovered_apps+=("$name")
                    break
                fi
            done
        fi
        
        # Check appset label or owner reference
        local target_appset=""
        if [[ -n "$appset" && "$name" == "$source_cluster."* ]]; then
            target_appset="$appset"
        elif [[ -z "$appset" && -n "$owner_appset" && "$name" == "$source_cluster."* ]]; then
            target_appset="$owner_appset"
        fi
        
        if [[ -n "$target_appset" ]]; then
            for parent in "${parent_apps[@]}"; do
                if [[ "$parent" == "$target_appset" ]]; then
                    parent_app_found["$parent"]=1
                    record_parent_relation "$name" "$target_appset"
                    discovered_apps+=("$name")
                    discovered_appsets+=("$target_appset")
                    break
                fi
            done
        fi
    done
    
    # Discover ApplicationSets by tracking-id
    for record in "${CLUSTER_APPSETS[@]}"; do
        [[ -z "${record:-}" ]] && continue
        
        IFS='|' read -r name tracking finals sync_status <<<"$record"
        [[ -z "$name" ]] && continue
        [[ "$name" != "$source_cluster."* ]] && continue
        
        local tracking_parent="${tracking%%:*}"
        for parent in "${parent_apps[@]}"; do
            if [[ "$name" == "$parent" || "$tracking_parent" == "$parent" ]]; then
                discovered_appsets+=("$name")
                break
            fi
        done
    done
    
    # Include untracked apps (apps without tracking-id that match cluster prefix)
    if [[ "$include_untracked" == "true" ]]; then
        for record in "${CLUSTER_APPS[@]}"; do
            [[ -z "${record:-}" ]] && continue
            
            IFS='|' read -r name tracking appset owners finals sync_status <<<"$record"
            [[ -z "$name" ]] && continue
            
            # Skip if already discovered or has tracking info
            [[ -n "$tracking" || -n "$appset" || -n "$owners" ]] && continue
            
            # Must match cluster prefix
            [[ "$name" != "$source_cluster."* ]] && continue
            
            # Skip known test apps unless we're migrating them
            if [[ "$name" == *".migration-test"* || "$name" == *".appset-child-"* ]]; then
                local is_migration_test=false
                for parent in "${parent_apps[@]}"; do
                    [[ "$parent" == *".migration-test" ]] && is_migration_test=true && break
                done
                [[ "$is_migration_test" != "true" ]] && continue
            fi
            
            record_parent_relation "$name" "UNTRACKED"
            discovered_apps+=("$name")
        done
    fi
    
    # Warn about parents with no children
    for parent in "${parent_apps[@]}"; do
        if [[ ${parent_app_found["$parent"]:-0} -eq 0 ]]; then
            echo "  ⚠️  No child Applications found for parent $parent"
        fi
    done
    
    # Return via global arrays
    DISCOVERED_APPS=("${discovered_apps[@]}")
    DISCOVERED_APPSETS=("${discovered_appsets[@]}")
}

# Find child Applications of an ApplicationSet
child_apps_for_appset() {
    local target_appset="$1"
    local -a matches=()
    
    for record in "${CLUSTER_APPS[@]}"; do
        [[ -z "$record" ]] && continue
        
        IFS='|' read -r name tracking label owners finals sync_status <<<"$record"
        
        # Check standard ArgoCD label
        if [[ "$label" == "$target_appset" ]]; then
            matches+=("$name")
            continue
        fi
        
        # Check OwnerReferences
        if [[ -n "$owners" ]]; then
            IFS=',' read -ra owner_list <<< "$owners"
            for owner in "${owner_list[@]}"; do
                if [[ "$owner" == "$target_appset" ]]; then
                    matches+=("$name")
                    break
                fi
            done
        fi
    done
    
    echo "${matches[*]}"
}

#######################################
# Parent Tracking
#######################################

record_parent_relation() {
    local child="$1"
    local parent="$2"
    
    if [[ -z "${APP_PARENTS[$child]:-}" ]]; then
        APP_PARENTS["$child"]="$parent"
    elif [[ "${APP_PARENTS[$child]}" != *"$parent"* ]]; then
        APP_PARENTS["$child"]="${APP_PARENTS[$child]}, $parent"
    fi
}

parent_for_app() {
    local child="$1"
    echo "${APP_PARENTS[$child]:-}"
}

#######################################
# Resource Helpers (use cache)
#######################################

resource_exists() {
    local type="$1"
    local name="$2"
    
    if [[ "$type" == "application" ]]; then
        [[ "${APP_EXISTS[$name]:-0}" == "1" ]] && return 0
    elif [[ "$type" == "applicationset" ]]; then
        [[ "${APPSET_EXISTS[$name]:-0}" == "1" ]] && return 0
    fi
    return 1
}

get_finalizers() {
    local type="$1"
    local name="$2"
    
    if [[ "$type" == "application" ]]; then
        echo "${APP_FINALIZERS[$name]:-}"
    elif [[ "$type" == "applicationset" ]]; then
        echo "${APPSET_FINALIZERS[$name]:-}"
    fi
}

get_sync_status() {
    local name="$1"
    echo "${APP_SYNC_STATUS[$name]:-}"
}

get_appset_template_sync_status() {
    local name="$1"
    echo "${APPSET_TEMPLATE_SYNC_STATUS[$name]:-}"
}

has_finalizer() {
    local type="$1"
    local name="$2"
    local finals
    finals=$(get_finalizers "$type" "$name")
    [[ -n "$finals" ]]
}

#######################################
# Patch Helpers
#######################################

remove_finalizers() {
    local type="$1"
    local name="$2"
    local label="$3"

    local finals
    finals=$(get_finalizers "$type" "$name")
    if [[ -z "$finals" ]]; then
        echo "  (no finalizers to remove)"
        return 0
    fi

    echo "→ Removing $label finalizers..."
    if ! kubectl_ns patch "$type" "$name" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null; then
        echo "  (failed or already removed)"
        return 1
    fi
    return 0
}

disable_sync_policy() {
    local name="$1"
    local current_status="${APP_SYNC_STATUS[$name]:-}"
    
    if [[ -z "$current_status" || "$current_status" == "false" ]]; then
        echo "  (syncPolicy already disabled)"
        return 0
    fi

    if ! kubectl_ns patch application "$name" --type=json \
        -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]' 2>/dev/null; then
        echo "  (syncPolicy already disabled or patch failed)"
        return 1
    fi
    return 0
}

freeze_applicationset() {
    local appset="$1"
    
    # Try JSON patch first (for new syncPolicy)
    if kubectl_ns patch applicationset "$appset" --type=json \
        -p='[{"op":"add","path":"/spec/syncPolicy","value":{"applicationsSync":"create-only"}}]' 2>/dev/null; then
        return 0
    fi
    
    # Fallback to merge patch (if syncPolicy already exists)
    if kubectl_ns patch applicationset "$appset" --type=merge \
        -p='{"spec":{"syncPolicy":{"applicationsSync":"create-only"}}}' 2>/dev/null; then
        return 0
    fi
    
    echo "  ⚠️  Could not freeze ApplicationSet $appset"
    return 1
}

disarm_applicationset_template() {
    local appset="$1"
    local current_status="${APPSET_TEMPLATE_SYNC_STATUS[$appset]:-}"
    
    if [[ "$current_status" != "true" ]]; then
        echo "  (template syncPolicy already disabled)"
        return 0
    fi
    
    if ! kubectl_ns patch applicationset "$appset" --type=json \
        -p='[{"op":"remove","path":"/spec/template/spec/syncPolicy/automated"}]' 2>/dev/null; then
        echo "  (template syncPolicy already disabled or patch failed)"
        return 1
    fi
    return 0
}

delete_resource() {
    local type="$1"
    local name="$2"
    local label="$3"
    shift 3
    local extra_args=("$@")

    echo "→ Deleting $label..."
    if kubectl_ns delete "$type" "$name" "${extra_args[@]}" 2>/dev/null; then
        echo "✅ $name deleted"
        return 0
    else
        echo "  ⚠️  Failed to delete $name"
        return 1
    fi
}

#######################################
# Display Helpers
#######################################

display_status_table() {
    local -a apps=("${!1}")
    local -a appsets=("${!2}")
    
    echo ""
    echo "========================================="
    echo "RESOURCE STATUS"
    echo "========================================="
    printf "%-50s %-12s %-15s %-30s\n" "NAME" "TYPE" "SYNC_POLICY" "FINALIZERS"
    echo "-----------------------------------------------------------------------------------------------------------"
    
    for app in "${apps[@]}"; do
        if resource_exists application "$app"; then
            local sync_status
            if [[ -n "${APP_SYNC_STATUS[$app]:-}" && "${APP_SYNC_STATUS[$app]}" != "false" ]]; then
                sync_status="automated"
            else
                sync_status="manual"
            fi
            local finals="${APP_FINALIZERS[$app]:-none}"
            [[ -z "$finals" ]] && finals="none"
        else
            sync_status="NOT_IN_CLUSTER"
            finals="-"
        fi
        printf "%-50s %-12s %-15s %-30s\n" "$app" "App" "$sync_status" "$finals"
    done
    
    for appset in "${appsets[@]}"; do
        if resource_exists applicationset "$appset"; then
            local sync_status
            if [[ "${APPSET_TEMPLATE_SYNC_STATUS[$appset]:-}" == "true" ]]; then
                sync_status="automated"
            else
                sync_status="manual"
            fi
            local finals="${APPSET_FINALIZERS[$appset]:-none}"
            [[ -z "$finals" ]] && finals="none"
        else
            sync_status="NOT_IN_CLUSTER"
            finals="-"
        fi
        printf "%-50s %-12s %-15s %-30s\n" "$appset" "AppSet" "$sync_status" "$finals"
    done
    echo ""
}

#######################################
# Target Validation
#######################################

ensure_target_app_ready() {
    local target_url="$1"
    local target_app="$2"
    local argocd_bin="${ARGOCD_BIN:-argocd}"
    local yq_bin="${YQ_BIN:-yq}"
    
    if [[ -z "$target_url" || -z "$target_app" ]]; then
        echo "❌ ERROR: Target Argo URL and app are required for cleanup."
        return 1
    fi

    if ! command -v "$argocd_bin" >/dev/null 2>&1; then
        echo "Error: $argocd_bin not found in PATH" >&2
        return 1
    fi

    echo "→ Validating target '$target_app' on $target_url..."
    local target_json
    if ! target_json=$("$argocd_bin" app get "$target_app" --server "$target_url" -o json 2>/dev/null); then
        echo "❌ ERROR: Unable to query target app '$target_app' at $target_url."
        echo "   Ensure you are logged in and the app exists."
        return 1
    fi

    local target_health target_sync
    target_health=$(echo "$target_json" | "$yq_bin" eval '.status.health.status // ""' - | tr -d '"')
    target_sync=$(echo "$target_json" | "$yq_bin" eval '.status.sync.status // ""' - | tr -d '"')

    if [[ "$target_health" != "Healthy" || "$target_sync" != "Synced" ]]; then
        echo "❌ ERROR: Target app is not ready (Health=$target_health, Sync=$target_sync)."
        echo "   Run sync-target-apps.sh first."
        return 1
    fi

    echo "✅ Target is Healthy/Synced."
    return 0
}

#######################################
# Initialization
#######################################

init_migration_lib() {
    check_bash_version
    check_yq_version
    check_kubectl
}

# Auto-initialize when sourced
init_migration_lib
