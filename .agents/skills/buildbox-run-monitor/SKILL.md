---
name: buildbox-run-monitor
description: Use when you need read-only monitoring of a buildbox run status, diagnostics artifact availability, and recommended next skill; dont use when you need to dispatch, enqueue, or mutate queues; outputs monitor_status.json and monitor_report.md with next-step lane guidance.
---

# Buildbox Run Monitor

Inspect run status only. This skill must not start or enqueue anything.

## Procedure
1. Monitor by run id.
```powershell
pwsh -NoProfile -File .agents/skills/buildbox-run-monitor/scripts/check_buildbox_run_status.ps1 `
  -RunId <github-run-id> `
  -Title space4x
```
2. Or resolve latest run by ref first.
```powershell
pwsh -NoProfile -File .agents/skills/buildbox-run-monitor/scripts/check_buildbox_run_status.ps1 `
  -Ref <remote-ref> `
  -Title space4x
```
3. Read generated outputs:
  - `monitor_status.json`
  - `monitor_report.md`
4. Follow `next_skill` recommendation from monitor output.

## Outputs And Success Criteria
- Script prints `monitor_status=` and `monitor_report=` paths.
- Status file includes run lifecycle state, artifact availability, and `next_skill`.
- No dispatch/enqueue/cleanup side effects occur.

## Common Failures - What To Check Next
- `gh` auth missing: run `gh auth login`.
- Run not found: verify run id/repo/ref and workflow name.
- Artifact list unavailable: rerun after short delay if workflow just completed.
- Ambiguous title/ref: specify `-RunId` directly.

## Negative Examples
- Do not call this skill to trigger buildbox workflows.
- Do not call this skill to enqueue artifact jobs.
- Do not call this skill to analyze deep failure evidence from extracted result bundles.

## Receipt (Required)
Write the standardized receipt after monitor pass.
```powershell
pwsh -NoProfile -File .agents/skills/_shared/scripts/write_skill_receipt.ps1 `
  -SkillSlug buildbox-run-monitor `
  -Status pass `
  -Reason "run status inspected" `
  -InputsJson '{"run_id":"<github-run-id>","title":"space4x"}' `
  -CommandsJson '[".agents/skills/buildbox-run-monitor/scripts/check_buildbox_run_status.ps1"]' `
  -PathsConsumedJson '["GitHub Actions run metadata"]' `
  -PathsProducedJson '[".agents\\skills\\artifacts\\buildbox-run-monitor\\latest_manifest.json",".agents\\skills\\artifacts\\buildbox-run-monitor\\latest_log.md"]'
```

## References
- `references/status-decision.md`

