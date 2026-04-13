#!/usr/bin/env python3
"""Utility for capturing and diffing Argo CD Application + workload snapshots.

The tool has two subcommands:

```
python3 tools/migrations/argocd_snapshot.py capture --apps apps-prod-cluster infra-prod-cluster
python3 tools/migrations/argocd_snapshot.py diff --before snapshots/20241201T010000Z --after snapshots/20241201T030000Z
```

`capture` stores trimmed `argocd app get -o json` output for each provided App-of-Apps, their
child Applications (by default), and optionally snapshots selected Kubernetes resource kinds
(Deployments by default). `diff` compares two snapshot directories and prints the differences.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple

import shlex
from urllib.parse import urlparse
from concurrent.futures import ThreadPoolExecutor, as_completed


def run(cmd: Sequence[str]) -> subprocess.CompletedProcess[str]:
    """Run a CLI command, raising a friendly RuntimeError on failure."""

    try:
        return subprocess.run(
            cmd,
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as exc:  # pragma: no cover - runtime only
        stderr = (exc.stderr or "").strip()
        stdout = (exc.stdout or "").strip()
        detail = stderr or stdout or str(exc)
        hint = ""
        if "permission denied" in detail.lower():
            hint = " Hint: ensure your argocd login has access to the requested application/control plane."
        raise RuntimeError(
            f"Command {' '.join(cmd)} failed (exit {exc.returncode}): {detail}.{hint}"
        ) from exc


def run_passthrough(cmd: Sequence[str]) -> None:
    """Run a CLI command while allowing interactive stdin/stdout."""

    subprocess.run(cmd, check=True)


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def trim_app_payload(payload: Dict[str, Any]) -> Dict[str, Any]:
    spec = payload.get("spec", {})
    status = payload.get("status", {})
    metadata = payload.get("metadata", {})

    trimmed = {
        "metadata": {
            "name": metadata.get("name"),
            "namespace": metadata.get("namespace"),
            "labels": metadata.get("labels", {}),
        },
        "spec": {
            "project": spec.get("project"),
            "destination": spec.get("destination"),
            # App-of-Apps can use either `source` (single) or `sources` (multi-repo)
            # so preserve both keys.
            "source": spec.get("source"),
            "sources": spec.get("sources"),
            "syncPolicy": spec.get("syncPolicy"),
        },
        "status": {
            "sync": status.get("sync"),
            "health": status.get("health"),
            "operationState": status.get("operationState", {}).get("phase"),
            "observedAt": status.get("observedAt"),
        },
    }
    return trimmed


def extract_child_apps(payload: Dict[str, Any]) -> List[str]:
    resources = payload.get("status", {}).get("resources", []) or []
    child_apps: Set[str] = set()
    for resource in resources:
        if resource.get("kind") == "Application" and resource.get("name"):
            child_apps.add(resource["name"])
    return sorted(child_apps)


def fetch_app_payload(argo_cli: str, app: str) -> Dict[str, Any]:
    result = run([argo_cli, "app", "get", app, "-o", "json"])
    return json.loads(result.stdout)


def capture_apps(
    argo_cli: str,
    root_apps: Sequence[str],
    include_child_apps: bool,
    exclude_apps: Optional[Set[str]] = None,
    parallelism: int = 4,
) -> Tuple[Dict[str, Dict[str, Any]], Dict[str, List[str]], List[str]]:
    snapshots: Dict[str, Dict[str, Any]] = {}
    exclude = exclude_apps or set()
    queue: List[str] = [app for app in dict.fromkeys(root_apps) if app not in exclude]
    discovered_children: Dict[str, List[str]] = {}
    failures: List[str] = []

    parallelism = max(1, parallelism)
    with ThreadPoolExecutor(max_workers=parallelism) as executor:
        while queue:
            batch: List[str] = []
            while queue and len(batch) < parallelism:
                app = queue.pop(0)
                if app in snapshots or app in exclude:
                    continue
                batch.append(app)

            if not batch:
                continue

            futures = {executor.submit(fetch_app_payload, argo_cli, app): app for app in batch}
            for future in as_completed(futures):
                app = futures[future]
                try:
                    payload = future.result()
                except RuntimeError as exc:
                    print(f"WARNING: unable to fetch {app}: {exc}")
                    failures.append(app)
                    continue

                snapshots[app] = trim_app_payload(payload)

                if include_child_apps:
                    children = extract_child_apps(payload)
                    if children:
                        discovered_children[app] = children
                        for child in children:
                            if child not in snapshots and child not in exclude:
                                queue.append(child)

    return snapshots, discovered_children, failures


def stable_hash(data: Any) -> Optional[str]:
    if data in (None, {}):
        return None
    serialized = json.dumps(data, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(serialized.encode("utf-8")).hexdigest()


def capture_resources(kubectl_cli: str, kinds: Sequence[str]) -> List[Dict[str, Any]]:
    resources: List[Dict[str, Any]] = []
    for kind in kinds:
        result = run([kubectl_cli, "get", kind, "-A", "-o", "json"])
        payload = json.loads(result.stdout)
        for item in payload.get("items", []):
            meta = item.get("metadata", {})
            entry = {
                "apiVersion": item.get("apiVersion"),
                "kind": item.get("kind"),
                "namespace": meta.get("namespace", "default"),
                "name": meta.get("name"),
                "generation": meta.get("generation"),
                "uid": meta.get("uid"),
                "specHash": stable_hash(item.get("spec")),
            }
            resources.append(entry)
    resources.sort(key=lambda x: (x["kind"], x["namespace"], x["name"]))
    return resources


def write_json(path: Path, data: Any) -> None:
    with path.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")


def normalize_argo_server(server: str) -> str:
    parsed = urlparse(server)
    if parsed.scheme:
        if not parsed.netloc:
            raise ValueError(f"Invalid Argo server URL: {server}")
        return parsed.netloc
    return server


def capture_command(args: argparse.Namespace) -> None:
    if args.login_kube_context:
        print(f"Switching kubectl context to {args.login_kube_context}")
        run([args.kubectl_cli, "config", "use-context", args.login_kube_context])

    if args.login_argo_url:
        server = normalize_argo_server(args.login_argo_url)
        cmd = [args.argo_cli, "login", server]
        login_args: List[str] = []
        interactive_login = False
        if args.login_argo_args:
            login_args = shlex.split(args.login_argo_args)
            interactive_login = any(arg == "--username" for arg in login_args) and "--sso" not in login_args
            cmd.extend(login_args)
        print(f"Logging into ArgoCD server {server}")
        if interactive_login:
            run_passthrough(cmd)
        else:
            run(cmd)

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output_dir = Path(args.output_dir or Path("snapshots") / timestamp)
    ensure_dir(output_dir)

    print(f"Writing snapshots to {output_dir}")

    exclude = set(args.exclude_apps or [])
    for root_app in args.app_of_apps:
        if root_app.endswith(".infra-apps"):
            cluster = root_app[: -len(".infra-apps")]
            if cluster:
                exclude.add(f"{cluster}.root-app-of-apps")

    app_snapshots, child_map, failures = capture_apps(
        args.argo_cli,
        args.app_of_apps,
        include_child_apps=not args.skip_child_apps,
        exclude_apps=exclude,
        parallelism=args.max_workers,
    )
    for name, payload in sorted(app_snapshots.items()):
        write_json(output_dir / f"{name}.app.json", payload)

    if not args.skip_resources:
        kinds = [k.strip() for k in args.resource_kinds.split(",") if k.strip()]
        resources = capture_resources(args.kubectl_cli, kinds)
        write_json(output_dir / "resources.json", {"kinds": kinds, "items": resources})
    else:
        kinds = []

    metadata = {
        "generatedAt": timestamp,
        "rootApps": sorted(args.app_of_apps),
        "includeChildApps": not args.skip_child_apps,
        "childApps": child_map,
        "failedApps": failures,
        "argoCli": args.argo_cli,
        "kubectlCli": args.kubectl_cli,
        "resourceKinds": kinds,
    }
    write_json(output_dir / "metadata.json", metadata)

    if failures:
        print(
            f"WARNING: {len(failures)} app(s) could not be fetched. See metadata.json for details."
        )


def load_app_snapshots(directory: Path) -> Dict[str, Dict[str, Any]]:
    snapshots: Dict[str, Dict[str, Any]] = {}
    for path in directory.glob("*.app.json"):
        snapshots[path.stem.replace(".app", "")] = json.loads(path.read_text(encoding="utf-8"))
    return snapshots


def flatten(payload: Any, prefix: str = "") -> Iterable[Tuple[str, Any]]:
    if isinstance(payload, dict):
        for key, value in payload.items():
            new_prefix = f"{prefix}.{key}" if prefix else key
            yield from flatten(value, new_prefix)
    elif isinstance(payload, list):
        for idx, value in enumerate(payload):
            new_prefix = f"{prefix}[{idx}]"
            yield from flatten(value, new_prefix)
    else:
        yield prefix, payload


def compare_app_snapshots(before: Mapping[str, Dict[str, Any]], after: Mapping[str, Dict[str, Any]]) -> None:
    names = sorted(set(before) | set(after))
    for name in names:
        if name not in after:
            print(f"- App {name} missing in AFTER snapshot")
            continue
        if name not in before:
            print(f"- App {name} new in AFTER snapshot")
            continue

        before_flat = dict(flatten(before[name]))
        after_flat = dict(flatten(after[name]))
        keys = sorted(set(before_flat) | set(after_flat))
        diffs = []
        for key in keys:
            if before_flat.get(key) != after_flat.get(key):
                diffs.append((key, before_flat.get(key), after_flat.get(key)))
        if diffs:
            print(f"- App {name} changed:")
            for key, old, new in diffs:
                print(f"    {key}: {old} -> {new}")


def load_resource_snapshot(directory: Path) -> Dict[str, Dict[str, Any]]:
    path = directory / "resources.json"
    if not path.exists():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    items = {}
    for item in data.get("items", []):
        key = (item.get("apiVersion"), item.get("kind"), item.get("namespace"), item.get("name"))
        items[key] = item
    return items


def compare_resource_snapshots(before_items: Mapping[Tuple[str, str, str, str], Dict[str, Any]], after_items: Mapping[Tuple[str, str, str, str], Dict[str, Any]]) -> None:
    keys = set(before_items) | set(after_items)
    missing = []
    added = []
    changed = []
    for key in sorted(keys):
        if key not in after_items:
            missing.append(key)
            continue
        if key not in before_items:
            added.append(key)
            continue
        if before_items[key].get("specHash") != after_items[key].get("specHash"):
            changed.append(key)

    if missing:
        print("- Resources missing after snapshot:")
        for key in missing:
            print(f"    {key}")
    if added:
        print("- New resources after snapshot:")
        for key in added:
            print(f"    {key}")
    if changed:
        print("- Resources with spec hash changes:")
        for key in changed:
            print(f"    {key}")


def diff_command(args: argparse.Namespace) -> None:
    before_dir = Path(args.before)
    after_dir = Path(args.after)
    if not before_dir.exists() or not after_dir.exists():
        raise FileNotFoundError("Before/after directories must exist")

    print("== App-of-Apps differences ==")
    before_apps = load_app_snapshots(before_dir)
    after_apps = load_app_snapshots(after_dir)
    compare_app_snapshots(before_apps, after_apps)

    print("\n== Kubernetes resource differences ==")
    before_resources = load_resource_snapshot(before_dir)
    after_resources = load_resource_snapshot(after_dir)
    if before_resources or after_resources:
        compare_resource_snapshots(before_resources, after_resources)
    else:
        print("(resources.json missing in one or both snapshots)")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Capture and diff Argo CD App-of-Apps plus selected Kubernetes resources.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    capture_parser = subparsers.add_parser("capture", help="Create a snapshot")
    capture_parser.add_argument(
        "--app-of-apps",
        "--apps",
        nargs="+",
        required=True,
        dest="app_of_apps",
        help="App-of-Apps names to snapshot (e.g., target-cluster.apps).",
    )
    capture_parser.add_argument("--output-dir", help="Directory to store the snapshot (defaults to snapshots/<UTC timestamp>.)")
    capture_parser.add_argument("--argo-cli", default="argocd", help="Path to argocd CLI (default: argocd).")
    capture_parser.add_argument("--kubectl-cli", default="kubectl", help="Path to kubectl CLI (default: kubectl).")
    capture_parser.add_argument(
        "--resource-kinds",
        default="deployments",
        help="Comma-separated list of kubectl resource kinds to snapshot (default: deployments).",
    )
    capture_parser.add_argument(
        "--exclude-apps",
        nargs="+",
        default=[],
        help="Application names to skip (useful for parents you cannot access, e.g., target-cluster.root-app-of-apps).",
    )
    capture_parser.add_argument(
        "--skip-child-apps",
        action="store_true",
        help="Only snapshot the specified App-of-Apps; skip auto-discovered child Applications.",
    )
    capture_parser.add_argument(
        "--skip-resources",
        action="store_true",
        help="Skip kubectl resource capture (only save Argo Applications).",
    )
    capture_parser.add_argument(
        "--login-argo-url",
        help="Optional Argo CD base URL to log into before running captures (e.g., https://argocd.example.com).",
    )
    capture_parser.add_argument(
        "--login-argo-args",
        default="",
        help="Additional args to pass to `argocd login` (e.g., \"--sso\" or \"--username admin --password ...\").",
    )
    capture_parser.add_argument(
        "--login-kube-context",
        help="Optional kubectl context to switch to before running captures.",
    )
    capture_parser.add_argument(
        "--max-workers",
        type=int,
        default=4,
        help="Maximum number of parallel argocd app fetches (default: 4).",
    )
    capture_parser.set_defaults(func=capture_command)

    diff_parser = subparsers.add_parser("diff", help="Compare two snapshot directories")
    diff_parser.add_argument("--before", required=True, help="Directory produced by the capture command (baseline).")
    diff_parser.add_argument("--after", required=True, help="Directory produced by the capture command (post-change).")
    diff_parser.set_defaults(func=diff_command)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
