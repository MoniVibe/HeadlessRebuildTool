---
name: nightly-runner-orchestrator
description: Use when you want to start the full run_nightly end-to-end loop for one or both titles and emit nightly summaries; dont use when debugging a completed run, doing one-off dispatch, or enqueuing a single artifact; outputs nightly summary json, triage paths, and optional intel/scoreboard sidecar results.
---

# Nightly Runner Orchestrator

Run the integrated nightly loop script with explicit queue roots.

## Procedure
1. Set Unity executable via env or argument.
```powershell
$unityExe = if ($env:UNITY_EXE) { $env:UNITY_EXE } elseif ($env:UNITY_WIN) { $env:UNITY_WIN } else { "<set-unity-exe>" }
```
2. Set queue roots explicitly.
```powershell
$space4xQueue = "C:\polish\anviloop\space4x\queue"
$godgameQueue = "C:\polish\anviloop\godgame\queue"
```
3. Run nightly for both titles.
```powershell
pwsh -NoProfile -File Polish/run_nightly.ps1 `
  -UnityExe $unityExe `
  -Title both `
  -QueueRootSpace4x $space4xQueue `
  -QueueRootGodgame $godgameQueue `
  -Repeat 10 `
  -WaitTimeoutSec 1800
```
4. Review outputs under each queue report directory:
  - `nightly_<date>_<title>.json`
  - listed `triage=` lines

## Outputs And Success Criteria
- Nightly summary file is written in `<queueRoot>\reports\`.
- Each run entry contains build id, expected jobs, and exit reason counts.
- Triage paths are printed for non-success outcomes.
- If intel sidecar succeeds, ingest/headline status appears in summary.

## Common Failures - What To Check Next
- Unity exe missing: pass `-UnityExe` or set `UNITY_EXE`/`UNITY_WIN`.
- Queue root wrong for title: verify per-title queue roots before launch.
- `pipeline_smoke` failures: inspect triage paths and recurring error ledger.
- Missing intel/scoreboard outputs: verify WSL distro and `-WslRepoRoot` path.

## Negative Examples
- Do not call this skill when the user only wants to enqueue from an existing artifact.
- Do not call this skill when the user only wants lock claim/release operations.
- Do not call this skill when buildbox dispatch is the requested action.

## Receipt (Required)
Write the standardized receipt after orchestrator completion.
```powershell
pwsh -NoProfile -File .agents/skills/_shared/scripts/write_skill_receipt.ps1 `
  -SkillSlug nightly-runner-orchestrator `
  -Status pass `
  -Reason "nightly loop completed" `
  -InputsJson '{"title":"both","repeat":10}' `
  -CommandsJson '["Polish/run_nightly.ps1"]' `
  -PathsConsumedJson '["Polish/pipeline_smoke.ps1","Polish/pipeline_enqueue.ps1"]' `
  -PathsProducedJson '[".agents\\skills\\artifacts\\nightly-runner-orchestrator\\latest_manifest.json",".agents\\skills\\artifacts\\nightly-runner-orchestrator\\latest_log.md"]'
```

## References
- `references/nightly-outputs.md`

