#!/usr/bin/env python3
"""Argo CD CLI-based smoke tester.

The script does three things:
1. Lists all repositories registered in the target Argo CD.
2. Lists all registered clusters.
3. Creates temporary "smoke" Applications (defined in a tests file) and
   performs `argocd app sync --dry-run --prune` for each.

Nothing new is added to Argo permanently unless --keep-apps is set.
The tests file can be JSON or YAML (requires PyYAML installed locally).
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Tuple
from urllib.parse import urlparse


def run(cmd: List[str], capture: bool = True) -> subprocess.CompletedProcess[str]:
    """Run an argocd CLI command with uniform error handling."""
    try:
        return subprocess.run(
            cmd,
            check=True,
            capture_output=capture,
            text=True,
        )
    except subprocess.CalledProcessError as exc:  # pragma: no cover - CLI errors
        if capture:
            sys.stderr.write(exc.stdout or "")
            sys.stderr.write(exc.stderr or "")
        raise


def list_repos(argocd: str) -> List[Dict[str, Any]]:
    result = run([argocd, "repo", "list", "-o", "json"])
    repos = json.loads(result.stdout)
    print("\n== Repositories ==")
    for repo in repos:
        status = repo.get("connectionState", {}).get("status")
        name = repo.get("name") or repo.get("repo") or "<unknown>"
        print(f"- {name:<25} {repo.get('repo', '<unknown>'):<70} status={status}")
    return repos


def list_clusters(argocd: str) -> List[Dict[str, Any]]:
    result = run([argocd, "cluster", "list", "-o", "json"])
    clusters = json.loads(result.stdout)
    print("\n== Clusters ==")
    for cluster in clusters:
        status = cluster.get("connectionState", {}).get("status")
        print(f"- {cluster['name']:<25} {cluster['server']:<60} status={status}")
    return clusters


def load_tests(path: Path) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    content = path.read_text()

    if path.suffix.lower() in {".yaml", ".yml"}:
        try:
            import yaml  # type: ignore

            data = yaml.safe_load(content)
        except ModuleNotFoundError as exc:  # pragma: no cover - runtime env
            raise RuntimeError(
                "PyYAML is required to parse YAML tests files. Install with 'pip install PyYAML' "
                "or supply the tests file as JSON."
            ) from exc
    else:
        data = json.loads(content)

    config: Dict[str, Any] = {}
    tests = None
    if isinstance(data, dict):
        raw_config = data.get("config") or {}
        if raw_config and not isinstance(raw_config, dict):
            raise ValueError(f"Top-level config in {path} must be a mapping.")
        config = raw_config or {}
        tests = data.get("tests")
    if not tests:
        raise ValueError(f"No tests defined in {path}")
    if not isinstance(tests, list):
        raise ValueError(f"'tests' in {path} must be a list.")
    return config, tests


def apply_test_defaults(tests: List[Dict[str, Any]], defaults: Dict[str, Any]) -> List[Dict[str, Any]]:
    if not defaults:
        return tests

    merged_tests: List[Dict[str, Any]] = []
    scalar_defaults = {
        key: defaults.get(key)
        for key in ("repoURL", "path", "targetRevision", "project")
        if defaults.get(key)
    }
    destination_namespace = defaults.get("destinationNamespace")

    for test in tests:
        merged = dict(test)
        for key, value in scalar_defaults.items():
            merged.setdefault(key, value)

        destination = merged.get("destination")
        if destination_namespace and isinstance(destination, dict) and not destination.get("namespace"):
            merged_destination = dict(destination)
            merged_destination.setdefault("namespace", destination_namespace)
            merged["destination"] = merged_destination

        merged_tests.append(merged)

    return merged_tests


def filter_tests(
    tests: List[Dict[str, Any]],
    argo_instance: str | None,
    active_only: bool,
) -> List[Dict[str, Any]]:
    filtered: List[Dict[str, Any]] = []
    for test in tests:
        if argo_instance and test.get("argoInstance") != argo_instance:
            continue
        if active_only and test.get("active", True) is False:
            continue
        filtered.append(test)
    return filtered


def create_or_update_app(argocd: str, test: Dict[str, Any]) -> None:
    cmd = [
        argocd,
        "app",
        "create",
        test["name"],
        "--project",
        test.get("project", "default"),
        "--repo",
        test["repoURL"],
        "--path",
        test["path"],
        "--revision",
        test.get("targetRevision", "HEAD"),
        "--dest-name",
        test["destination"]["name"],
        "--dest-namespace",
        test["destination"]["namespace"],
        "--upsert",
    ]

    for opt, value in (
        ("--helm-release-name", test.get("helmReleaseName")),
        ("--sync-option", test.get("syncOption")),
    ):
        if value:
            cmd.extend([opt, value])

    for values_file in test.get("valuesFiles", []) or []:
        cmd.extend(["--values", values_file])

    run(cmd, capture=True)


def dry_run_app(argocd: str, name: str, timeout_seconds: int) -> None:
    print(f"\n== Dry-run sync for {name} ==")
    cmd = [
        argocd,
        "app",
        "sync",
        name,
        "--dry-run",
        "--prune",
        "--timeout",
        str(timeout_seconds),
    ]
    run(cmd, capture=False)


def delete_app(argocd: str, name: str) -> None:
    run([argocd, "app", "delete", name, "--yes"], capture=True)


def repo_exists(argocd: str, repo_url: str) -> bool:
    try:
        run([argocd, "repo", "get", repo_url])
    except subprocess.CalledProcessError:
        return False
    return True


def normalize_argo_server(server: str) -> str:
    parsed = urlparse(server)
    if parsed.scheme:
        if not parsed.netloc:
            raise ValueError(f"Invalid Argo CD server URL: {server}")
        return parsed.netloc
    return server


def login_to_argocd(argocd: str, server: str, raw_args: str | None) -> None:
    normalized = normalize_argo_server(server)
    cmd = [argocd, "login", normalized]
    if raw_args:
        cmd.extend(shlex.split(raw_args))
    print(f"Logging into Argo CD server {normalized}")
    run(cmd, capture=False)


def run_pre_commands(commands: List[str]) -> None:
    """Execute optional shell commands (e.g., repo bootstrap helpers) before validation."""
    for command in commands:
        if not command:
            continue
        print(f"Running pre-command: {command}")
        subprocess.run(command, shell=True, check=True)  # noqa: S602


def terminate_app_operation(argocd: str, name: str) -> None:
    """Best-effort stop of a running operation to unblock deletion."""
    try:
        run([argocd, "app", "terminate-op", name], capture=True)
    except Exception:
        # If there is no running operation, argocd returns an error we can ignore.
        pass


def write_temp_key(data: bytes) -> Path:
    fd, path_str = tempfile.mkstemp(suffix=".key")
    path = Path(path_str)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    path.chmod(0o600)
    return path


def fetch_secret_field(entry: Dict[str, Any]) -> bytes:
    namespace = entry["namespace"]
    name = entry["name"]
    kube_context = entry.get("kubeContext")
    cmd = ["kubectl"]
    if kube_context:
        cmd.extend(["--context", kube_context])
    cmd.extend(["-n", namespace, "get", "secret", name, "-o", "json"])
    result = subprocess.run(cmd, check=True, capture_output=True, text=True)
    payload = json.loads(result.stdout)
    data = payload.get("data") or {}
    field_name = entry.get("keyField", "sshPrivateKey")
    raw = data.get(field_name)
    if not raw:
        raise RuntimeError(
            f"Secret {name} in namespace {namespace} is missing '{field_name}'"
        )
    return base64.b64decode(raw)


def bootstrap_repos(argocd: str, entries: List[Dict[str, Any]]) -> List[Tuple[str, bool]]:
    """Temporarily register repos (typically for smoke tests) using secrets from another cluster."""
    cleanup_targets: List[Tuple[str, bool]] = []
    try:
        for entry in entries:
            repo_url = entry["repoURL"]
            force = bool(entry.get("force", False))
            existed_before = repo_exists(argocd, repo_url)
            if existed_before and not force:
                print(f"[bootstrap] {repo_url} already registered; skipping.")
                continue
            key_bytes = fetch_secret_field(entry["secret"])
            temp_key = write_temp_key(key_bytes)
            repo_name = entry.get("repoName") or entry.get("name") or repo_url
            enable_cleanup = entry.get("cleanup", True)
            extra_args = entry.get("extraArgs") or []
            try:
                cmd = [
                    argocd,
                    "repo",
                    "add",
                    repo_url,
                    "--name",
                    repo_name,
                    "--upsert",
                    "--ssh-private-key-path",
                    str(temp_key),
                ]
                cmd.extend(extra_args)
                print(f"[bootstrap] Registering {repo_url} via secret {entry['secret']['name']}")
                run(cmd, capture=False)
                if enable_cleanup and not existed_before:
                    cleanup_targets.append((repo_url, True))
                elif enable_cleanup and existed_before:
                    print(
                        f"[bootstrap] {repo_url} existed beforehand; skipping cleanup to preserve original registration."
                    )
            finally:
                temp_key.unlink(missing_ok=True)  # type: ignore[arg-type]
        return cleanup_targets
    except Exception:
        if cleanup_targets:
            cleanup_bootstrap_repos(argocd, cleanup_targets)
        raise


def cleanup_bootstrap_repos(argocd: str, targets: List[Tuple[str, bool]]) -> None:
    for repo_url, should_cleanup in targets:
        if not should_cleanup:
            continue
        try:
            print(f"[bootstrap] Removing temporary repo {repo_url}")
            run([argocd, "repo", "rm", repo_url], capture=False)
        except subprocess.CalledProcessError as exc:
            print(f"Warning: failed to remove repo {repo_url}: {exc}", file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Validate Argo CD repositories/clusters via dry-run Applications.",
    )
    parser.add_argument(
        "--tests-file",
        required=True,
        help="Path to YAML or JSON file describing smoke tests (see script header).",
    )
    parser.add_argument(
        "--argo-instance",
        help="Only run tests whose 'argoInstance' field matches this value.",
    )
    parser.add_argument(
        "--active-only",
        action="store_true",
        help="Skip tests that have 'active: false' in the tests file.",
    )
    parser.add_argument(
        "--keep-apps",
        action="store_true",
        help="Do not delete temporary Applications after running dry-runs.",
    )
    parser.add_argument(
        "--argocd-cli",
        default="argocd",
        help="Path to the argocd binary (default: argocd in PATH).",
    )
    parser.add_argument(
        "--login-argo-url",
        help="Optional Argo CD server to log into before running tests (e.g., https://argocd.example.com).",
    )
    parser.add_argument(
        "--login-argo-args",
        help="Extra arguments passed to 'argocd login' (e.g., '--sso' or '--auth-token <token>').",
    )
    parser.add_argument(
        "--pre-command",
        action="append",
        default=[],
        help="Shell command to run before validation (repeatable). Useful for temporary repo bootstraps.",
    )
    parser.add_argument(
        "--bootstrap-repo-config",
        action="append",
        default=[],
        help="JSON string describing a repo bootstrap entry (see README). Repeatable.",
    )
    parser.add_argument(
        "--sync-timeout",
        type=int,
        default=30,
        help="Seconds to wait for each argocd sync (default: 30). Increase if clusters respond slowly.",
    )
    args = parser.parse_args()

    tests_path = Path(args.tests_file)
    config, tests = load_tests(tests_path)
    tests = apply_test_defaults(tests, config)
    tests = filter_tests(tests, args.argo_instance, args.active_only)
    if not tests:
        raise ValueError("No tests match the provided filters.")

    login_url = args.login_argo_url or config.get("argoServer")
    login_args = args.login_argo_args or config.get("loginArgs")
    if login_url:
        login_to_argocd(args.argocd_cli, login_url, login_args)

    pre_commands = config.get("preCommands", [])
    if not isinstance(pre_commands, list):
        raise ValueError("'preCommands' must be a list if provided in config.")
    combined_pre_commands = pre_commands + (args.pre_command or [])
    if combined_pre_commands:
        run_pre_commands(combined_pre_commands)

    bootstrap_entries = config.get("bootstrapRepos", [])
    if not isinstance(bootstrap_entries, list):
        raise ValueError("'bootstrapRepos' must be a list if provided in config.")
    for json_entry in args.bootstrap_repo_config:
        bootstrap_entries.append(json.loads(json_entry))

    bootstrap_cleanup_targets: List[Tuple[str, bool]] = []
    try:
        if bootstrap_entries:
            bootstrap_cleanup_targets = bootstrap_repos(args.argocd_cli, bootstrap_entries)

        list_repos(args.argocd_cli)
        list_clusters(args.argocd_cli)

        print("\n== Planned smoke tests ==")
        for test in tests:
            dest = test["destination"]
            instance = test.get("argoInstance", "<unspecified>")
            is_active = test.get("active", True)
            repo = test.get("repoURL") or config.get("repoURL") or "<repo>"
            path = test.get("path") or config.get("path") or "<path>"
            revision = test.get("targetRevision") or config.get("targetRevision") or "HEAD"
            project = test.get("project") or config.get("project") or "default"
            print(
                f"- {test['name']}: repo={repo} path={path} revision={revision} project={project} "
                f"dest={dest['name']}/{dest['namespace']} argoInstance={instance} active={is_active}"
            )

        failures = []

        for test in tests:
            try:
                create_or_update_app(args.argocd_cli, test)
                dry_run_app(args.argocd_cli, test["name"], args.sync_timeout)
            except Exception as exc:  # noqa: BLE001 - surfaced at end
                failures.append((test["name"], exc))
                terminate_app_operation(args.argocd_cli, test["name"])
            finally:
                if not args.keep_apps:
                    try:
                        delete_app(args.argocd_cli, test["name"])
                    except Exception as cleanup_exc:  # noqa: BLE001 - cleanup best effort
                        print(
                            f"Warning: failed to delete temporary app {test['name']}: {cleanup_exc}",
                            file=sys.stderr,
                        )

        if failures:
            print("\n== Failures ==")
            for name, exc in failures:
                print(f"- {name}: {exc}")
            sys.exit(1)

        print("\nAll dry-run tests completed successfully.")
    finally:
        if bootstrap_cleanup_targets:
            cleanup_bootstrap_repos(args.argocd_cli, bootstrap_cleanup_targets)


if __name__ == "__main__":
    main()
