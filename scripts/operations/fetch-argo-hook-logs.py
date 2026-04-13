#!/usr/bin/env python3
"""Retrieve Argo CD hook logs for slow-syncing applications.

This helper consumes the JSON summary emitted by ``analyze-sync-durations.py``
(or accepts explicit app names) and invokes the ``argocd`` CLI to collect hook
logs. It highlights lines that may indicate errors or slow-running hooks and can
optionally persist the aggregated findings as JSON.

Example usage::

    # Inspect the five slowest apps from the summary file
    ./tools/fetch-argo-hook-logs.py \
        --summary-json reports/sync-duration-summary.json \
        --max-apps 5 --since 48h --output-json reports/hook-logs.json

    # Focus on specific apps and tail only the latest 200 lines
    ./tools/fetch-argo-hook-logs.py --apps source-cluster.ingest-gateway \
        --apps example-cluster.agent-gateway-test --tail 200

The script expects the ``argocd`` CLI to be installed, authenticated, and
pointed at the desired Argo CD instance (via environment variables, config
files, or command flags). Use ``--extra-flag`` to append additional arguments to
``argocd app logs`` if needed (for example, ``--grpc-web``).
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

DEFAULT_ERROR_KEYWORDS = (
    "error",
    "fail",
    "timeout",
    "panic",
    "exception",
)


@dataclass
class AppCandidate:
    """An application selected for hook log inspection."""

    app: str
    context: Optional[str]
    max_duration: float
    avg_duration: Optional[float] = None


@dataclass
class HookLogSummary:
    """Summarised information about a single application's hook logs."""

    app: str
    context: Optional[str]
    command: List[str]
    return_code: int
    stdout_lines: int
    stderr: str
    highlighted_lines: List[str]


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--summary-json",
        type=Path,
        help="Path to analyze-sync-durations JSON output (optional if --apps provided)",
    )
    parser.add_argument(
        "--apps",
        action="append",
        default=[],
        help=(
            "Specific app names to inspect. Repeatable. Supports optional context prefix "
            "in the form context:app."
        ),
    )
    parser.add_argument(
        "--max-apps",
        type=int,
        default=5,
        help="Maximum number of apps to inspect when deriving from the summary JSON (default: 5)",
    )
    parser.add_argument(
        "--min-duration",
        type=float,
        default=0.0,
        help="Only consider apps whose max_duration meets or exceeds this value (seconds).",
    )
    parser.add_argument(
        "--top-entries",
        type=int,
        default=None,
        help="Fallback to top entries list when long_running_apps is empty (limit items).",
    )
    parser.add_argument(
        "--since",
        help=(
            "Time window passed to argocd app logs --since (optional; only use if your CLI supports it)"
        ),
    )
    parser.add_argument(
        "--tail",
        type=int,
        help="Limit the number of log lines by appending --tail to argocd (optional)",
    )
    parser.add_argument(
        "--argocd",
        default="argocd",
        help="Path to the argocd CLI binary (default: argocd)",
    )
    parser.add_argument(
        "--extra-flag",
        action="append",
        default=[],
        help="Additional flags to append to each argocd command (repeatable)",
    )
    parser.add_argument(
        "--output-json",
        type=Path,
        help="Optional destination to write the collected summaries as JSON",
    )
    parser.add_argument(
        "--keywords",
        action="append",
        help="Custom keywords (case-insensitive) to highlight in logs (repeatable)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Resolve candidate apps but skip invoking argocd",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print argocd commands before executing",
    )
    return parser.parse_args(argv)


def ensure_argocd_available(argocd_path: str) -> None:
    if shutil.which(argocd_path) is None:
        raise FileNotFoundError(
            f"Unable to locate '{argocd_path}'. Ensure argocd CLI is installed and on PATH."
        )


def load_summary(path: Path) -> Dict[str, object]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def parse_app_spec(spec: str) -> Tuple[Optional[str], str]:
    if ":" in spec:
        context, app = spec.split(":", 1)
        context = context.strip() or None
        return context, app.strip()
    return None, spec.strip()


def derive_candidates(
    *,
    summary: Optional[Dict[str, object]],
    apps_from_cli: Sequence[str],
    max_apps: int,
    min_duration: float,
    top_entries_limit: Optional[int],
) -> List[AppCandidate]:
    explicit: List[AppCandidate] = []
    for item in apps_from_cli:
        context, app = parse_app_spec(item)
        explicit.append(AppCandidate(app=app, context=context, max_duration=float("nan")))
    if explicit:
        return explicit

    if not summary:
        raise ValueError("Either --summary-json must be provided or --apps must be specified.")

    candidates: List[AppCandidate] = []
    long_running = summary.get("long_running_apps") or []
    for entry in long_running:
        max_duration = float(entry.get("max_duration", 0.0) or 0.0)
        if max_duration < min_duration:
            continue
        candidates.append(
            AppCandidate(
                app=str(entry.get("app", "")),
                context=entry.get("context"),
                max_duration=max_duration,
                avg_duration=float(entry.get("avg_duration", 0.0) or 0.0),
            )
        )
    if not candidates:
        top_entries = summary.get("top_entries") or []
        if top_entries_limit is not None:
            top_entries = top_entries[:top_entries_limit]
        for entry in top_entries:
            max_duration = float(entry.get("duration_seconds", 0.0) or 0.0)
            if max_duration < min_duration:
                continue
            candidates.append(
                AppCandidate(
                    app=str(entry.get("app", "")),
                    context=entry.get("context"),
                    max_duration=max_duration,
                    avg_duration=float(entry.get("duration_seconds", 0.0) or 0.0),
                )
            )

    candidates.sort(key=lambda item: item.max_duration if not is_nan(item.max_duration) else -1, reverse=True)
    if max_apps > 0:
        candidates = candidates[:max_apps]
    return candidates


def is_nan(value: float) -> bool:
    return value != value  # NaN check


def build_argocd_command(
    *,
    argocd_bin: str,
    app: str,
    since: Optional[str],
    tail: Optional[int],
    extra_flags: Sequence[str],
) -> List[str]:
    cmd = [argocd_bin, "app", "logs", app, "--kind", "Hook"]
    if since:
        cmd.extend(["--since", since])
    if tail is not None:
        cmd.extend(["--tail", str(tail)])
    cmd.extend(extra_flags)
    return cmd


def execute_command(cmd: Sequence[str]) -> Tuple[int, str, str]:
    completed = subprocess.run(
        list(cmd),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return completed.returncode, completed.stdout, completed.stderr


def highlight_lines(lines: Sequence[str], keywords: Sequence[str]) -> List[str]:
    if not keywords:
        return []
    pattern = re.compile("|".join(re.escape(word) for word in keywords), re.IGNORECASE)
    return [line for line in lines if pattern.search(line)]


def collect_hook_logs(
    *,
    candidates: Sequence[AppCandidate],
    argocd_bin: str,
    since: Optional[str],
    tail: Optional[int],
    extra_flags: Sequence[str],
    keywords: Sequence[str],
    dry_run: bool,
    verbose: bool,
) -> List[HookLogSummary]:
    summaries: List[HookLogSummary] = []
    for candidate in candidates:
        cmd = build_argocd_command(
            argocd_bin=argocd_bin,
            app=candidate.app,
            since=since,
            tail=tail,
            extra_flags=extra_flags,
        )
        if verbose:
            print("[argocd]", " ".join(cmd), file=sys.stderr)
        if dry_run:
            summaries.append(
                HookLogSummary(
                    app=candidate.app,
                    context=candidate.context,
                    command=list(cmd),
                    return_code=0,
                    stdout_lines=0,
                    stderr="",
                    highlighted_lines=[],
                )
            )
            continue

        return_code, stdout, stderr = execute_command(cmd)
        lines = stdout.splitlines()
        highlighted = highlight_lines(lines, keywords)
        summaries.append(
            HookLogSummary(
                app=candidate.app,
                context=candidate.context,
                command=list(cmd),
                return_code=return_code,
                stdout_lines=len(lines),
                stderr=stderr.strip(),
                highlighted_lines=highlighted[:100],
            )
        )
    return summaries


def display_report(candidates: Sequence[AppCandidate], summaries: Sequence[HookLogSummary]) -> None:
    candidate_by_app = {item.app: item for item in candidates}
    print("=== Hook Log Inspection ===")
    for summary in summaries:
        candidate = candidate_by_app.get(summary.app)
        header = summary.app
        if candidate and candidate.context:
            header = f"{candidate.context}:{summary.app}"
        print(f"\n{header}")
        if candidate and not is_nan(candidate.max_duration):
            print(
                f"  max_duration={candidate.max_duration:.1f}s avg_duration="
                f"{candidate.avg_duration:.1f}s"
            )
        print(f"  command: {' '.join(summary.command)}")
        print(f"  return_code: {summary.return_code} | lines: {summary.stdout_lines}")
        if summary.stderr:
            print(f"  stderr: {summary.stderr}")
        if summary.highlighted_lines:
            print("  highlighted lines:")
            for line in summary.highlighted_lines[:10]:
                print(f"    {line}")
            if len(summary.highlighted_lines) > 10:
                print(
                    f"    ... {len(summary.highlighted_lines) - 10} additional matching lines omitted"
                )
        else:
            print("  highlighted lines: none")


def write_json(path: Path, candidates: Sequence[AppCandidate], summaries: Sequence[HookLogSummary]) -> None:
    payload = {
        "candidates": [
            {
                "app": item.app,
                "context": item.context,
                "max_duration": item.max_duration,
                "avg_duration": item.avg_duration,
            }
            for item in candidates
        ],
        "summaries": [
            {
                **asdict(summary),
            }
            for summary in summaries
        ],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)

    keywords = args.keywords if args.keywords else list(DEFAULT_ERROR_KEYWORDS)

    summary_data: Optional[Dict[str, object]] = None
    if args.summary_json:
        if not args.summary_json.exists():
            print(f"Summary file not found: {args.summary_json}", file=sys.stderr)
            return 1
        summary_data = load_summary(args.summary_json)

    try:
        candidates = derive_candidates(
            summary=summary_data,
            apps_from_cli=args.apps,
            max_apps=args.max_apps,
            min_duration=args.min_duration,
            top_entries_limit=args.top_entries,
        )
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if not candidates:
        print("No applications matched the selection criteria.", file=sys.stderr)
        return 1

    if not args.dry_run:
        try:
            ensure_argocd_available(args.argocd)
        except FileNotFoundError as exc:
            print(str(exc), file=sys.stderr)
            return 1

    summaries = collect_hook_logs(
        candidates=candidates,
        argocd_bin=args.argocd,
        since=args.since,
        tail=args.tail,
        extra_flags=args.extra_flag,
        keywords=keywords,
        dry_run=args.dry_run,
        verbose=args.verbose,
    )

    display_report(candidates, summaries)

    if args.output_json:
        write_json(args.output_json, candidates, summaries)

    return 0


if __name__ == "__main__":
    sys.exit(main())
