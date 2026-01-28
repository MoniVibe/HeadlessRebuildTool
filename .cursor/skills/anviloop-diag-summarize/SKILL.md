---
name: anviloop-diag-summarize
description: Summarize Anviloop diagnostics artifacts (meta/run_summary/watchdog/invariants/log tails) into a concise report. Use after downloading buildbox_diag artifacts or when triaging nightly failures.
---

# Anviloop Diag Summarize

## Quick Start

```powershell
pwsh -NoProfile -File C:\Dev\unity_clean\headlessrebuildtool\Polish\Ops\diag_summarize.ps1 -ResultDir C:\polish\queue\reports\_diag_downloads\21428962925\buildbox_diag_space4x_21428962925\results\result_... -OutPath C:\polish\queue\reports\diag_space4x_21428962925.md
```

## What it does

- Reads `meta.json`, `out/run_summary.json`, `out/watchdog.json`, `out/invariants.json` if present.
- Extracts primary failure signature + key fields.
- Emits a compact summary markdown.

## Fallback (if script missing)

1) Find the extracted diag folder.
2) Inspect key JSONs:

```powershell
Get-Content -Path <diag>\meta.json -TotalCount 200
Get-Content -Path <diag>\out\run_summary.json -TotalCount 200
Get-Content -Path <diag>\out\watchdog.json -TotalCount 200
Get-Content -Path <diag>\out\invariants.json -TotalCount 200
```

3) Grab log tails if present:

```powershell
Get-Content -Path <diag>\logs\player.log -Tail 200
Get-Content -Path <diag>\logs\stdout.log -Tail 200
Get-Content -Path <diag>\logs\stderr.log -Tail 200
```

## Inputs

- `-DiagRoot` should point at a **result folder** containing `meta.json` + `out/` (e.g., `.../buildbox_diag_* /results/result_*`).
- `-OutFile` (markdown path for summary)

## Resources

### scripts/
- `diag_summarize_wrapper.ps1`
