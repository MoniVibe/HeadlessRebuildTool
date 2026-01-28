---
name: buildbox-download-diag
description: Download and extract Buildbox diagnostics artifacts from GitHub Actions runs. Use when you need the buildbox_diag_* zip (meta/run_summary/watchdog/log tails) for remote buildbox runs.
---

# Buildbox Download Diag

## Quick Start

```powershell
pwsh -NoProfile -File scripts/download_buildbox_diag.ps1 -RunId 21428962925 -Title space4x -Expand
```

## Workflow

1) Identify the GitHub Actions run id (use buildbox-iterate or `gh run list`).
2) Download the newest `buildbox_diag_*` artifact for that run.
3) Expand and inspect the extracted folder.

## Parameters (helper script)

- `-RunId` (int, required)
- `-Title` (`space4x|godgame`, optional) — used to pick `buildbox_diag_<title>` artifacts.
- `-ArtifactName` (string, optional) — override name/prefix match.
- `-Repo` (string) — default `MoniVibe/HeadlessRebuildTool`.
- `-OutputRoot` (string) — default `C:\polish\queue\reports\_diag_downloads`.
- `-Expand` (switch) — expand the zip into `<OutputRoot>\<run_id>\<artifact_name>\`.

## Output

Prints:

- `artifact_name=...`
- `zip_path=...`
- `expanded_path=...` (if `-Expand`)

## Notes

- Requires GitHub CLI (`gh`) with `gh auth login` completed.
