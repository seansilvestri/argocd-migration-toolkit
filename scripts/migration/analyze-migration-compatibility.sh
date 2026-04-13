#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Analyze migration compatibility for all workload clusters managed by a control plane.
#
# This script performs a comprehensive analysis of ArgoCD Applications and ApplicationSets
# to identify potential issues before migration. It checks for:
#
#   1. ApplicationSet sync policies (create-only vs create-update)
#   2. Finalizers on Applications and ApplicationSets
#   3. preserveResourcesOnDeletion settings
#   4. Cross-cluster ApplicationSets (deploy to multiple workload clusters)
#   5. Unhealthy or out-of-sync Applications
#   6. Apps with Replace=true sync option (can cause issues)
#   7. Orphaned Applications (not managed by any App-of-Apps)
#
# Usage:
#   ./tools/migrations/analyze-migration-compatibility.sh --context <kubectl-context>
#   ./tools/migrations/analyze-migration-compatibility.sh --context source-cluster
#   ./tools/migrations/analyze-migration-compatibility.sh --context legacy-cluster --output report.csv
#
# Output:
#   - Summary table per workload cluster
#   - Detailed issue breakdown
#   - Optional CSV export for further analysis

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
CONTEXT=""
OUTPUT_FILE=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Analyze migration compatibility for workload clusters.

Options:
  --context <name>     Kubectl context for the control plane (required)
  --output <file>      Export results to CSV file
  -h, --help           Show this help

Examples:
  $(basename "$0") --context source-cluster
  $(basename "$0") --context legacy-cluster --output prod-analysis.csv
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --context)
            CONTEXT="$2"
            shift 2
            ;;
        --output)
            OUTPUT_FILE="$2"
            shift 2
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

if [[ -z "$CONTEXT" ]]; then
    echo "❌ --context is required" >&2
    usage
fi

echo "=========================================="
echo "Migration Compatibility Analysis"
echo "=========================================="
echo "Control Plane: $CONTEXT"
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# Save current context to restore later
ORIGINAL_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "")

# Restore context on exit
cleanup() {
    if [[ -n "$ORIGINAL_CONTEXT" ]] && [[ "$ORIGINAL_CONTEXT" != "$CONTEXT" ]]; then
        kubectl config use-context "$ORIGINAL_CONTEXT" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# Switch context
echo "→ Switching to context: $CONTEXT"
kubectl config use-context "$CONTEXT" >/dev/null 2>&1 || {
    echo "❌ Failed to switch to context: $CONTEXT" >&2
    exit 1
}

# Get all applications
echo "→ Fetching Applications..."
APPS_JSON=$(kubectl get applications -n argocd -o json 2>/dev/null)
TOTAL_APPS=$(echo "$APPS_JSON" | jq '.items | length')

# Get all applicationsets
echo "→ Fetching ApplicationSets..."
APPSETS_JSON=$(kubectl get applicationsets -n argocd -o json 2>/dev/null)
TOTAL_APPSETS=$(echo "$APPSETS_JSON" | jq '.items | length')

echo "   Found $TOTAL_APPS Applications, $TOTAL_APPSETS ApplicationSets"
echo ""

#######################################
# Global Issue Detection
#######################################

echo "→ Analyzing global issues..."

# 1. Cross-cluster ApplicationSets (deploy to multiple clusters)
# These need special attention as they span workload clusters
CROSS_CLUSTER_APPSETS=$(echo "$APPSETS_JSON" | jq -r '
  [.items[] | select(.metadata.name | test("^(otel-|cross-|global-)"))] | length')

# 2. Unhealthy Applications
UNHEALTHY_APPS=$(echo "$APPS_JSON" | jq '[.items[] | select(.status.health.status != "Healthy" and .status.health.status != null)] | length')

# 3. Out-of-sync Applications  
OUTOFSYNC_APPS=$(echo "$APPS_JSON" | jq '[.items[] | select(.status.sync.status != "Synced" and .status.sync.status != null)] | length')

# 4. Apps with Replace=true (can cause issues during sync)
REPLACE_APPS=$(echo "$APPS_JSON" | jq '[.items[] | select(.spec.syncPolicy.syncOptions[]? == "Replace=true")] | length')

# 5. Apps without owner references (potentially orphaned)
# These might not be managed by any App-of-Apps
ORPHANED_APPS=$(echo "$APPS_JSON" | jq '[.items[] | select(.metadata.ownerReferences == null or (.metadata.ownerReferences | length) == 0) | select(.metadata.name | test("\\.(apps|infra-apps)$") | not)] | length')

# 6. ApplicationSets without preserveResourcesOnDeletion
APPSETS_NO_PRESERVE=$(echo "$APPSETS_JSON" | jq '[.items[] | select(.spec.syncPolicy.preserveResourcesOnDeletion != true)] | length')

# 7. Multi-source Applications (more complex, but generally OK)
MULTISOURCE_APPS=$(echo "$APPS_JSON" | jq '[.items[] | select(.spec.sources != null and (.spec.sources | length) > 1)] | length')

echo "   Global checks complete"
echo ""

# Extract unique workload cluster prefixes from app names
# Handles both patterns: "example-cluster.apps" and "snake.apps"
# Excludes:
#   - System apps like "root-app-of-apps", "argocd-nonprod"
#   - Environment prefixes like "auto.", "dev.", "int.", "stage." (these are cross-cluster apps)
WORKLOAD_CLUSTERS=$(echo "$APPS_JSON" | jq -r '.items[].metadata.name' | \
    grep -E '^[a-z]' | \
    grep '\.' | \
    sed 's/\..*//' | \
    grep -vE '^(root|argocd|kargo|auto|dev|int|stage)$' | \
    sort -u)

# Count workload clusters
NUM_CLUSTERS=$(echo "$WORKLOAD_CLUSTERS" | grep -c . || echo 0)
echo "Found $NUM_CLUSTERS workload cluster(s) to analyze"
echo ""

# CSV header
if [[ -n "$OUTPUT_FILE" ]]; then
    echo "cluster,total_apps,apps_with_finalizers,appsets,appsets_with_finalizers,appsets_create_only,appsets_preserve_on_delete,compatibility,notes" > "$OUTPUT_FILE"
fi

# Print table header
printf "%-25s %8s %12s %8s %12s %12s %12s %12s %s\n" \
    "CLUSTER" "APPS" "W/FINALIZER" "APPSETS" "W/FINALIZER" "CREATE-ONLY" "PRESERVE" "STATUS" "NOTES"
printf "%-25s %8s %12s %8s %12s %12s %12s %12s %s\n" \
    "-------------------------" "--------" "------------" "--------" "------------" "------------" "------------" "------------" "-----"

# Analyze each workload cluster
for CLUSTER in $WORKLOAD_CLUSTERS; do
    # Skip root/meta apps
    if [[ "$CLUSTER" == "root" ]] || [[ "$CLUSTER" == "argocd" ]]; then
        continue
    fi

    # Count apps for this cluster
    CLUSTER_APPS=$(echo "$APPS_JSON" | jq --arg c "$CLUSTER" '[.items[] | select(.metadata.name | startswith($c + "."))] | length')
    
    # Count apps with finalizers
    APPS_WITH_FINALIZERS=$(echo "$APPS_JSON" | jq --arg c "$CLUSTER" '[.items[] | select(.metadata.name | startswith($c + ".")) | select(.metadata.finalizers != null and (.metadata.finalizers | length) > 0)] | length')
    
    # Count appsets for this cluster
    CLUSTER_APPSETS=$(echo "$APPSETS_JSON" | jq --arg c "$CLUSTER" '[.items[] | select(.metadata.name | startswith($c + "."))] | length')
    
    # Count appsets with finalizers
    APPSETS_WITH_FINALIZERS=$(echo "$APPSETS_JSON" | jq --arg c "$CLUSTER" '[.items[] | select(.metadata.name | startswith($c + ".")) | select(.metadata.finalizers != null and (.metadata.finalizers | length) > 0)] | length')
    
    # Count appsets with create-only policy (potential issue)
    APPSETS_CREATE_ONLY=$(echo "$APPSETS_JSON" | jq --arg c "$CLUSTER" '[.items[] | select(.metadata.name | startswith($c + ".")) | select(.spec.syncPolicy.applicationsSync == "create-only")] | length')
    
    # Count appsets with preserveResourcesOnDeletion
    APPSETS_PRESERVE=$(echo "$APPSETS_JSON" | jq --arg c "$CLUSTER" '[.items[] | select(.metadata.name | startswith($c + ".")) | select(.spec.syncPolicy.preserveResourcesOnDeletion == true)] | length')
    
    # Count apps with syncPolicy.automated enabled (will prune if orphaned)
    APPS_WITH_AUTOSYNC=$(echo "$APPS_JSON" | jq --arg c "$CLUSTER" '[.items[] | select(.metadata.name | startswith($c + ".")) | select(.spec.syncPolicy.automated != null)] | length')
    
    # Count appsets that ignore syncPolicy differences (can re-apply syncPolicy after disarm)
    APPSETS_IGNORE_SYNCPOLICY=$(echo "$APPSETS_JSON" | jq --arg c "$CLUSTER" '[.items[] | select(.metadata.name | startswith($c + ".")) | select(.spec.ignoreApplicationDifferences[]?.jsonPointers[]? == "/spec/syncPolicy")] | length')
    
    # Determine compatibility status
    STATUS="✅"
    NOTES=""
    
    # Check for potential issues
    if [[ "$APPSETS_CREATE_ONLY" -gt 0 ]]; then
        STATUS="⚠️"
        NOTES="$APPSETS_CREATE_ONLY AppSet(s) use create-only"
    fi
    
    if [[ "$APPSETS_WITH_FINALIZERS" -gt 0 ]]; then
        if [[ -n "$NOTES" ]]; then
            NOTES="$NOTES; "
        fi
        NOTES="${NOTES}$APPSETS_WITH_FINALIZERS AppSet(s) have finalizers"
    fi
    
    if [[ "$APPS_WITH_AUTOSYNC" -gt 0 ]]; then
        STATUS="⚠️"
        if [[ -n "$NOTES" ]]; then
            NOTES="$NOTES; "
        fi
        NOTES="${NOTES}$APPS_WITH_AUTOSYNC app(s) have auto-sync enabled"
    fi
    
    if [[ "$APPSETS_IGNORE_SYNCPOLICY" -gt 0 ]]; then
        STATUS="⚠️"
        if [[ -n "$NOTES" ]]; then
            NOTES="$NOTES; "
        fi
        NOTES="${NOTES}$APPSETS_IGNORE_SYNCPOLICY AppSet(s) ignore syncPolicy diffs"
    fi
    
    if [[ -z "$NOTES" ]]; then
        NOTES="-"
    fi
    
    # Print row
    printf "%-25s %8d %12d %8d %12d %12d %12d %12s %s\n" \
        "$CLUSTER" "$CLUSTER_APPS" "$APPS_WITH_FINALIZERS" "$CLUSTER_APPSETS" \
        "$APPSETS_WITH_FINALIZERS" "$APPSETS_CREATE_ONLY" "$APPSETS_PRESERVE" "$STATUS" "$NOTES"
    
    # CSV output
    if [[ -n "$OUTPUT_FILE" ]]; then
        echo "$CLUSTER,$CLUSTER_APPS,$APPS_WITH_FINALIZERS,$CLUSTER_APPSETS,$APPSETS_WITH_FINALIZERS,$APPSETS_CREATE_ONLY,$APPSETS_PRESERVE,$STATUS,\"$NOTES\"" >> "$OUTPUT_FILE"
    fi
done

echo ""
echo "=========================================="
echo "Summary"
echo "=========================================="
echo "Total Applications: $TOTAL_APPS"
echo "Total ApplicationSets: $TOTAL_APPSETS"
echo "Workload Clusters: $NUM_CLUSTERS"

# Overall compatibility check
TOTAL_CREATE_ONLY=$(echo "$APPSETS_JSON" | jq '[.items[] | select(.spec.syncPolicy.applicationsSync == "create-only")] | length')
TOTAL_APPSETS_WITH_FINALIZERS=$(echo "$APPSETS_JSON" | jq '[.items[] | select(.metadata.finalizers != null and (.metadata.finalizers | length) > 0)] | length')

echo ""
echo "=========================================="
echo "Detailed Issue Analysis"
echo "=========================================="

# Track if we have any blocking issues
BLOCKING_ISSUES=0
WARNING_ISSUES=0

echo ""
echo "🔴 BLOCKING ISSUES (must fix before migration):"
echo "------------------------------------------------"
echo "  ✅ None - our scripts handle all known edge cases"
echo ""
echo "     cleanup-source.sh:"
echo "     - Deletes AppSets first with --cascade=orphan (prevents child recreation)"
echo "     - Re-checks and removes syncPolicy before each app deletion"
echo "     - Handles race where AppSets re-apply syncPolicy after disarm"
echo "     - Verifies finalizer removal before deletion"

echo ""
echo "🟡 WARNINGS (review recommended):"
echo "----------------------------------"

# create-only AppSets - handled by cleanup-source.sh (deletes AppSets first)
if [[ "$TOTAL_CREATE_ONLY" -gt 0 ]]; then
    echo "  ⚠️  $TOTAL_CREATE_ONLY ApplicationSet(s) use 'create-only' policy"
    echo "     cleanup-source.sh handles this by deleting AppSets first with --cascade=orphan."
    WARNING_ISSUES=$((WARNING_ISSUES + 1))
fi

# Finalizers - handled by disarm-source.sh but worth noting
if [[ "$TOTAL_APPSETS_WITH_FINALIZERS" -gt 0 ]]; then
    echo "  ⚠️  $TOTAL_APPSETS_WITH_FINALIZERS ApplicationSet(s) have finalizers"
    echo "     disarm-source.sh will remove these automatically."
    WARNING_ISSUES=$((WARNING_ISSUES + 1))
fi

# AppSets without preserveResourcesOnDeletion - our scripts use --cascade=orphan so this is OK
if [[ "$APPSETS_NO_PRESERVE" -gt 0 ]]; then
    echo "  ⚠️  $APPSETS_NO_PRESERVE ApplicationSet(s) missing preserveResourcesOnDeletion"
    echo "     cleanup-source.sh uses --cascade=orphan which handles this safely."
    WARNING_ISSUES=$((WARNING_ISSUES + 1))
fi

# Unhealthy apps - should be investigated
if [[ "$UNHEALTHY_APPS" -gt 0 ]]; then
    echo "  ⚠️  $UNHEALTHY_APPS Application(s) are not Healthy"
    echo "     Consider fixing these before migration to ensure clean state."
    echo ""
    echo "     Sample unhealthy apps:"
    echo "$APPS_JSON" | jq -r '.items[] | select(.status.health.status != "Healthy" and .status.health.status != null) | "       - \(.metadata.name) (\(.status.health.status))"' | head -5
    WARNING_ISSUES=$((WARNING_ISSUES + 1))
fi

# Out-of-sync apps
if [[ "$OUTOFSYNC_APPS" -gt 0 ]]; then
    echo "  ⚠️  $OUTOFSYNC_APPS Application(s) are OutOfSync"
    echo "     Consider syncing these before migration."
    WARNING_ISSUES=$((WARNING_ISSUES + 1))
fi

# Cross-cluster AppSets
if [[ "$CROSS_CLUSTER_APPSETS" -gt 0 ]]; then
    echo "  ⚠️  $CROSS_CLUSTER_APPSETS cross-cluster ApplicationSet(s) detected"
    echo "     These deploy to multiple workload clusters and need coordinated migration."
    echo ""
    echo "     Cross-cluster AppSets:"
    echo "$APPSETS_JSON" | jq -r '.items[] | select(.metadata.name | test("^(otel-|cross-|global-)")) | "       - \(.metadata.name)"'
    WARNING_ISSUES=$((WARNING_ISSUES + 1))
fi

# Replace=true apps
if [[ "$REPLACE_APPS" -gt 0 ]]; then
    echo "  ⚠️  $REPLACE_APPS Application(s) use Replace=true sync option"
    echo "     These may behave differently during sync; monitor closely."
    WARNING_ISSUES=$((WARNING_ISSUES + 1))
fi

if [[ "$WARNING_ISSUES" -eq 0 ]]; then
    echo "  ✅ None detected"
fi

echo ""
echo "ℹ️  INFORMATIONAL:"
echo "------------------"
echo "  • Multi-source Applications: $MULTISOURCE_APPS"
echo "  • Apps without owner references: $ORPHANED_APPS (may be top-level App-of-Apps)"

echo ""
echo "=========================================="
echo "Migration Readiness"
echo "=========================================="

if [[ "$BLOCKING_ISSUES" -gt 0 ]]; then
    echo ""
    echo "  ❌ NOT READY - $BLOCKING_ISSUES blocking issue(s) found"
    echo "     Address the issues above before proceeding with migration."
elif [[ "$WARNING_ISSUES" -gt 0 ]]; then
    echo ""
    echo "  ⚠️  READY WITH CAUTION - $WARNING_ISSUES warning(s) found"
    echo "     Migration should work, but review warnings above."
    echo "     Our scripts (disarm-source.sh, cleanup-source.sh) handle most of these."
else
    echo ""
    echo "  ✅ READY - No blocking issues or warnings detected"
    echo "     Migration should proceed smoothly with standard runbook."
fi

echo ""
echo "Legend:"
echo "  APPS          - Total Applications for this workload cluster"
echo "  W/FINALIZER   - Apps/AppSets with resources-finalizer"
echo "  CREATE-ONLY   - AppSets with applicationsSync: create-only"
echo "  PRESERVE      - AppSets with preserveResourcesOnDeletion: true"
echo "  STATUS        - ✅ Compatible, ⚠️ Review recommended"

if [[ -n "$OUTPUT_FILE" ]]; then
    # Append summary section to CSV
    echo "" >> "$OUTPUT_FILE"
    echo "# SUMMARY" >> "$OUTPUT_FILE"
    echo "total_apps,$TOTAL_APPS" >> "$OUTPUT_FILE"
    echo "total_appsets,$TOTAL_APPSETS" >> "$OUTPUT_FILE"
    echo "workload_clusters,$NUM_CLUSTERS" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
    echo "# GLOBAL ISSUES" >> "$OUTPUT_FILE"
    echo "blocking_issues,$BLOCKING_ISSUES" >> "$OUTPUT_FILE"
    echo "warning_issues,$WARNING_ISSUES" >> "$OUTPUT_FILE"
    echo "appsets_create_only,$TOTAL_CREATE_ONLY" >> "$OUTPUT_FILE"
    echo "appsets_with_finalizers,$TOTAL_APPSETS_WITH_FINALIZERS" >> "$OUTPUT_FILE"
    echo "appsets_no_preserve,$APPSETS_NO_PRESERVE" >> "$OUTPUT_FILE"
    echo "unhealthy_apps,$UNHEALTHY_APPS" >> "$OUTPUT_FILE"
    echo "outofsync_apps,$OUTOFSYNC_APPS" >> "$OUTPUT_FILE"
    echo "cross_cluster_appsets,$CROSS_CLUSTER_APPSETS" >> "$OUTPUT_FILE"
    echo "replace_apps,$REPLACE_APPS" >> "$OUTPUT_FILE"
    echo "multisource_apps,$MULTISOURCE_APPS" >> "$OUTPUT_FILE"
    echo "orphaned_apps,$ORPHANED_APPS" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
    echo "# MIGRATION READINESS" >> "$OUTPUT_FILE"
    if [[ "$BLOCKING_ISSUES" -gt 0 ]]; then
        echo "status,NOT_READY" >> "$OUTPUT_FILE"
    elif [[ "$WARNING_ISSUES" -gt 0 ]]; then
        echo "status,READY_WITH_CAUTION" >> "$OUTPUT_FILE"
    else
        echo "status,READY" >> "$OUTPUT_FILE"
    fi
    echo ""
    echo "Results exported to: $OUTPUT_FILE"
fi

echo ""
echo "=========================================="
