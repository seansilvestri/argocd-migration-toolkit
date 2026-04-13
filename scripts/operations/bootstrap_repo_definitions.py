#!/usr/bin/env python3
"""Bootstrap Argo CD repository definitions from Kubernetes secrets.

Use this once when standing up a brand-new control plane so every Git/Helm repo
referenced by repo credential secrets is registered via ``argocd repo add``.
After the repositories exist, ``hydrate_repo_credentials.py`` can maintain them
as usual.
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


def run(cmd: List[str], *, capture_output: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        check=True,
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


def write_temp_file(content: bytes | str, suffix: str) -> Path:
    data = content.encode() if isinstance(content, str) else content
    fd, path_str = tempfile.mkstemp(suffix=suffix)
    path = Path(path_str)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    path.chmod(0o600)
    return path


def add_repo(argocd_cmd: str, secret: RepoSecret, dry_run: bool) -> None:
    repo_name = secret.repo_name or secret.name
    repo_url = secret.url
    if dry_run:
        print(f"[dry-run] Would register {repo_url} from secret {secret.name}")
        return

    cmd = [argocd_cmd, "repo", "add", repo_url, "--name", repo_name, "--upsert"]
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

        print(f"[bootstrap] {repo_url} (secret {secret.name})")
        run(cmd)
    finally:
        for path in temp_paths:
            try:
                path.unlink()
            except FileNotFoundError:
                pass


def login_to_argocd(argocd_cmd: str, server: str, login_args: Optional[str]) -> None:
    cmd = [argocd_cmd, "login", server]
    if login_args:
        cmd.extend(shlex.split(login_args))
    run(cmd)


def apply_context_preset(args: argparse.Namespace) -> None:
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
    server = preset.get("argoServer")
    kube_context = preset.get("kubeContext")
    if not server or not kube_context:
        raise ValueError(
            f"Context preset '{args.context_key}' must include both 'argoServer' and 'kubeContext'."
        )
    args.argo_server = server
    args.login_args = preset.get("loginArgs")
    args.kube_context = kube_context


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
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
        help="Extra secret name to bootstrap even if it doesn't match the selector (repeatable)",
    )
    parser.add_argument(
        "--argocd-cmd",
        default="argocd",
        help="Path to argocd CLI (default: %(default)s)",
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
        help="Only report which repos would be registered",
    )
    return parser.parse_args(list(argv))


def main(argv: Iterable[str]) -> int:
    args = parse_args(argv)
    apply_context_preset(args)
    login_to_argocd(args.argocd_cmd, args.argo_server, args.login_args)
    secrets = list_repo_secrets(
        args.namespace,
        args.selector,
        args.include_secrets,
        args.kube_context,
    )
    if not secrets:
        print(
            f"No repo credential secrets found in namespace '{args.namespace}' with selector '{args.selector}'",
            file=sys.stderr,
        )
        return 1
    for secret in secrets:
        if not secret.url:
            continue
        add_repo(args.argocd_cmd, secret, args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
