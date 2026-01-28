---
name: buildbox-diagnose
description: Diagnose Buildbox GitHub Actions runs by downloading buildbox_diag artifacts, extracting result zips, summarizing meta/run_summary/watchdog, and pointing to the primary evidence. Use when a buildbox run fails, is queued too long, or you need a quick triage summary.
---

# Buildbox Diagnose

## Quick Start

```powershell
pwsh -NoProfile -File scripts/diagnose_buildbox_run.ps1 -RunId 21434672832 -Title space4x
```

## Workflow

1) Get the run id from GitHub Actions.
2) Download the `buildbox_diag_*` artifact for that run.
3) Expand it and locate the newest `results/result_*` folder.
4) Generate a summary via `Polish/Ops/diag_summarize.ps1`.

## Parameters (helper script)

- `-RunId` (int, required)
- `-Title` (`space4x|godgame`, optional) – used to match artifact name.
- `-Repo` (string) – default `MoniVibe/HeadlessRebuildTool`.
- `-OutputRoot` (string) – default `C:\polish\queue\reports\_diag_downloads`.
- `-DiagTool` (string) – path to `diag_summarize.ps1`.

## Output

Prints:
- `diag_root=<path>`
- `result_dir=<path>`
- `summary_path=<path>` (if summarizer succeeded)

## Notes

- Requires GitHub CLI (`gh`) with `gh auth login` completed.
- If the summarizer is missing, the script will still download and expand the diag artifact.
