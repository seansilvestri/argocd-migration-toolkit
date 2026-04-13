#!/usr/bin/env bash

# Helper for capturing, diffing, and watching pod restart counts during Argo cutovers.
# Usage examples:
#   ./tools/migrations/monitor-restarts.sh capture --kube-context target-cluster --output-prefix snapshots/target-pre-restarts
#   ./tools/migrations/monitor-restarts.sh diff --before snapshots/target-pre-restarts.json --after snapshots/target-post-restarts.json
#   ./tools/migrations/monitor-restarts.sh watch --kube-context target-cluster --argo-managed

set -euo pipefail

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "FATAL: '$1' not found in PATH" >&2
    exit 1
  }
}

kubectl_cmd() {
  local ctx=$1
  shift
  if [[ -n "$ctx" ]]; then
    kubectl --context "$ctx" "$@"
  else
    kubectl "$@"
  fi
}

capture_restarts() {
  local kube_context=""
  local selector=""
  local output_prefix=""
  local managed_only=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kube-context)
        kube_context="$2"
        shift 2
        ;;
      --selector)
        selector="$2"
        shift 2
        ;;
      --argo-managed)
        managed_only=1
        shift
        ;;
      --output-prefix)
        output_prefix="$2"
        shift 2
        ;;
      *)
        echo "Unknown capture argument: $1" >&2
        exit 1
        ;;
    esac
  done

  local timestamp
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  if [[ -z "$output_prefix" ]]; then
    output_prefix="snapshots/restarts-${timestamp}"
  fi
  mkdir -p "$(dirname "$output_prefix")"

  local json_path="${output_prefix}.json"
  local table_path="${output_prefix}.txt"

  local label_selector="$selector"
  if [[ $managed_only -eq 1 ]]; then
    label_selector=${label_selector:+$label_selector,}"app.kubernetes.io/managed-by=argo-cd"
  fi

  local label_args=()
  if [[ -n "$label_selector" ]]; then
    label_args+=(-l "$label_selector")
  fi

  echo "Collecting pod restart data..."
  kubectl_cmd "$kube_context" get pods -A "${label_args[@]}" -o json \
    | jq '[.items[]
            | {namespace: .metadata.namespace,
               pod: .metadata.name,
               restarts: ((.status.containerStatuses // [])
                          | map(.restartCount // 0)
                          | add // 0)}]' \
    >"$json_path"

  kubectl_cmd "$kube_context" get pods -A "${label_args[@]}" \
    -o custom-columns='NAMESPACE:.metadata.namespace,POD:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount' \
    >"$table_path"

  echo "Wrote restart summaries to:"
  echo "  JSON : $json_path"
  echo "  Table: $table_path"
}

diff_restarts() {
  local before=""
  local after=""
  local output=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --before)
        before="$2"
        shift 2
        ;;
      --after)
        after="$2"
        shift 2
        ;;
      --output)
        output="$2"
        shift 2
        ;;
      *)
        echo "Unknown diff argument: $1" >&2
        exit 1
        ;;
    esac
  done

  if [[ -z "$before" || -z "$after" ]]; then
    echo "Usage: $0 diff --before <pre.json> --after <post.json> [--output diff.json]" >&2
    exit 1
  fi
  local jq_expr='
    def to_map($arr):
      reduce $arr[] as $pod ({}; .[$pod.namespace + "/" + $pod.pod] = $pod.restarts // 0);
    ($before | to_map(.)) as $B |
    ($after  | to_map(.)) as $A |
    ( ($B | keys) + ($A | keys) | unique | sort ) as $keys |
    [ $keys[]
      | {pod: .,
         before: ($B[.] // 0),
         after:  ($A[.] // 0),
         delta:  (($A[.] // 0) - ($B[.] // 0))}
      | select(.delta != 0)
    ]'

  if [[ -n "$output" ]]; then
    jq -n --argfile before "$before" --argfile after "$after" "$jq_expr" >"$output"
    echo "Wrote restart delta report to $output"
  else
    jq -n --argfile before "$before" --argfile after "$after" "$jq_expr"
  fi
}

watch_restarts() {
  local kube_context=""
  local selector=""
  local managed_only=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kube-context)
        kube_context="$2"
        shift 2
        ;;
      --selector)
        selector="$2"
        shift 2
        ;;
      --argo-managed)
        managed_only=1
        shift
        ;;
      *)
        echo "Unknown watch argument: $1" >&2
        exit 1
        ;;
    esac
  done

  local label_selector="$selector"
  if [[ $managed_only -eq 1 ]]; then
    label_selector=${label_selector:+$label_selector,}"app.kubernetes.io/managed-by=argo-cd"
  fi

  local label_args=()
  if [[ -n "$label_selector" ]]; then
    label_args+=(-l "$label_selector")
  fi

  echo "Streaming pod restarts (ctrl-c to exit)..."
  kubectl_cmd "$kube_context" get pods -A "${label_args[@]}" \
    -o custom-columns='TIME:.metadata.creationTimestamp,NAMESPACE:.metadata.namespace,POD:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount' \
    --watch
}

main() {
  if [[ $# -lt 1 ]]; then
    cat <<'EOF' >&2
Usage: monitor-restarts.sh <command> [options]
Commands:
  capture   Capture restart counts into JSON + table files.
  diff      Compare two capture JSON files and list pods whose restart counts changed.
  watch     Stream restart counts in real time (optionally filtered to Argo-managed pods).
EOF
    exit 1
  fi

  local cmd=$1
  shift

  require_bin kubectl
  require_bin jq

  case "$cmd" in
    capture)
      capture_restarts "$@"
      ;;
    diff)
      diff_restarts "$@"
      ;;
    watch)
      watch_restarts "$@"
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      exit 1
      ;;
  esac
}

main "$@"
