#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Automates "Finish Commit B" preparation: Cleanup & Handoff.
#
# Steps performed:
# 1. Removes legacy App-of-Apps manifests from Git.
# 2. Removes entries from legacy kustomization.yaml.
# 3. Enables auto-sync on the NEW Target manifests (using toggle-autosync.sh).
# 4. Stages all changes to Git.
#
# Usage:
#   ./tools/migrations/prep-commit-b-cleanup.sh --cluster <name> --source-argo <name> --target-argo <name>
#

if [[ -n "${MIG_MANIFEST_ROOT:-}" ]]; then
    REPO_ROOT="$MIG_MANIFEST_ROOT"
else
    REPO_ROOT="$(git rev-parse --show-toplevel)"
fi
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOGGLE_SCRIPT="${TOOLS_DIR}/toggle-autosync.sh"
YQ_BIN="${YQ_BIN:-yq}"

usage() {
    echo "Usage: $0 --cluster <name> --source <path> --target <path> [--app-file <filename> ...]"
    echo ""
    echo "  --cluster       The name of the cluster being migrated (e.g., target-cluster)"
    echo "  --source        Path to source manifests (e.g., app-of-apps/clusters/source-argocd)"
    echo "  --target        Path to target manifests (e.g., app-of-apps/clusters/target-argocd)"
    echo "  --app-file      Specific manifest filename to process (relative to source dir)."
    echo "                  Can be repeated. Defaults to apps-<cluster>.yaml and infra-apps-<cluster>.yaml"
    exit 1
}

die() { echo "ERROR: $*" >&2; exit 1; }

require_yq_version() {
    local raw version major
    if ! command -v "$YQ_BIN" >/dev/null 2>&1; then
        die "$YQ_BIN not found in PATH."
    fi
    
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
        die "prep-commit-b-cleanup.sh requires yq v4+ (found $version)"
    fi
}

validate_input() {
    local value="$1"
    local name="$2"
    if [[ ! "$value" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        die "Invalid format for $name: '$value'. Must contain only alphanumeric characters, hyphens, underscores, and periods."
    fi
}

# Ensure tools exist
require_yq_version

if [[ ! -x "$TOGGLE_SCRIPT" ]]; then
    die "$TOGGLE_SCRIPT not found or not executable."
fi

CLUSTER=""
SOURCE_DIR=""
TARGET_DIR=""
CUSTOM_FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster) CLUSTER="$2"; shift 2 ;;
        --source) SOURCE_DIR="${REPO_ROOT}/$2"; shift 2 ;;
        --target) TARGET_DIR="${REPO_ROOT}/$2"; shift 2 ;;
        --app-file) CUSTOM_FILES+=("$2"); shift 2 ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

if [[ -z "$CLUSTER" && -n "${MIG_SOURCE_CLUSTER:-}" ]]; then
    CLUSTER="$MIG_SOURCE_CLUSTER"
fi
if [[ -z "$SOURCE_DIR" && -n "${MIG_SOURCE_CLUSTER:-}" ]]; then
    SOURCE_DIR="${REPO_ROOT}/app-of-apps/clusters/${MIG_SOURCE_CLUSTER}"
fi
if [[ -z "$TARGET_DIR" && -n "${MIG_TARGET_CLUSTER:-}" ]]; then
    TARGET_DIR="${REPO_ROOT}/app-of-apps/clusters/${MIG_TARGET_CLUSTER}"
fi

if [[ -z "$CLUSTER" ]]; then
    die "--cluster is required."
fi
if [[ -z "$SOURCE_DIR" ]]; then
    die "--source is required."
fi
if [[ -z "$TARGET_DIR" ]]; then
    die "--target is required."
fi

validate_input "$CLUSTER" "cluster"

for file in "${CUSTOM_FILES[@]}"; do
    validate_input "$file" "app-file"
done

echo "🚀 Preparing Finish Commit B (Cleanup & Enable) for cluster '$CLUSTER'..."
echo "   Source: $SOURCE_DIR"
echo "   Target: $TARGET_DIR"

if [[ ! -d "$SOURCE_DIR" ]]; then
    die "Source directory does not exist: $SOURCE_DIR"
fi
if [[ ! -d "$TARGET_DIR" ]]; then
    die "Target directory does not exist: $TARGET_DIR"
fi

if ((${#CUSTOM_FILES[@]})); then
    FILES=("${CUSTOM_FILES[@]}")
else
    FILES=("apps-${CLUSTER}.yaml" "infra-apps-${CLUSTER}.yaml")
fi

PROCESSED_COUNT=0

# 1. Remove Legacy Files & Update Source Kustomization
SRC_KUSTOMIZATION="${SOURCE_DIR}/kustomization.yaml"

for file in "${FILES[@]}"; do
    SRC_FILE="${SOURCE_DIR}/${file}"
    DST_FILE="${TARGET_DIR}/${file}"

    echo "Processing $file..."

    # Cleanup Legacy Source
    if [[ -f "$SRC_FILE" ]]; then
        echo "   → Removing legacy manifest: $SRC_FILE"
        git -C "$REPO_ROOT" rm -f "$SRC_FILE" || rm -f "$SRC_FILE"
        
        if [[ -f "$SRC_KUSTOMIZATION" ]]; then
            echo "   → Removing from source kustomization: $SRC_KUSTOMIZATION"
            "$YQ_BIN" -i "del(.resources[] | select(. == \"$file\"))" "$SRC_KUSTOMIZATION"
            git -C "$REPO_ROOT" add "$SRC_KUSTOMIZATION"
        fi
    else
        echo "⚠️  Source file not found (already deleted?): $SRC_FILE"
    fi

    # Enable Target Auto-Sync
    if [[ -f "$DST_FILE" ]]; then
        echo "   → Enabling auto-sync on target: $DST_FILE"
        "$TOGGLE_SCRIPT" --mode enable --app-of-app "$DST_FILE" >/dev/null
        git -C "$REPO_ROOT" add "$DST_FILE"
        PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
    else
        echo "⚠️  Target file not found: $DST_FILE"
    fi
done

if (( PROCESSED_COUNT == 0 )); then
    echo "⚠️  No target files were updated. Verify paths."
fi

echo "✅ Prep B Cleanup complete! Files staged."
echo "   Recommended commit message:"
echo "   git commit -m \"feat: retire ${CLUSTER}.apps from source-argocd; enable target-argocd\""
