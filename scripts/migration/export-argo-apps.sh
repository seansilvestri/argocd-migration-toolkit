#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/export-argo-apps.sh <cluster> [output_dir]

Export sanitized Argo CD App-of-Apps definitions for the specified cluster.
By default, YAML files are written to backups/<cluster>/ in the current repo.

Prerequisites:
  - argocd CLI (authenticated against the source control plane)
  - jq installed in PATH
EOF
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

if ! command -v argocd >/dev/null 2>&1; then
  echo "error: argocd CLI not found in PATH" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required to sanitize Application output" >&2
  exit 1
fi

cluster="$1"
shift || true

out_dir="${1:-backups/${cluster}}"
mkdir -p "$out_dir"

apps=("${cluster}.infra-apps" "${cluster}.apps")

for app in "${apps[@]}"; do
  echo "Exporting ${app} -> ${out_dir}/${app}.yaml"
  tmp_file="$(mktemp)"
  if ! argocd app get "$app" -o json >"$tmp_file"; then
    echo "error: failed to fetch Application ${app}" >&2
    rm -f "$tmp_file"
    exit 1
  fi

  if ! jq '{
      apiVersion: .apiVersion,
      kind: .kind,
      metadata: ({
        name: .metadata.name,
        namespace: .metadata.namespace,
        labels: .metadata.labels,
        annotations: .metadata.annotations,
        finalizers: .metadata.finalizers
      } | with_entries(select(.value != null))),
      spec: .spec
    }' "$tmp_file" >"${out_dir}/${app}.yaml"; then
    echo "error: failed to process Application ${app}" >&2
    rm -f "$tmp_file"
    exit 1
  fi

  rm -f "$tmp_file"
  echo "  ✓ saved ${out_dir}/${app}.yaml"
  echo
done

echo "Finished exporting Application specs to ${out_dir}"
