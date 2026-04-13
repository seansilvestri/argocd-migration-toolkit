#!/usr/bin/env bash
# shellcheck shell=bash
#
# Usage:
#   source ./tools/migrations/migration-env.sh <env-name|/absolute/path/to.env>
#
# Sourcing this script loads the requested migration environment file under
# tools/migrations/envs/, exports normalized MIG_* variables, and defines
# helper functions for switching kubectl contexts and logging into the
# corresponding ArgoCD instances.
#
# The environment file format is a simple KEY=VALUE list. See
# tools/migrations/envs/migration-test.env for a reference.
#
# Optional env keys worth knowing:
#   - RUNBOOK_APP_FILES="apps-foo.yaml infra-foo.yaml"
#       Limits the generated runbook to the listed manifests. Values can be
#       absolute paths, repo-relative paths, or bare filenames that will be
#       resolved relative to the source/target cluster directories.
#   - SAFE_DELETE_INCLUDE_UNTRACKED=true
#       When set, MIG_SAFE_DELETE_INCLUDE_UNTRACKED propagates to the runbook
#       and safe-delete helper, adding --include-untracked so every legacy
#       Application matching the <cluster>. prefix is removed. ⚠️ This can
#       delete any unmanaged Applications in the same namespace; always run the
#       dry-run mode first and ensure you are pointed at the correct source
#       control plane before enabling it.
#   - MIG_ALLOW_EXTERNAL_ENV=true
#       Allows sourcing env files outside tools/migrations/envs/. ⚠️ Treat this
#       as "execute arbitrary shell from an untrusted path"—only enable it when
#       you fully trust the external file and understand that it can export or
#       override any shell variable/function in your session.
#

if ! command -v python3 >/dev/null 2>&1; then
    echo "migration-env.sh requires python3 for path resolution; install it or ensure it is in PATH."
    return 1 2>/dev/null || exit 1
fi

_mig_detect_self_path() {
    if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
        echo "${BASH_SOURCE[0]}"
    elif [[ -n "${ZSH_VERSION:-}" ]]; then
        echo "${(%):-%x}"
    else
        echo "$0"
    fi
}

_mig_ensure_sourced() {
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        case ":${ZSH_EVAL_CONTEXT:-}:" in
            *:file:*) return 0 ;;
            *) return 1 ;;
        esac
    elif [[ -n "${BASH_VERSION:-}" ]]; then
        (return 0 2>/dev/null)
        return
    else
        # POSIX shells: best effort
        (return 0 2>/dev/null)
        return
    fi
}

_MIG_SELF_PATH="$(_mig_detect_self_path)"

if ! _mig_ensure_sourced; then
    echo "This helper must be sourced so that it can export variables:"
    echo "  source ${_MIG_SELF_PATH} <env-name>"
    exit 1
fi

if [[ $# -lt 1 ]]; then
    echo "Usage: source tools/migrations/migration-env.sh <env-name|/path/to/env>"
    return 1 2>/dev/null || exit 1
fi

_MIG_HELPER_DIR="$(cd "$(dirname "${_MIG_SELF_PATH}")" && pwd)"
_MIG_ENV_ARG="$1"
shift || true

_mig_with_env_ext() {
    local path="$1"
    if [[ "$path" == *.env ]]; then
        echo "$path"
    else
        echo "${path}.env"
    fi
}

_mig_try_env_path() {
    local path="$1"
    path="$(_mig_with_env_ext "$path")"
    if [[ -f "$path" ]]; then
        echo "$path"
    else
        echo ""
    fi
}

_MIG_ENV_FILE=""

if [[ "$_MIG_ENV_ARG" == /* ]]; then
    _MIG_ENV_FILE="$(_mig_with_env_ext "$_MIG_ENV_ARG")"
elif [[ "$_MIG_ENV_ARG" == *"/"* ]]; then
    _MIG_ENV_FILE="$(_mig_try_env_path "${_MIG_HELPER_DIR}/envs/${_MIG_ENV_ARG}")"
    if [[ -z "$_MIG_ENV_FILE" ]]; then
        _MIG_ENV_FILE="$(_mig_try_env_path "$_MIG_ENV_ARG")"
    fi
else
    _MIG_ENV_FILE="$(_mig_try_env_path "${_MIG_HELPER_DIR}/envs/${_MIG_ENV_ARG}")"
fi

if [[ -z "$_MIG_ENV_FILE" ]]; then
    _MIG_ENV_BASENAME="${_MIG_ENV_ARG##*/}"
    _MIG_ENV_BASENAME="${_MIG_ENV_BASENAME%.env}"
    mapfile -t _MIG_ENV_CANDIDATES < <(find "${_MIG_HELPER_DIR}/envs" -type f -name "${_MIG_ENV_BASENAME}.env" 2>/dev/null || true)
    if [[ ${#_MIG_ENV_CANDIDATES[@]} -eq 1 ]]; then
        _MIG_ENV_FILE="${_MIG_ENV_CANDIDATES[0]}"
    elif [[ ${#_MIG_ENV_CANDIDATES[@]} -gt 1 ]]; then
        echo "Multiple env files named ${_MIG_ENV_BASENAME}.env found:"
        printf '  - %s\n' "${_MIG_ENV_CANDIDATES[@]}"
        echo "Please re-run using the subdirectory path (e.g., source tools/migrations/migration-env.sh non-prod/us/${_MIG_ENV_BASENAME})."
        return 1 2>/dev/null || exit 1
    fi
    unset _MIG_ENV_CANDIDATES _MIG_ENV_BASENAME
fi

# Resolve path safely (portable realpath using python3)
_MIG_ENV_FILE_RESOLVED="$(
python3 - "$_MIG_ENV_FILE" <<'PY'
import os, sys
path = sys.argv[1]
print(os.path.realpath(path))
PY
)" || {
    echo "Failed to resolve env file path: $_MIG_ENV_FILE"
    return 1 2>/dev/null || exit 1
}
_MIG_ENV_FILE="$_MIG_ENV_FILE_RESOLVED"
unset _MIG_ENV_FILE_RESOLVED

if [[ ! -f "$_MIG_ENV_FILE" ]]; then
    echo "Migration env file not found: $_MIG_ENV_FILE"
    echo "Create it under tools/migrations/envs/<env>.env"
    return 1 2>/dev/null || exit 1
fi

_MIG_ENV_ROOT="${_MIG_HELPER_DIR}/envs/"
case "$_MIG_ENV_FILE" in
    "$_MIG_ENV_ROOT"*)
        ;;
    *)
        if [[ "${MIG_ALLOW_EXTERNAL_ENV:-false}" != "true" ]]; then
            cat <<EOF
Refusing to source external env file:
  $_MIG_ENV_FILE
Set MIG_ALLOW_EXTERNAL_ENV=true if you trust this file and need to load it.
EOF
            return 1 2>/dev/null || exit 1
        fi
        echo "⚠️  Warning: sourcing external env file $_MIG_ENV_FILE (MIG_ALLOW_EXTERNAL_ENV=true)."
        ;;
esac

# Unset optional MIG_* variables to prevent pollution when sourcing multiple envs in same shell
unset MIG_PATH_BASED_DISCOVERY
unset MIG_SOURCE_PATH
unset MIG_WORKLOAD_CLUSTER
unset MIG_SAFE_DELETE_PARENT_APPS
unset MIG_SAFE_DELETE_INCLUDE_UNTRACKED
unset MIG_RUNBOOK_APP_FILES

# shellcheck disable=SC1090
source "$_MIG_ENV_FILE"

_mig_get_var() {
    local var_name=$1
    if [[ -n "${BASH_VERSION:-}" ]]; then
        printf '%s' "${!var_name-}"
    elif [[ -n "${ZSH_VERSION:-}" ]]; then
        printf '%s' "${(P)var_name-}"
    else
        eval "printf '%s' \"\${$var_name-}\""
    fi
}

_mig_require_var() {
    local var_name=$1
    local value
    value="$(_mig_get_var "$var_name")"
    if [[ -z "$value" ]]; then
        echo "Missing required variable '$var_name' in $_MIG_ENV_FILE"
        return 1
    fi
}

_mig_require_var SOURCE_CLUSTER || return 1
_mig_require_var SOURCE_KUBECONTEXT || return 1
_mig_require_var SOURCE_ARGO_URL || return 1
_mig_require_var TARGET_CLUSTER || return 1
_mig_require_var TARGET_KUBECONTEXT || return 1
_mig_require_var TARGET_ARGO_URL || return 1
_mig_require_var TARGET_ARGO_APP || return 1

# Export normalized variables for downstream scripts.
export MIG_SOURCE_CLUSTER="$SOURCE_CLUSTER"
export MIG_SOURCE_KUBECONTEXT="$SOURCE_KUBECONTEXT"
export MIG_SOURCE_ARGO_URL="$SOURCE_ARGO_URL"
export MIG_SOURCE_ARGO_LOGIN_ARGS="${SOURCE_ARGO_LOGIN_ARGS:-}"

export MIG_TARGET_CLUSTER="$TARGET_CLUSTER"
export MIG_TARGET_KUBECONTEXT="$TARGET_KUBECONTEXT"
export MIG_TARGET_ARGO_URL="$TARGET_ARGO_URL"
export MIG_TARGET_ARGO_LOGIN_ARGS="${TARGET_ARGO_LOGIN_ARGS:-}"
export MIG_TARGET_ARGO_APP="$TARGET_ARGO_APP"
export MIG_TARGET_ARGO_SYNC_APPS="${TARGET_ARGO_SYNC_APPS:-$TARGET_ARGO_APP}"

# Export path-based discovery flag
export MIG_PATH_BASED_DISCOVERY="${MIG_PATH_BASED_DISCOVERY:-false}"

# Don't default SAFE_DELETE_PARENT_APPS when using path-based discovery (mutually exclusive)
if [[ "${MIG_PATH_BASED_DISCOVERY}" == "true" ]]; then
    export MIG_SAFE_DELETE_PARENT_APPS="${SAFE_DELETE_PARENT_APPS:-}"
else
    export MIG_SAFE_DELETE_PARENT_APPS="${SAFE_DELETE_PARENT_APPS:-$TARGET_ARGO_APP}"
fi
export MIG_RUNBOOK_APP_FILES="${RUNBOOK_APP_FILES:-}"
export MIG_SAFE_DELETE_INCLUDE_UNTRACKED="${SAFE_DELETE_INCLUDE_UNTRACKED:-false}"

_mig_detect_repo_root() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then
        return 1
    fi
    python3 - "$target" <<'PY'
import os, sys
path = os.path.realpath(sys.argv[1])
print(path)
PY
}

_default_repo_root="$(_mig_detect_repo_root "${_MIG_HELPER_DIR}/../..")"

if [[ -n "${MANIFEST_ROOT:-}" ]]; then
    _manifest_candidate="$MANIFEST_ROOT"
elif [[ -n "${MIG_MANIFEST_ROOT:-}" ]]; then
    _manifest_candidate="$MIG_MANIFEST_ROOT"
else
    _manifest_candidate="$_default_repo_root"
fi

_manifest_candidate="$(_mig_detect_repo_root "$_manifest_candidate")"
export MIG_MANIFEST_ROOT="$_manifest_candidate"
unset _manifest_candidate _default_repo_root

# Helper functions -----------------------------------------------------------

mig_use_source_context() {
    kubectl config use-context "$MIG_SOURCE_KUBECONTEXT"
}

mig_use_target_context() {
    kubectl config use-context "$MIG_TARGET_KUBECONTEXT"
}

mig_login_source_argo() {
    argocd login "$MIG_SOURCE_ARGO_URL" ${MIG_SOURCE_ARGO_LOGIN_ARGS}
}

mig_login_target_argo() {
    argocd login "$MIG_TARGET_ARGO_URL" ${MIG_TARGET_ARGO_LOGIN_ARGS}
}

mig_env_info() {
    cat <<EOF
Active migration environment: $(_basename="${_MIG_ENV_FILE##*/}"; echo "${_basename%.env}")
  Source:
    Cluster:      $MIG_SOURCE_CLUSTER
    Kubectl ctx:  $MIG_SOURCE_KUBECONTEXT
    Argo URL:     $MIG_SOURCE_ARGO_URL
  Target:
    Cluster:      $MIG_TARGET_CLUSTER
    Kubectl ctx:  $MIG_TARGET_KUBECONTEXT
    Argo URL:     $MIG_TARGET_ARGO_URL
    Default App:  $MIG_TARGET_ARGO_APP
EOF
}

# Print summary each time we load an env for visibility.
mig_env_info

# Cleanup helper internals
unset _MIG_HELPER_DIR _MIG_ENV_ARG _MIG_ENV_FILE _mig_require_var _mig_detect_self_path _mig_ensure_sourced _MIG_SELF_PATH
