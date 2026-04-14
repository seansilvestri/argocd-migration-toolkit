#!/usr/bin/env bash
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ generate-runbook.sh requires python3; install it or ensure it is in PATH." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEMPLATE_PATH="${SCRIPT_DIR}/templates/runbook.md.tmpl"
DEFAULT_RUNBOOK_DIR="${SCRIPT_DIR}/runbooks"

usage() {
    cat <<'EOF'
Usage: ./tools/migrations/generate-runbook.sh <env-name|path> [--output <file>] [--app-file <app-of-apps yaml>]

Examples:
  ./tools/migrations/generate-runbook.sh migration-test
  ./tools/migrations/generate-runbook.sh migration-test --output tools/migrations/runbooks/migration-test.md
  ./tools/migrations/generate-runbook.sh migration-test --app-file app-of-apps/clusters/source-cluster/apps-migration-test.yaml
EOF
    exit 1
}

ENV_SPEC=""
OUTPUT_PATH=""
declare -a APP_FILE_PATHS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            [[ $# -ge 2 ]] || usage
            OUTPUT_PATH="$2"
            shift 2
            ;;
        --app-file)
            [[ $# -ge 2 ]] || usage
            APP_FILE_PATHS+=("$2")
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [[ -z "$ENV_SPEC" ]]; then
                ENV_SPEC="$1"
                shift
            else
                echo "Unknown argument: $1"
                usage
            fi
            ;;
    esac
done

if [[ -z "$ENV_SPEC" ]]; then
    usage
fi

if [[ -z "$TEMPLATE_PATH" ]]; then
    echo "❌ Template not found at $TEMPLATE_PATH"
    exit 1
fi

# shellcheck source=tools/migrations/migration-env.sh
source "${SCRIPT_DIR}/migration-env.sh" "$ENV_SPEC"

if [[ -n "${MIG_MANIFEST_ROOT:-}" ]]; then
    MANIFEST_ROOT="${MIG_MANIFEST_ROOT}"
else
    MANIFEST_ROOT="${REPO_ROOT}"
fi

derive_env_name() {
    local raw="$1"
    local base
    base="$(basename "$raw")"
    base="${base%.env}"
    echo "$base"
}

derive_env_output_path() {
    local spec="$1"
    local fallback="$2"
    local cleaned="$spec"
    cleaned="${cleaned%.env}"
    cleaned="${cleaned%/}"
    cleaned="${cleaned#./}"
    cleaned="${cleaned#tools/migrations/envs/}"
    cleaned="${cleaned#./tools/migrations/envs/}"
    if [[ "$cleaned" == */tools/migrations/envs/* ]]; then
        cleaned="${cleaned#*/tools/migrations/envs/}"
    fi
    cleaned="${cleaned#envs/}"
    cleaned="${cleaned#./envs/}"
    cleaned="${cleaned#/}"
    if [[ -z "$cleaned" ]]; then
        cleaned="$fallback"
    fi
    echo "$cleaned"
}

ENV_NAME="$(derive_env_name "$ENV_SPEC")"

TARGET_CLUSTER="${MIG_TARGET_CLUSTER}"
SOURCE_CLUSTER="${MIG_SOURCE_CLUSTER}"
TARGET_ARGO_APP="${MIG_TARGET_ARGO_APP}"
# Extract workload cluster from app name (strip everything after the first dot)
# Can be overridden by MIG_WORKLOAD_CLUSTER for appsets
WORKLOAD_CLUSTER="${MIG_WORKLOAD_CLUSTER:-${TARGET_ARGO_APP%%.*}}"

# Source path defaults to app-of-apps but can be overridden (e.g., for appsets)
SOURCE_PATH="${MIG_SOURCE_PATH:-app-of-apps/clusters/${SOURCE_CLUSTER}}"

TARGET_CLUSTER_DIR="${MANIFEST_ROOT}/app-of-apps/clusters/${TARGET_CLUSTER}"
SOURCE_CLUSTER_DIR="${MANIFEST_ROOT}/app-of-apps/clusters/${SOURCE_CLUSTER}"

read_runbook_app_files() {
    if [[ -z "${MIG_RUNBOOK_APP_FILES:-}" ]]; then
        return
    fi
    local IFS=$' \t\n'
    local entries=(${MIG_RUNBOOK_APP_FILES})
    for entry in "${entries[@]}"; do
        APP_FILE_PATHS+=("$(resolve_runbook_entry "$entry")")
    done
}

resolve_runbook_entry() {
    local entry="$1"
    if [[ "$entry" == /* ]]; then
        echo "$entry"
        return
    fi

    if [[ "$entry" == *"/"* ]]; then
        echo "${MANIFEST_ROOT}/${entry}"
        return
    fi

    local candidate="${SOURCE_CLUSTER_DIR}/${entry}"
    if [[ -f "$candidate" ]]; then
        echo "$candidate"
        return
    fi

    candidate="${TARGET_CLUSTER_DIR}/${entry}"
    if [[ -f "$candidate" ]]; then
        echo "$candidate"
        return
    fi

    echo "${MANIFEST_ROOT}/${entry}"
}

ensure_app_files() {
    # Validate explicitly provided app files first
    for path in "${APP_FILE_PATHS[@]}"; do
        if [[ ! -f "$path" ]]; then
            echo "❌ App file not found: $path"
            echo "   Pass one or more valid --app-file <path> arguments (relative or absolute)."
            exit 1
        fi
        # Check if file is readable
        if [[ ! -r "$path" ]]; then
            echo "❌ App file not readable: $path"
            exit 1
        fi
    done

    if (( ${#APP_FILE_PATHS[@]} > 0 )); then
        return
    fi

    read_runbook_app_files
    if (( ${#APP_FILE_PATHS[@]} > 0 )); then
        return
    fi

    local defaults=("apps-${WORKLOAD_CLUSTER}.yaml" "infra-apps-${WORKLOAD_CLUSTER}.yaml")
    for file in "${defaults[@]}"; do
        local candidate="${SOURCE_CLUSTER_DIR}/${file}"
        if [[ -f "$candidate" ]]; then
            APP_FILE_PATHS+=("$candidate")
        fi
    done

    if (( ${#APP_FILE_PATHS[@]} == 0 )) && [[ -d "$TARGET_CLUSTER_DIR" ]]; then
        local guess
        guess="$(grep -rl --include '*.yaml' "name: ${TARGET_ARGO_APP}" "$TARGET_CLUSTER_DIR" 2>/dev/null | head -n 1 || true)"
        if [[ -n "$guess" ]]; then
            APP_FILE_PATHS+=("$guess")
        fi
    fi

    if (( ${#APP_FILE_PATHS[@]} == 0 )); then
        echo "❌ Unable to auto-detect App-of-Apps manifests for ${TARGET_CLUSTER}."
        echo "   Pass one or more --app-file <path> arguments (relative or absolute)."
        exit 1
    fi
}

ensure_app_files

declare -a APP_FILE_NAMES=()
declare -a APP_FILE_TARGET_PATHS=()
for path in "${APP_FILE_PATHS[@]}"; do

    real="$(python3 - "$path" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"
    APP_FILE_NAMES+=("$(basename "$path")")
    APP_FILE_TARGET_PATHS+=("${TARGET_CLUSTER_DIR}/$(basename "$path")")
done

if [[ -z "$OUTPUT_PATH" ]]; then
    ENV_OUTPUT_SUBPATH="$(derive_env_output_path "$ENV_SPEC" "$ENV_NAME")"
    OUTPUT_PATH="${DEFAULT_RUNBOOK_DIR}/${ENV_OUTPUT_SUBPATH}.md"
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

format_login_hint() {
    local url="$1"
    local args="${2:-}"
    if [[ -n "$args" ]]; then
        echo "argocd login $url $args"
    else
        echo "argocd login $url"
    fi
}

TARGET_LOGIN_HINT="$(format_login_hint "$MIG_TARGET_ARGO_URL" "${MIG_TARGET_ARGO_LOGIN_ARGS:-}")"
SOURCE_LOGIN_HINT="$(format_login_hint "$MIG_SOURCE_ARGO_URL" "${MIG_SOURCE_ARGO_LOGIN_ARGS:-}")"

build_safe_delete_list() {
    local raw="${1:-}"
    if [[ -z "$raw" ]]; then
        echo "  - (None defined; pass --parent-app to disarm/cleanup scripts.)"
        return
    fi
    local IFS=$' \t\n'
    local parents=($raw)
    for parent in "${parents[@]}"; do
        printf '  - %s\n' "$parent"
    done
}

SAFE_DELETE_PARENT_LIST="$(build_safe_delete_list "${MIG_SAFE_DELETE_PARENT_APPS:-}")"

find_rel_paths() {
    local arr=()
    if [[ $# -gt 0 ]]; then
        for file in "$@"; do
            if [[ -n "$file" && -f "$file" ]]; then
                arr+=("${file#${MANIFEST_ROOT}/}")
            fi
        done
    fi
    if [[ ${#arr[@]} -eq 0 ]]; then
        echo "  - (None detected)"
    else
        for rel in "${arr[@]}"; do
            printf '  - %s\n' "$rel"
        done
    fi
}

detect_source_pair_files() {
    local pattern="$1"
    local matches=()
    if [[ -d "$SOURCE_CLUSTER_DIR" ]]; then
        while IFS= read -r -d '' file; do
            matches+=("$file")
        done < <(find "$SOURCE_CLUSTER_DIR" -maxdepth 1 -type f -name "$pattern" -name "*${WORKLOAD_CLUSTER}*.yaml" -print0 2>/dev/null)
    fi
    echo "${matches[@]}"
}

SOURCE_APPS_FILE="$(detect_source_pair_files 'apps-*.yaml')"
SOURCE_INFRA_FILE="$(detect_source_pair_files 'infra-apps-*.yaml')"

TARGET_APPS_FILES=()
if (( ${#APP_FILE_TARGET_PATHS[@]} )); then
    TARGET_APPS_FILES=("${APP_FILE_TARGET_PATHS[@]}")
fi

build_target_specs_by_kind() {
    local kind="$1"
    local items=()
    for idx in "${!APP_FILE_NAMES[@]}"; do
        local name="${APP_FILE_NAMES[$idx]}"
        local rel="app-of-apps/clusters/${TARGET_CLUSTER}/${name}"
        if [[ "$kind" == "apps" && "$name" != infra-apps-* ]]; then
            items+=("$rel")
        elif [[ "$kind" == "infra" && "$name" == infra-apps-* ]]; then
            items+=("$rel")
        fi
    done
    if (( ${#items[@]} == 0 )); then
        echo "  - (None detected)"
    else
        for rel in "${items[@]}"; do
            printf '  - %s\n' "$rel"
        done
    fi
}

build_expected_target_specs() {
    build_target_specs_by_kind "apps"
}

build_expected_target_infra_specs() {
    build_target_specs_by_kind "infra"
}

build_appofapps_block() {
    cat <<EOF
- Source control plane (${SOURCE_CLUSTER}) specs targeting ${TARGET_CLUSTER}:
$(find_rel_paths $SOURCE_APPS_FILE)
- Source infra control plane specs:
$(find_rel_paths $SOURCE_INFRA_FILE)
- Target control plane (${TARGET_CLUSTER}) specs prepared via Commit A:
$(build_expected_target_specs)
- Target infra specs:
$(build_expected_target_infra_specs)
EOF
}

APPOFAPPS_BLOCK="$(build_appofapps_block)"
HIDE_PAIRS_SECTION="false"
if [[ -n "${MIG_RUNBOOK_APP_FILES:-}" ]]; then
    HIDE_PAIRS_SECTION="true"
fi

if [[ "$HIDE_PAIRS_SECTION" == "true" ]]; then
    APPOFAPPS_SECTION=""
else
    APPOFAPPS_SECTION=$(
        cat <<EOF
### App-of-Apps Pairing

${APPOFAPPS_BLOCK}

---

EOF
    )
fi

GENERATED_ON="$(date -u +"%Y-%m-%d %H:%M:%SZ")"

build_app_file_summary() {
    if (( ${#APP_FILE_NAMES[@]} == 1 )); then
        echo "${APP_FILE_NAMES[0]}"
    else
        local IFS=", "
        printf '%s' "${APP_FILE_NAMES[*]}"
    fi
}

build_app_file_flags_inline() {
    if (( ${#APP_FILE_NAMES[@]} == 1 )); then
        :
    fi
    local block=""
    for name in "${APP_FILE_NAMES[@]}"; do
        block+=$' \\\n'
        block+="    --app-file ${name}"
    done
    echo "$block"
}

APP_FILE_SUMMARY="$(build_app_file_summary)"
APP_FILE_FLAGS_INLINE="$(build_app_file_flags_inline)"

build_parent_flags_inline() {
    local raw="${MIG_SAFE_DELETE_PARENT_APPS:-}"
    if [[ -z "$raw" ]]; then
        echo ""
        return
    fi
    local IFS=$' \t\n'
    local parents=($raw)
    local block=""
    for parent in "${parents[@]}"; do
        block+=$' \\\n'
        block+="    --parent-app ${parent}"
    done
    echo "$block"
}

build_parent_delete_commands() {
    local raw="${MIG_SAFE_DELETE_PARENT_APPS:-}"
    if [[ -z "$raw" ]]; then
        echo "argocd app delete ${TARGET_ARGO_APP} --cascade=false --server ${MIG_SOURCE_ARGO_URL}"
        return
    fi
    local IFS=$' \t\n'
    local parents=($raw)
    for parent in "${parents[@]}"; do
        printf 'argocd app delete %s --cascade=false --server %s\n' "$parent" "$MIG_SOURCE_ARGO_URL"
    done
}

# Build parent flags and discovery flags
# Note: --path-based-discovery and --parent-app are mutually exclusive
SAFE_DELETE_INCLUDE_FLAG=""
if [[ "${MIG_PATH_BASED_DISCOVERY:-false}" == "true" ]]; then
    SAFE_DELETE_INCLUDE_FLAG=$' \\\n    --path-based-discovery'
    SAFE_DELETE_PARENT_FLAGS=""  # Don't use parent flags with path-based discovery
elif [[ "${MIG_SAFE_DELETE_INCLUDE_UNTRACKED:-false}" == "true" ]]; then
    SAFE_DELETE_INCLUDE_FLAG=$' \\\n    --include-untracked'
    SAFE_DELETE_PARENT_FLAGS="$(build_parent_flags_inline)"
else
    SAFE_DELETE_PARENT_FLAGS="$(build_parent_flags_inline)"
fi

PARENT_DELETE_COMMANDS="$(build_parent_delete_commands)"

export RUNBOOK_TEMPLATE_PATH="$TEMPLATE_PATH"
export RUNBOOK_OUTPUT_PATH="$OUTPUT_PATH"
export RB_APP_FILE_SUMMARY="$APP_FILE_SUMMARY"
export RB_ENV_NAME="$ENV_NAME"
export RB_ENV_SPEC="$ENV_SPEC"
export RB_SOURCE_CLUSTER="$SOURCE_CLUSTER"
export RB_SOURCE_PATH="$SOURCE_PATH"
export RB_SOURCE_ARGO_URL="$MIG_SOURCE_ARGO_URL"
export RB_TARGET_CLUSTER="$TARGET_CLUSTER"
export RB_TARGET_ARGO_URL="$MIG_TARGET_ARGO_URL"
export RB_TARGET_ARGO_APP="$TARGET_ARGO_APP"
export RB_TARGET_LOGIN_HINT="$TARGET_LOGIN_HINT"
export RB_SOURCE_LOGIN_HINT="$SOURCE_LOGIN_HINT"
export RB_SAFE_DELETE_PARENT_LIST="$SAFE_DELETE_PARENT_LIST"
export RB_APPOFAPPS_BLOCK="$APPOFAPPS_BLOCK"
export RB_APPOFAPPS_SECTION="$APPOFAPPS_SECTION"
export RB_GENERATED_ON="$GENERATED_ON"
export RB_APP_FILE_FLAGS_INLINE="$APP_FILE_FLAGS_INLINE"
export RB_SAFE_DELETE_PARENT_FLAGS="$SAFE_DELETE_PARENT_FLAGS"
export RB_PARENT_DELETE_COMMANDS="$PARENT_DELETE_COMMANDS"
export RB_SAFE_DELETE_INCLUDE_FLAG="$SAFE_DELETE_INCLUDE_FLAG"
export RB_WORKLOAD_CLUSTER="$WORKLOAD_CLUSTER"

python3 <<'PY'
import os
import re

template_path = os.environ["RUNBOOK_TEMPLATE_PATH"]
output_path = os.environ["RUNBOOK_OUTPUT_PATH"]

with open(template_path, "r", encoding="utf-8") as f:
    template = f.read()

data = {k[3:]: v for k, v in os.environ.items() if k.startswith("RB_")}

pattern = re.compile(r"\{\{([A-Z0-9_]+)\}\}")

def replace(match):
    key = match.group(1)
    return data.get(key, match.group(0))

rendered = pattern.sub(replace, template)

with open(output_path, "w", encoding="utf-8") as f:
    f.write(rendered)
PY

echo "✅ Runbook generated at ${OUTPUT_PATH#${REPO_ROOT}/}"
