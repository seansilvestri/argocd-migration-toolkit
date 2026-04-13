#!/usr/bin/env python3
"""Validate migration env profiles and runbooks against prod manifests.

Usage examples:
  python3 tools/migrations/validate_runbooks.py --tier prod --region ap
  python3 tools/migrations/validate_runbooks.py --tier prod
  python3 tools/migrations/validate_runbooks.py --tier prod --region us --region eu

Set --manifest-root if your k8s-deployments-prod checkout lives elsewhere.
"""
from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Set
import shlex
import re

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent  # repo/tools/migrations -> repo/tools -> repo root
DEFAULT_MANIFEST_REPO = \
    Path(os.environ.get("MIG_MANIFEST_ROOT", "/Users/sean.silvestri/git/k8s-deployments-prod"))


@dataclass
class EnvRecord:
    tier: str
    region: str
    env_name: str
    env_path: Path
    runbook_path: Path
    source_cluster: str
    target_cluster: str
    workload_name: str  # Without trailing .apps/.appsets
    workload_kind: str  # "apps" | "appsets" | other
    runbook_files: List[str]
    manifest_root: Path


def parse_env(path: Path) -> Dict[str, str]:
    data: Dict[str, str] = {}
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        key = key.strip()
        val = val.strip()
        if val.startswith('"') and val.endswith('"'):
            val = val[1:-1]
        data[key] = val
    return data


def load_envs(tier: str, regions: Sequence[str], default_manifest_root: Path) -> List[EnvRecord]:
    env_root = REPO_ROOT / "tools/migrations/envs" / tier
    runbook_root = REPO_ROOT / "tools/migrations/runbooks" / tier
    if not env_root.is_dir():
        raise SystemExit(f"Env directory missing: {env_root}")

    selected_regions: Sequence[str]
    if regions:
        selected_regions = regions
    else:
        selected_regions = sorted(p.name for p in env_root.iterdir() if p.is_dir())

    records: List[EnvRecord] = []
    for region in selected_regions:
        region_dir = env_root / region
        if not region_dir.is_dir():
            raise SystemExit(f"Region directory missing: {region_dir}")
        for env_path in sorted(region_dir.glob("*.env")):
            data = parse_env(env_path)
            src = data.get("SOURCE_CLUSTER")
            tgt = data.get("TARGET_CLUSTER")
            target_app = data.get("TARGET_ARGO_APP")
            raw_runbook_files = data.get("RUNBOOK_APP_FILES", "").strip()
            runbook_files = shlex.split(raw_runbook_files) if raw_runbook_files else []
            if not (src and tgt and target_app):
                print(f"⚠️  Skipping {env_path} (missing SOURCE_CLUSTER / TARGET_CLUSTER / TARGET_ARGO_APP)")
                continue
            workload_kind = "apps"
            if target_app.endswith(".appsets"):
                workload = target_app[: -len(".appsets")]
                workload_kind = "appsets"
            elif target_app.endswith(".apps"):
                workload = target_app[:-5]
            else:
                workload = target_app
            manifest_root_str = data.get("MIG_MANIFEST_ROOT")
            if manifest_root_str:
                manifest_root = Path(manifest_root_str).expanduser().resolve()
            else:
                manifest_root = default_manifest_root
            runbook_path = runbook_root / region / f"{env_path.stem}.md"
            records.append(
                EnvRecord(
                    tier=tier,
                    region=region,
                    env_name=env_path.stem,
                    env_path=env_path,
                    runbook_path=runbook_path,
                    source_cluster=src,
                    target_cluster=tgt,
                    workload_name=workload,
                    workload_kind=workload_kind,
                    runbook_files=runbook_files,
                    manifest_root=manifest_root,
                )
            )
    return records


def runbook_mentions(text: str, filename: str) -> bool:
    pattern = re.compile(rf"\b{re.escape(filename)}\b")
    return bool(pattern.search(text))


def index_cluster_manifests(records: Sequence[EnvRecord]) -> Dict[tuple[Path, str], Dict[str, Path]]:
    cache: Dict[tuple[Path, str], Dict[str, Path]] = {}
    for rec in records:
        key = (rec.manifest_root, rec.source_cluster)
        if key in cache:
            continue
        clusters_root = rec.manifest_root / "app-of-apps" / "clusters"
        if not clusters_root.is_dir():
            raise SystemExit(f"Manifest clusters dir missing: {clusters_root}")
        cluster_dir = clusters_root / rec.source_cluster
        files = {path.name: path for path in cluster_dir.glob("*.yaml")}
        cache[key] = files
    return cache


def validate(records: Sequence[EnvRecord]) -> bool:
    cluster_cache = index_cluster_manifests(records)
    overall_ok = True
    app_pattern = re.compile(r"\bapps-[a-z0-9-]+\.yaml\b")
    infra_pattern = re.compile(r"\binfra-apps-[a-z0-9-]+\.yaml\b")
    for rec in records:
        spec = f"{rec.tier}/{rec.region}/{rec.env_name}"
        apps_file = f"apps-{rec.workload_name}.yaml"
        infra_file = f"infra-apps-{rec.workload_name}.yaml"
        cluster_files = cluster_cache.get((rec.manifest_root, rec.source_cluster), {})
        issues: List[str] = []

        app_path = cluster_files.get(apps_file)
        infra_path = cluster_files.get(infra_file)
        runbook_text = ""
        if not rec.runbook_path.exists():
            issues.append(f"missing runbook {rec.runbook_path}")
        else:
            runbook_text = rec.runbook_path.read_text()

        explicit_files = rec.runbook_files or (["appsets.yaml"] if rec.workload_kind == "appsets" else [])
        if explicit_files:
            for entry in explicit_files:
                filename = Path(entry).name
                if filename not in cluster_files:
                    issues.append(f"missing manifest {filename} in {rec.source_cluster}")
                elif runbook_text and not runbook_mentions(runbook_text, filename):
                    issues.append(f"runbook missing '{filename}'")
        else:
            if app_path is None:
                issues.append(f"missing manifest {apps_file} in {rec.source_cluster}")

            if runbook_text:
                app_refs = set(app_pattern.findall(runbook_text))
                infra_refs = set(infra_pattern.findall(runbook_text))

                if app_path is not None and apps_file not in app_refs:
                    issues.append(f"runbook missing '{apps_file}'")

                cluster_infra_files = {name for name in cluster_files if name.startswith("infra-apps-")}
                if infra_path is not None:
                    if infra_file not in infra_refs:
                        issues.append(f"runbook missing '{infra_file}'")
                else:
                    matching_refs = sorted(infra_refs & cluster_infra_files)
                    if not matching_refs:
                        issues.append(f"missing manifest {infra_file} in {rec.source_cluster}")
                    # else: runbook references an existing infra manifest with a different name; treat as OK.

        if runbook_text:
            for needle in (rec.source_cluster, rec.target_cluster):
                if needle not in runbook_text:
                    issues.append(f"runbook missing '{needle}'")

        if issues:
            overall_ok = False
            print(f"❌ {spec}")
            for issue in issues:
                print(f"   - {issue}")
        else:
            print(f"✅ {spec}")
    return overall_ok


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate migration env/runbook pairs")
    parser.add_argument("--tier", default="prod", choices=["prod", "non-prod"], help="Env tier to validate")
    parser.add_argument(
        "--region",
        action="append",
        help="Region(s) to validate (e.g. ap). Pass multiple --region flags or omit for all",
    )
    parser.add_argument(
        "--manifest-root",
        default=str(DEFAULT_MANIFEST_REPO),
        help="Path to k8s-deployments-prod checkout (default: %(default)s)",
    )
    args = parser.parse_args()

    manifest_repo = Path(args.manifest_root).expanduser().resolve()
    records = load_envs(args.tier, args.region or [], manifest_repo)
    ok = validate(records)
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
