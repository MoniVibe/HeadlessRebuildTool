---
name: buildbox-dispatch
description: Use when you need to dispatch buildbox_on_demand workflow runs for space4x or godgame and capture run ids for follow-up; dont use when you need local fallback execution or post-run diagnostics only; outputs enqueue metadata (run_id, run_url, status) and the exact dispatch inputs used.
---

# Buildbox Dispatch

Dispatch remote runs with explicit refs and scenario inputs.

## Procedure
1. Run preflight guard checks first and stop on any failure.
```powershell
pwsh -NoProfile -File Polish/Ops/preflight_guard.ps1
```
2. Confirm workflow/runners are reachable before dispatch.
```powershell
pwsh -NoProfile -File scripts/buildbox_sync_audit.ps1
```
3. Trigger a normal on-demand run.
```powershell
pwsh -NoProfile -File scripts/trigger_buildbox.ps1 `
  -Title space4x `
  -Ref <remote-ref> `
  -Repeat 1 `
  -WaitForResult
```
4. Trigger bug-hunt suite when the request is scenario-micro hunting.
```powershell
pwsh -NoProfile -File Polish/Ops/bug_hunt_suite.ps1 `
  -Title space4x `
  -Ref <remote-ref> `
  -PuredotsRef <puredots-remote-ref> `
  -FastFirst
```
5. Capture `run_id` and `run_url` from output for downstream triage.

## Outputs And Success Criteria
- `enqueue_request ...` line includes requested inputs.
- `run_id=<id>` and `run_url=<url>` are printed.
- If waiting, workflow ends with terminal status and non-error exit.

## Common Failures - What To Check Next
- `gh not found` or auth failure: run `gh auth login`, then retry.
- Ref mismatch/not found: verify the branch exists on remote and is pushed.
- Run stuck queued: rerun `scripts/buildbox_sync_audit.ps1` and check runner labels/status.
- Wrong scenario/queue input: confirm `-ScenarioRel` and `-QueueRoot` values passed to trigger script.

## Negative Examples
- Do not call this skill when the user asks to summarize a finished run artifact.
- Do not call this skill when the user asks for local emergency execution with `-AllowLocalBuild`.
- Do not call this skill when the user asks to clean queue retention only.

## Receipt (Required)
Write the standardized receipt after dispatch.
```powershell
pwsh -NoProfile -File .agents/skills/_shared/scripts/write_skill_receipt.ps1 `
  -SkillSlug buildbox-dispatch `
  -Status pass `
  -Reason "workflow dispatched" `
  -InputsJson '{"title":"space4x","ref":"<remote-ref>"}' `
  -CommandsJson '["Polish/Ops/preflight_guard.ps1","scripts/buildbox_sync_audit.ps1","scripts/trigger_buildbox.ps1"]' `
  -PathsConsumedJson '["Polish/Ops/preflight_guard.ps1","scripts/buildbox_sync_audit.ps1","scripts/trigger_buildbox.ps1"]' `
  -PathsProducedJson '[".agents\\skills\\artifacts\\buildbox-dispatch\\latest_manifest.json",".agents\\skills\\artifacts\\buildbox-dispatch\\latest_log.md"]'
```

## References
- `references/dispatch-matrix.md`

