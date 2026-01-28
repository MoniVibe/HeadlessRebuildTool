---
name: workflow-guard
description: Preflight and guard Buildbox workflows and labels to prevent silent fallbacks or queued runs. Use before triggering buildbox or when runs stay queued unexpectedly.
---

# Workflow Guard

## Quick Start

```powershell
pwsh -NoProfile -File scripts/check_workflow_guard.ps1
```

## What it checks

- `buildbox_on_demand.yml` exists and targets the `buildbox` runner label.
- `nightly-evals.yml` exists and targets the expected label (default `headless-e2e`).
- Buildbox workflow exports `GIT_COMMIT`/`GIT_BRANCH` for BuildStamp visibility.
- Basic YAML presence checks for the buildbox workflow.

## Parameters (helper script)

- `-RepoRoot` (string) — default `C:\Dev\unity_clean\headlessrebuildtool`
- `-BuildboxWorkflow` (string) — default `.github/workflows/buildbox_on_demand.yml`
- `-NightlyWorkflow` (string) — default `.github/workflows/nightly-evals.yml`
- `-ExpectedRunnerLabel` (string) — default `buildbox`
- `-ExpectedNightlyLabel` (string) — default `headless-e2e`

## Output

Prints `OK:` and `WARN:` lines. Returns non-zero if a critical check fails.
