#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Automates "Commit A" preparation for Regional Argo Cutover.
#
# Steps performed:
# 1. Copies App-of-Apps manifests (apps-*.yaml, infra-apps-*.yaml) from Source to Target directory.
# 2. Updates 'spec.destination.name' in the NEW Target manifests.
# 3. Disables auto-sync in the NEW Target manifests (using toggle-autosync.sh).
# 4. Adds the new manifests to the Target's kustomization.yaml.
# 5. Removes auto-sync from the OLD Source manifests.
# 6. Stages all changes to Git.
#
# Usage:
#   ./tools/migrations/prep-commit-a.sh --cluster <name> --source-argo <name> --target-argo <name>
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$SCRIPT_DIR"
TOGGLE_SCRIPT="${TOOLS_DIR}/toggle-autosync.sh"
YQ_BIN="yq"

if [[ -n "${MIG_MANIFEST_ROOT:-}" ]]; then
    MANIFEST_ROOT="$MIG_MANIFEST_ROOT"
else
    MANIFEST_ROOT="$(git rev-parse --show-toplevel)"
fi

usage() {
    echo "Usage: $0 --cluster <name> --source <path> --target <path> [--dest-name <name>] [--app-file <filename> ...]"
    echo ""
    echo "  --cluster       The name of the cluster being migrated (e.g., target-cluster)"
    echo "  --source        Path to source manifests (e.g., app-of-apps/clusters/source-argocd)"
    echo "  --target        Path to target manifests (e.g., app-of-apps/clusters/target-argocd)"
    echo "  --dest-name     The destination.name for the target manifests (default: in-cluster)"
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
        die "prep-commit-a.sh requires yq v4+ (found $version)"
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
DEST_NAME="in-cluster"
CUSTOM_FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster) CLUSTER="$2"; shift 2 ;;
        --source) SOURCE_DIR="${MANIFEST_ROOT}/$2"; shift 2 ;;
        --target) TARGET_DIR="${MANIFEST_ROOT}/$2"; shift 2 ;;
        --dest-name) DEST_NAME="$2"; shift 2 ;;
        --app-file) CUSTOM_FILES+=("$2"); shift 2 ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

if [[ -z "$CLUSTER" && -n "${MIG_SOURCE_CLUSTER:-}" ]]; then
    CLUSTER="$MIG_SOURCE_CLUSTER"
fi
if [[ -z "$SOURCE_DIR" && -n "${MIG_SOURCE_CLUSTER:-}" ]]; then
    SOURCE_DIR="${MANIFEST_ROOT}/app-of-apps/clusters/${MIG_SOURCE_CLUSTER}"
fi
if [[ -z "$TARGET_DIR" && -n "${MIG_TARGET_CLUSTER:-}" ]]; then
    TARGET_DIR="${MANIFEST_ROOT}/app-of-apps/clusters/${MIG_TARGET_CLUSTER}"
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
validate_input "$DEST_NAME" "dest-name"

# Validate custom files if provided
for file in "${CUSTOM_FILES[@]}"; do
    validate_input "$file" "app-file"
done

echo "🚀 Preparing Commit A for cluster '$CLUSTER'..."
echo "   Source: $SOURCE_DIR"
echo "   Target: $TARGET_DIR"
echo "   Destination: $DEST_NAME"

if [[ ! -d "$SOURCE_DIR" ]]; then
    die "Source directory does not exist: $SOURCE_DIR"
fi

mkdir -p "$TARGET_DIR"

# Pre-flight: Check for target kustomization.yaml
KUSTOMIZATION_FILE="${TARGET_DIR}/kustomization.yaml"
if [[ ! -f "$KUSTOMIZATION_FILE" ]]; then
    die "Target kustomization.yaml not found: $KUSTOMIZATION_FILE. Create it before running this script."
fi

if ((${#CUSTOM_FILES[@]})); then
    FILES=("${CUSTOM_FILES[@]}")
else
    FILES=("apps-${CLUSTER}.yaml" "infra-apps-${CLUSTER}.yaml")
fi

PROCESSED_COUNT=0

for file in "${FILES[@]}"; do
    SRC_FILE="${SOURCE_DIR}/${file}"
    DST_FILE="${TARGET_DIR}/${file}"

    if [[ ! -f "$SRC_FILE" ]]; then
        echo "⚠️  Source file not found: $SRC_FILE (skipping)"
        continue
    fi

    echo "Processing $file..."

    # 1. Copy original file to target (preserving original content for now)
    cp "$SRC_FILE" "$DST_FILE"

    # 2. Update Target File
    echo "   → Configuring target: $DST_FILE"
    # Set destination name (only if not in-cluster)
    if [[ "$DEST_NAME" != "in-cluster" ]]; then
        "$YQ_BIN" -i ".spec.destination.name = \"$DEST_NAME\"" "$DST_FILE"
        "$YQ_BIN" -i "del(.spec.destination.server)" "$DST_FILE"
    fi
    
    # Disable auto-sync on target (using toggle script for consistency/safety)
    "$TOGGLE_SCRIPT" --mode disable --app-of-app "$DST_FILE" >/dev/null

    # 3. Add to Target kustomization.yaml
    echo "   → Adding to kustomization: $KUSTOMIZATION_FILE"
    # Append to resources and ensure uniqueness
    "$YQ_BIN" -i ".resources = (.resources + [\"$file\"] | unique)" "$KUSTOMIZATION_FILE"
    git -C "$MANIFEST_ROOT" add "$KUSTOMIZATION_FILE"

    # 4. Update Source File (Legacy Prep)
    echo "   → Disabling source: $SRC_FILE"
    # Remove auto-sync block entirely (same as disable, but being explicit with yq for clarity if needed, 
    # though toggle-autosync.sh --mode disable does exactly this: del(.spec.syncPolicy.automated))
    "$TOGGLE_SCRIPT" --mode disable --app-of-app "$SRC_FILE" >/dev/null

    # 4. Git Stage
    git -C "$MANIFEST_ROOT" add "$SRC_FILE" "$DST_FILE"
    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
done

if (( PROCESSED_COUNT == 0 )); then
    echo "❌ No manifest files found for cluster '$CLUSTER' in '$SOURCE_ARGO'."
    exit 1
fi

echo "✅ Prep complete! Files staged for commit."
echo "   Run 'git diff --staged' to verify."
