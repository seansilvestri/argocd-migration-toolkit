# Example Runbooks

This directory contains example generated runbooks to show what `generate-runbook.sh` produces.

## What is a Runbook?

A runbook is a detailed, step-by-step guide for executing a specific migration. It's automatically generated from your environment profile and includes:

- All commands with parameters pre-filled
- Exact cluster names and URLs
- Safety checkpoints
- Rollback procedures
- Context switching commands

## Generating Your Own Runbook

```bash
# 1. Create environment profile
cp examples/env-profiles/example-migration.env envs/my-migration.env
vi envs/my-migration.env  # Edit with your details

# 2. Generate runbook
scripts/migration/generate-runbook.sh my-migration

# 3. Runbook created at: runbooks/my-migration.md
```

## Example Runbook

See `example-runbook.md` for a sample of what gets generated.

## Runbook Structure

Generated runbooks follow this structure:

1. **Header**: Environment details, source/target clusters
2. **App-of-Apps Pairing**: Which manifests are being migrated
3. **Commit A**: Preparation commands
4. **Pass 1 Disarm**: Source disarm commands with dry-run
5. **Target Sync**: Target sync commands
6. **Kyverno Policy** (Optional): Safety policy deployment
7. **Pass 2 Cleanup**: Source cleanup commands
8. **Commit B**: Finalization commands
9. **Verification**: Post-migration checks

## Using a Runbook

1. **Open the runbook** in your editor
2. **Follow step-by-step** - don't skip steps
3. **Check off sections** as you complete them
4. **Save as you go** - the runbook is your audit trail
5. **Keep for compliance** - attach to change tickets

## Customization

The runbook template can be customized at:
```
scripts/migration/templates/runbook.md.tmpl
```

Variables available in the template:
- `{{SOURCE_CLUSTER}}` - Source cluster name
- `{{TARGET_CLUSTER}}` - Target cluster name
- `{{SOURCE_ARGO_URL}}` - Source ArgoCD URL
- `{{TARGET_ARGO_URL}}` - Target ArgoCD URL
- `{{PARENT_APPS}}` - Space-separated parent apps
- And many more...

See `scripts/migration/templates/README.md` for full template documentation.
