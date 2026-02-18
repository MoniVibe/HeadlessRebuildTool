---
name: nightly-preflight-guard
description: Use when starting a nightly or buildbox loop and you need disk, lock, queue, and environment preflight checks; dont use when you are already triaging a finished run artifact; outputs a pass or fail checklist with blocking reasons and next action.
---

# Nightly Preflight Guard

Run this before dispatching new runs.

## Procedure
1. Check disk gate and stop if `C_free_GB < 40`.
```powershell
pwsh -NoProfile -Command "'C_free_GB=' + [math]::Round((Get-PSDrive C).Free/1GB,1)"
```
2. Audit Buildbox workflow and runner health.
```powershell
pwsh -NoProfile -File scripts/buildbox_sync_audit.ps1
```
3. Run desktop preflight guard checks.
```powershell
pwsh -NoProfile -File Polish/Ops/preflight_guard.ps1
```
4. Set queue roots explicitly, then snapshot status.
```powershell
$space4xQueue = "C:\polish\anviloop\space4x\queue"
$godgameQueue = "C:\polish\anviloop\godgame\queue"
pwsh -NoProfile -File Polish/queue_status.ps1 -QueueRoot $space4xQueue
pwsh -NoProfile -File Polish/queue_status.ps1 -QueueRoot $godgameQueue
```
5. Check for active session/nightly locks.
```powershell
python Tools/Headless/headlessctl.py show_session_lock
if ($env:TRI_STATE_DIR -and (Test-Path "$env:TRI_STATE_DIR\ops\locks\nightly.lock")) {
  Get-Content "$env:TRI_STATE_DIR\ops\locks\nightly.lock"
}
```

## Outputs And Success Criteria
- Disk gate passes (`C_free_GB >= 40`).
- `preflight_guard: PASS` is present.
- No blocking lock is active, or lock owner/purpose is known and intentional.
- Queue status files are written and readable for both titles.

## Common Failures - What To Check Next
- `GitHub CLI (gh) not found`: install/login `gh`, then rerun `scripts/buildbox_sync_audit.ps1`.
- `preflight_guard: FAIL`: fix listed guardrails first (Unity path, wsl runner cmd path, telemetry flag).
- Disk below gate: run cleanup skill before dispatching any build.
- Unknown lock owner: inspect `$TRI_STATE_DIR\ops\locks\` and avoid starting a second nightly loop.

## Negative Examples
- Do not call this skill when the user asks to inspect one specific finished `result_*.zip`.
- Do not call this skill when the user asks to implement gameplay code changes.
- Do not call this skill when the user asks to only trigger one buildbox run immediately.

## Receipt (Required)
Write the standardized receipt after preflight.
```powershell
pwsh -NoProfile -File .agents/skills/_shared/scripts/write_skill_receipt.ps1 `
  -SkillSlug nightly-preflight-guard `
  -Status pass `
  -Reason "preflight checks passed" `
  -InputsJson '{"queue_roots":["C:\\polish\\anviloop\\space4x\\queue","C:\\polish\\anviloop\\godgame\\queue"]}' `
  -CommandsJson '["scripts/buildbox_sync_audit.ps1","Polish/Ops/preflight_guard.ps1","Polish/queue_status.ps1"]' `
  -PathsConsumedJson '["Polish/Docs/NIGHTLY_PROTOCOL.md"]' `
  -PathsProducedJson '[".agents\\skills\\artifacts\\nightly-preflight-guard\\latest_manifest.json",".agents\\skills\\artifacts\\nightly-preflight-guard\\latest_log.md"]'
```

## References
- `references/checklist.md`

