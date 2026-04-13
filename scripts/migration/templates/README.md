# Runbook generation helper

This folder documents `generate-runbook.sh`, the template, and the env variables that control what
shows up in the Markdown output.

---

## When to use it

- **Before every cutover**: generate the forward runbook once the target manifests exist.
- **Before rollback rehearsals**: point at the reverse env (e.g., `target-cluster-reverse`) and
  regenerate as soon as the fallback manifests are staged.
- **During validation**: re-run after tweaking env files or manifest filenames; the generator is idempotent.

---

## Prerequisites

1. Python 3 (used for path resolution and template rendering).
2. An env profile under `tools/migrations/envs/<path>.env` (e.g., `tools/migrations/envs/non-prod/us/astg-use1-s1.env`) with the `SOURCE_*`, `TARGET_*`, safe-delete knobs, **and `MIG_MANIFEST_ROOT`** populated. `MIG_MANIFEST_ROOT` should point at the repo that holds the manifests you plan to edit (e.g., `/Users/<you>/git/k8s-deployments-prod`).
3. Manifest files for the App-of-Apps you plan to migrate (either in the source directory or listed via `RUNBOOK_APP_FILES`).
4. Run the helper from the tooling repo (`k8s-deployments-dev`). All scripts now resolve manifests via `MIG_MANIFEST_ROOT`, so there is no need to duplicate `tools/` across repos.

---

## Usage

```bash
cd /Users/<you>/git/k8s-deployments-dev
# If env files live in subdirectories, pass the relative path (e.g., non-prod/us/migration-test).
source ./tools/migrations/migration-env.sh <env-name-or-path>
./tools/migrations/generate-runbook.sh <env-name-or-path>
```

By default the Markdown lands under `tools/migrations/runbooks/<env-name-or-path>.md` (mirroring the env subdirectory). Override with `--output` only when you intentionally want a different destination.

Optional flags:

- `--app-file <path>` (repeatable) — override which App-of-App manifests are represented in the runbook.
- `--output <path>` — send the Markdown somewhere else (e.g., `/tmp/runbooks/<cluster>.md`).

---

## Env variables that influence the output

| Variable                        | Effect                                                                                                                                                                                                                                             |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TARGET_ARGO_APP`               | Primary App-of-Apps name used when scripts need a single default (manifest fallback paths, parent delete commands).                                                                                                                                |
| `TARGET_ARGO_SYNC_APPS`         | Space-separated list of target apps to refresh/sync during Target Sync phase. Controls the commands under "Target Sync."                                                                                                                           |
| `SAFE_DELETE_PARENT_APPS`       | Space-separated list of parent apps passed to `disarm-source.sh` and `cleanup-source.sh` via `--parent-app` flags.                                                                                                                                 |
| `SAFE_DELETE_INCLUDE_UNTRACKED` | When `true`, adds `--include-untracked` to the disarm/cleanup commands and highlights the blast radius.                                                                                                                                            |
| `RUNBOOK_APP_FILES`             | Space-separated manifest filenames (absolute, repo-relative to `MIG_MANIFEST_ROOT`, or bare). Use this when the generator cannot auto-detect App-of-Apps in the current env (e.g., rollback scenarios before copying manifests to the source dir). |

> **Reminder:** Bare filenames in `RUNBOOK_APP_FILES` are resolved against the source cluster directory first, then against the target directory. This allows rollback envs to reference the future fallback manifests even if they only exist on the target side.

---

## Template anatomy

The Markdown template lives at `tools/migrations/templates/runbook.md.tmpl` and renders in this order:

1. **Prep** — env sourcing snippet and App-of-Apps pairing tables.
2. **Commit A / Target Sync** — automatically injects `--app-file` flags for every manifest detected.
3. **Disarm/Cleanup sections** — expands parent apps and `--include-untracked` flag for `disarm-source.sh` and `cleanup-source.sh`.
4. **Finish Commit B & Final Cleanup** — mirrors the Commit A/B commands so the same manifest list is used end-to-end.

Whenever the env file changes, re-run `generate-runbook.sh` to pick up the new defaults (no need to edit the Markdown manually).

---

## Troubleshooting

| Symptom                                            | Likely cause                                                                          | Fix                                                                                                                                               |
| -------------------------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Runbook only shows one App-of-Apps                 | The generator could only find one manifest under the source directory.                | Add both filenames via `RUNBOOK_APP_FILES` (e.g., `apps-<cluster>.yaml infra-apps-<cluster>.yaml`) or copy the missing file into the source tree. |
| Safe-delete commands missing `--include-untracked` | `SAFE_DELETE_INCLUDE_UNTRACKED` not set (or set to `false`) in the env profile.       | Set `SAFE_DELETE_INCLUDE_UNTRACKED=true` for production cutovers so untracked legacy apps are removed.                                            |
| Login hints show the wrong auth style              | `SOURCE_ARGO_LOGIN_ARGS` / `TARGET_ARGO_LOGIN_ARGS` missing or outdated.              | Update the env profile and regenerate the runbook.                                                                                                |
| Template renders literal `{{PLACEHOLDER}}` text    | Running the script without sourcing the env first can leave required variables unset. | Always run `source ./tools/migrations/migration-env.sh <env>` before `generate-runbook.sh`.                                                       |

---

Need to script the runbook generation (e.g., CI or nightly builds)? Walk `tools/migrations/envs/` recursively (e.g., `find tools/migrations/envs -name '*.env'`) and call `generate-runbook.sh <relative-path>` for each entry. The script will automatically mirror the env path under `tools/migrations/runbooks/`, so you don’t need to compute per-env output locations.
