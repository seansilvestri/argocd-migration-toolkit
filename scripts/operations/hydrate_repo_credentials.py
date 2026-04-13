#!/usr/bin/env python3
"""Register Git and Helm/OCI repository secrets with the current Argo CD control plane.

The Argo CD control plane stores connection info as Kubernetes Secrets labeled
``argocd.argoproj.io/secret-type=repo-creds`` (Git) or ``argocd.argoproj.io/secret-type=repository``
(Helm/OCI). This helper enumerates those secrets, decodes their data, and runs
``argocd repo add`` for any URL that is not yet registered. It is intended to be
idempotent and safe to run before smoke tests so repo-server has credentials ready
for temporary Applications.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional
import shlex

DEFAULT_CONTEXTS_FILE = Path(__file__).with_name("contexts.yaml")

DEFAULT_SELECTOR = "argocd.argoproj.io/secret-type in (repo-creds,repository)"


@dataclass
class RepoSecret:
    name: str
    url: str
    repo_name: Optional[str]
    repo_type: Optional[str]
    project: Optional[str]
    enable_oci: bool
    ssh_private_key: Optional[str]
    username: Optional[str]
    password: Optional[str]
    insecure: bool
    tls_client_cert: Optional[bytes]
    tls_client_key: Optional[bytes]
    ca_cert: Optional[bytes]


class HydrationError(RuntimeError):
    """Raised when hydration cannot continue."""


def run(cmd: List[str], *, check: bool = True, capture_output: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        check=check,
        capture_output=capture_output,
        text=True,
    )


def decode_field(data: Dict[str, str], key: str, *, binary: bool = False) -> Optional[bytes | str]:
    raw = data.get(key)
    if raw is None:
        return None
    decoded = base64.b64decode(raw)
    if binary:
        return decoded
    return decoded.decode().strip()


def repo_url_key(secret: RepoSecret) -> Optional[str]:
    """Return the canonical URL used by argocd repo add for this secret."""
    if not secret.url:
        return None
    if secret.enable_oci and secret.url.startswith("oci://"):
        return secret.url[len("oci://") :]
    return secret.url


def add_kube_context(cmd: List[str], kube_context: Optional[str]) -> List[str]:
    if not kube_context:
        return ["kubectl"] + cmd
    return ["kubectl", "--context", kube_context] + cmd


def fetch_secret(namespace: str, name: str, kube_context: Optional[str]) -> Dict[str, object]:
    cmd = add_kube_context(
        [
            "-n",
            namespace,
            "get",
            "secret",
            name,
            "-o",
            "json",
        ],
        kube_context,
    )
    result = run(cmd, capture_output=True)
    return json.loads(result.stdout)


def list_repo_secrets(
    namespace: str,
    selector: str,
    include_names: List[str],
    kube_context: Optional[str],
) -> List[RepoSecret]:
    cmd = add_kube_context(
        [
            "-n",
            namespace,
            "get",
            "secrets",
            "-l",
            selector,
            "-o",
            "json",
        ],
        kube_context,
    )
    result = run(cmd, capture_output=True)
    payload = json.loads(result.stdout)
    items = payload.get("items", [])
    seen: set[str] = {item.get("metadata", {}).get("name") for item in items}
    for extra in include_names:
        if extra in seen:
            continue
        try:
            items.append(fetch_secret(namespace, extra, kube_context))
            seen.add(extra)
        except subprocess.CalledProcessError as exc:
            print(f"[warn] failed to fetch secret {extra}: {exc}", file=sys.stderr)
    secrets: List[RepoSecret] = []
    for item in items:
        metadata = item.get("metadata", {})
        name = metadata.get("name")
        data = item.get("data", {})
        if not name or "url" not in data:
            continue
        secrets.append(
            RepoSecret(
                name=name,
                url=decode_field(data, "url"),
                repo_name=decode_field(data, "name"),
                repo_type=decode_field(data, "type"),
                project=decode_field(data, "project"),
                enable_oci=(decode_field(data, "enableOCI") == "true"),
                ssh_private_key=decode_field(data, "sshPrivateKey"),
                username=decode_field(data, "username"),
                password=decode_field(data, "password"),
                insecure=(decode_field(data, "insecure") == "true"),
                tls_client_cert=decode_field(data, "tlsClientCertData", binary=True),
                tls_client_key=decode_field(data, "tlsClientCertKey", binary=True),
                ca_cert=decode_field(data, "caCertData", binary=True),
            )
        )
    return secrets


def repo_exists(argocd_cmd: str, url: str) -> bool:
    try:
        run([argocd_cmd, "repo", "get", url], check=True)
    except subprocess.CalledProcessError as exc:  # noqa: PERF203
        return False
    return True


def remove_repo(argocd_cmd: str, url: str) -> None:
    run([argocd_cmd, "repo", "rm", url], check=True)


def write_temp_file(content: bytes | str, suffix: str) -> Path:
    if isinstance(content, str):
        data = content.encode()
    else:
        data = content
    fd, path_str = tempfile.mkstemp(suffix=suffix)
    path = Path(path_str)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    path.chmod(0o600)
    return path


def add_repo(argocd_cmd: str, secret: RepoSecret, repo_url: str, dry_run: bool) -> None:
    if dry_run:
        print(f"[dry-run] Would register {repo_url} from secret {secret.name}")
        return

    repo_name = secret.repo_name or secret.name
    cmd = [argocd_cmd, "repo", "add", repo_url, "--name", repo_name]
    temp_paths: List[Path] = []

    try:
        if secret.repo_type:
            cmd.extend(["--type", secret.repo_type])
        if secret.project:
            cmd.extend(["--project", secret.project])
        if secret.enable_oci:
            cmd.append("--enable-oci")
        if secret.ssh_private_key:
            key_path = write_temp_file(secret.ssh_private_key, suffix=".key")
            temp_paths.append(key_path)
            cmd.extend(["--ssh-private-key-path", str(key_path)])
        if secret.username:
            cmd.extend(["--username", secret.username])
        if secret.password:
            cmd.extend(["--password", secret.password])
        if secret.insecure:
            cmd.append("--insecure")
        if secret.tls_client_cert and secret.tls_client_key:
            cert_path = write_temp_file(secret.tls_client_cert, suffix=".crt")
            key_path = write_temp_file(secret.tls_client_key, suffix=".key")
            temp_paths.extend([cert_path, key_path])
            cmd.extend([
                "--tls-client-cert-path",
                str(cert_path),
                "--tls-client-cert-key-path",
                str(key_path),
            ])
        if secret.ca_cert:
            ca_path = write_temp_file(secret.ca_cert, suffix=".ca")
            temp_paths.append(ca_path)
            cmd.extend(["--ca-path", str(ca_path)])

        print(f"[add] {repo_url} (secret {secret.name})")
        run(cmd)
    finally:
        for path in temp_paths:
            try:
                path.unlink()
            except FileNotFoundError:
                pass


def hydrate(
    argocd_cmd: str,
    namespace: str,
    selector: str,
    include_names: List[str],
    kube_context: Optional[str],
    dry_run: bool,
    force: bool,
    skip_exists_check: bool,
) -> None:
    secrets = list_repo_secrets(namespace, selector, include_names, kube_context)
    if not secrets:
        raise HydrationError(
            f"No repo credential secrets found in namespace '{namespace}' with selector '{selector}'"
        )
    seen_urls: set[str] = set()
    for secret in secrets:
        repo_url = repo_url_key(secret)
        if not repo_url:
            continue
        if repo_url in seen_urls:
            print(
                f"[dedupe] Skipping duplicate secret {secret.name} for repo {repo_url}; already handled."
            )
            continue
        seen_urls.add(repo_url)
        if skip_exists_check:
            exists = False
        else:
            exists = repo_exists(argocd_cmd, repo_url)
        if exists and not force:
            print(f"[skip] {repo_url} already registered")
            continue
        if exists and force:
            if dry_run:
                print(f"[dry-run] Would re-register {repo_url} from secret {secret.name}")
                continue
            print(f"[re-register] {repo_url} (secret {secret.name})")
            remove_repo(argocd_cmd, repo_url)
        add_repo(argocd_cmd, secret, repo_url, dry_run)


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.set_defaults(argo_server=None, login_args=None, kube_context=None)
    parser.add_argument(
        "--namespace",
        default="argocd",
        help="Namespace where repo credential secrets live (default: %(default)s)",
    )
    parser.add_argument(
        "--selector",
        default=DEFAULT_SELECTOR,
        help="Label selector for repo credential secrets (default: %(default)s)",
    )
    parser.add_argument(
        "--include-secret",
        dest="include_secrets",
        action="append",
        default=[],
        help="Extra secret name to hydrate even if it doesn't match the selector (repeatable)",
    )
    parser.add_argument(
        "--argocd-cmd",
        default="argocd",
        help="Path to argocd CLI (default: %(default)s)",
    )
    parser.add_argument(
        "--argo-server",
        help="Fully qualified Argo CD server to log into before hydrating repos.",
    )
    parser.add_argument(
        "--login-args",
        help="Extra arguments passed to 'argocd login' (e.g., '--sso' or '--auth-token <token>').",
    )
    parser.add_argument(
        "--kube-context",
        help="kubectl context to use when reading repo secrets (defaults to current context).",
    )
    parser.add_argument(
        "--context-key",
        required=True,
        help="Name of a preset in contexts.yaml that defines server/login/kube defaults.",
    )
    parser.add_argument(
        "--contexts-file",
        default=str(DEFAULT_CONTEXTS_FILE),
        help=f"Path to YAML file mapping context presets (default: {DEFAULT_CONTEXTS_FILE}).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Only report which repos would be added",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Re-register repos even if they already exist (removes then adds)",
    )
    parser.add_argument(
        "--skip-exists-check",
        action="store_true",
        help="Skip the repo existence check (useful when bootstrapping a brand-new control plane)",
    )
    return parser.parse_args(list(argv))


def login_to_argocd(argocd_cmd: str, server: Optional[str], login_args: Optional[str]) -> None:
    if not server:
        return
    cmd = [argocd_cmd, "login", server]
    if login_args:
        cmd.extend(shlex.split(login_args))
    run(cmd)


def apply_context_preset(args: argparse.Namespace) -> None:
    if not args.context_key:
        return
    contexts_path = Path(args.contexts_file).expanduser()
    if not contexts_path.exists():
        raise RuntimeError(f"Contexts file {contexts_path} not found (required for --context-key).")
    try:
        import yaml  # type: ignore
    except ModuleNotFoundError as exc:  # pragma: no cover - optional dependency
        raise RuntimeError(
            "PyYAML is required to parse contexts.yaml. Install with 'pip install PyYAML'."
        ) from exc
    presets = yaml.safe_load(contexts_path.read_text()) or {}
    if not isinstance(presets, dict) or args.context_key not in presets:
        raise ValueError(f"No context preset '{args.context_key}' found in {contexts_path}")
    preset = presets[args.context_key] or {}
    if not isinstance(preset, dict):
        raise ValueError(f"Context preset '{args.context_key}' must be a mapping.")
    args.argo_server = args.argo_server or preset.get("argoServer")
    args.login_args = args.login_args or preset.get("loginArgs")
    args.kube_context = args.kube_context or preset.get("kubeContext")


def main(argv: Iterable[str]) -> int:
    args = parse_args(argv)
    apply_context_preset(args)
    login_to_argocd(args.argocd_cmd, args.argo_server, args.login_args)
    try:
        hydrate(
            argocd_cmd=args.argocd_cmd,
            namespace=args.namespace,
            selector=args.selector,
            include_names=args.include_secrets,
            kube_context=args.kube_context,
            dry_run=args.dry_run,
            force=args.force,
            skip_exists_check=args.skip_exists_check,
        )
    except HydrationError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as exc:  # pragma: no cover - surfaces CLI errors
        print(exc, file=sys.stderr)
        return exc.returncode or 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
