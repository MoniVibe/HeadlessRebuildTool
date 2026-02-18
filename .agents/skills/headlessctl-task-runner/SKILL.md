---
name: headlessctl-task-runner
description: Use when running canonical headless tasks or validating task contracts through headlessctl with machine-checkable JSON outputs; dont use when dispatching GitHub workflows or cleaning queues; outputs run JSON with run_id plus artifacts under TRI_STATE_DIR/runs and optional validation summaries.
---

# Headlessctl Task Runner

Run canonical tasks and keep outputs machine-checkable.

## Procedure
1. Set roots via environment variables (no machine-specific paths).
```powershell
if (-not $env:TRI_ROOT) { throw "Set TRI_ROOT to your Tri workspace root." }
if (-not $env:TRI_STATE_DIR) { $env:TRI_STATE_DIR = Join-Path $env:TRI_ROOT ".tri\state" }
$env:HEADLESS_REBUILD_TOOL_ROOT = (Get-Location).Path
```
2. Run a task and capture JSON result.
```powershell
$run = python Tools/Headless/headlessctl.py run_task S0.SPACE4X_SMOKE --seed 77 --pack nightly-default | ConvertFrom-Json
$run
```
3. Inspect run artifacts using `run_id`.
```powershell
Get-Content "$env:TRI_STATE_DIR\runs\$($run.run_id)\result.json"
```
4. Run contract validation when requested.
```powershell
python Tools/Headless/headlessctl.py validate
```
5. Use metric commands for comparisons.
```powershell
python Tools/Headless/headlessctl.py get_metrics <run_id>
python Tools/Headless/headlessctl.py diff_metrics <base_run_id> <candidate_run_id>
```

## Outputs And Success Criteria
- `run_task` emits one JSON line with `ok`, `error_code`, and `run_id`.
- `result.json` exists under `$TRI_STATE_DIR/runs/<run_id>/`.
- Metrics and invariants artifacts exist and are non-empty for successful runs.
- `validate` returns overall `ok=true` for healthy contracts.

## Common Failures - What To Check Next
- `build_locked`: inspect `$TRI_STATE_DIR\ops\locks\build.lock` and avoid parallel build/run contention.
- `tasks_missing` or unknown task id: verify `Tools/Headless/headless_tasks.json`.
- Binary missing: confirm `Tools/builds/<project>/Linux_latest/*_Headless.x86_64` exists and is executable in lane.
- `telemetry.truncated` or invariant failures: rerun with pack/env adjustments and record failure signature.

## Negative Examples
- Do not call this skill when the user asks to dispatch `buildbox_on_demand.yml`.
- Do not call this skill when the user asks only for queue retention cleanup.
- Do not call this skill when the user asks to summarize a downloaded diag artifact.

## Receipt (Required)
Write the standardized receipt after each run or validation pass.
```powershell
pwsh -NoProfile -File .agents/skills/_shared/scripts/write_skill_receipt.ps1 `
  -SkillSlug headlessctl-task-runner `
  -Status pass `
  -Reason "headlessctl task completed" `
  -InputsJson '{"task_id":"S0.SPACE4X_SMOKE","seed":77,"pack":"nightly-default"}' `
  -CommandsJson '["Tools/Headless/headlessctl.py run_task"]' `
  -PathsConsumedJson '["Tools/Headless/headless_tasks.json","Tools/Headless/headless_packs.json"]' `
  -PathsProducedJson '[".agents\\skills\\artifacts\\headlessctl-task-runner\\latest_manifest.json",".agents\\skills\\artifacts\\headlessctl-task-runner\\latest_log.md"]'
```

## References
- `references/tasks-and-packs.md`

