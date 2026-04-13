#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Toggle auto-sync blocks for App-of-Apps Applications.
#
# Usage:
#   ./tools/migrations/toggle-autosync.sh --mode disable \
#       --app-of-app app-of-apps/clusters/target-cluster/apps.yaml
#   ./tools/migrations/toggle-autosync.sh --mode enable \
#       --app-of-app app-of-apps/clusters/target-cluster/apps.yaml
#   # Preview only (no files modified):
#   ./tools/migrations/toggle-autosync.sh --dry-run --mode disable ...
#
# When disabling, the script removes `.spec.syncPolicy.automated` for the
# App-of-App(s) ONLY. It does NOT touch child Applications or ApplicationSets
# in the source path. This ensures that when the App-of-App is manually synced
# on the target, its children are created with auto-sync ENABLED, allowing
# them to immediately adopt orphaned workloads (Zero Downtime).

MODE=""
DRY_RUN=false
YQ_BIN="${YQ_BIN:-yq}"
declare -a APP_OF_APP_PATHS=()
declare -A VISITED_FILES=()
if [[ -n "${MIG_MANIFEST_ROOT:-}" ]]; then
    MANIFEST_ROOT="$MIG_MANIFEST_ROOT"
else
    if MANIFEST_ROOT_GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
        MANIFEST_ROOT="$MANIFEST_ROOT_GIT_ROOT"
    else
        MANIFEST_ROOT="$(pwd)"
    fi
fi
declare -a ORIGINAL_PATHS=()
declare -a RESOLVED_APP_OF_APP_PATHS=()

die() { echo "ERROR: $*" >&2; exit 1; }

require_tools() {
    command -v "$YQ_BIN" >/dev/null 2>&1 || die "$YQ_BIN not found in PATH"
    require_yq_version
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --mode)
                MODE="$2"
                shift 2
                ;;
            --app-of-app)
                APP_OF_APP_PATHS+=("$2")
                shift 2
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done

    [[ -z "$MODE" ]] && die "--mode disable|enable is required"
    [[ "$MODE" != "disable" && "$MODE" != "enable" ]] && die "Invalid mode: $MODE"
    ((${#APP_OF_APP_PATHS[@]})) || die "At least one --app-of-app path is required"
}

require_yq_version() {
    local raw version major
    raw=$("$YQ_BIN" --version 2>/dev/null)
    
    # Extract version number from various yq output formats
    # v4.28.1: "yq (https://github.com/mikefarah/yq/) version 4.28.1"
    # v4.35+: "yq version 4.35.2"
    # v4.40+: "yq (https://github.com/mikefarah/yq/) version v4.40.5"
    if [[ "$raw" =~ version[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        version="${BASH_REMATCH[1]}"
    elif [[ "$raw" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        version="${BASH_REMATCH[1]}"
    else
        die "Unable to determine yq version (got '$raw'); yq v4+ is required"
    fi
    
    if [[ "$version" =~ ^([0-9]+)\. ]]; then
        major="${BASH_REMATCH[1]}"
    else
        die "Unable to parse yq version number (got '$version'); yq v4+ is required"
    fi
    
    if (( major < 4 )); then
        die "toggle-autosync.sh requires yq v4+ (found $version)"
    fi
}

ensure_single_document() {
    local file="$1"
    local count
    count=$("$YQ_BIN" eval 'documentIndex' "$file" 2>/dev/null | wc -l | tr -d ' ')
    if [[ -z "$count" ]]; then
        count=0
    fi
    if (( count > 1 )); then
        die "File $file contains $count YAML documents; multi-document files are not supported"
    fi
}

detect_kind() {
    local file="$1"
    local kind
    if kind=$("$YQ_BIN" eval '.kind' "$file" 2>/dev/null); then
        [[ "$kind" != "null" ]] && { echo "$kind"; return; }
    fi
    if grep -Eq '^[[:space:]]*kind:[[:space:]]*Application' "$file"; then
        echo "Application"
        return
    fi
    echo ""
}

toggle_block() {
    local file="$1"
    local kind

    if [[ -n "${VISITED_FILES[$file]:-}" ]]; then
        return
    fi
    ensure_single_document "$file"

    kind=$(detect_kind "$file")

    if [[ -z "$kind" ]]; then
        die "Unable to detect kind for file: $file"
    fi

    if [[ "$kind" != "Application" ]]; then
        die "File $file is not of kind 'Application' (found '$kind'). This script only supports toggling App-of-Apps."
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo "→ [dry-run] would update $file ($kind)"
        VISITED_FILES["$file"]=1
        return
    fi

    echo "→ Updating $file ($kind)"
    case "$MODE" in
        disable)
            "$YQ_BIN" -i 'del(.spec.syncPolicy.automated)' "$file"
            ;;
        enable)
            "$YQ_BIN" -i '
                .spec.syncPolicy.automated.prune = true |
                .spec.syncPolicy.automated.selfHeal = true
            ' "$file"
            ;;
    esac

    VISITED_FILES["$file"]=1
}

main() {
    parse_args "$@"
    require_tools

    resolve_app_paths() {
        RESOLVED_APP_OF_APP_PATHS=()
        ORIGINAL_PATHS=()
        for path in "${APP_OF_APP_PATHS[@]}"; do
            ORIGINAL_PATHS+=("$path")
            if [[ "$path" == /* ]]; then
                RESOLVED_APP_OF_APP_PATHS+=("$path")
            else
                RESOLVED_APP_OF_APP_PATHS+=("${MANIFEST_ROOT%/}/$path")
            fi
        done
    }

    resolve_app_paths

    for idx in "${!RESOLVED_APP_OF_APP_PATHS[@]}"; do
        app_file="${RESOLVED_APP_OF_APP_PATHS[$idx]}"
        display_name="${ORIGINAL_PATHS[$idx]}"
        [[ -f "$app_file" ]] || die "App-of-App file not found: ${display_name} (resolved: $app_file)"

        toggle_block "$app_file"
    done

    echo "✅ Auto-sync $MODE completed for ${#VISITED_FILES[@]} file(s)."
}

main "$@"
