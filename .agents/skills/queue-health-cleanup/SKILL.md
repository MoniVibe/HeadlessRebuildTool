---
name: queue-health-cleanup
description: Use when the task is queue health or retention cleanup for a specific queue root and disk pressure control; dont use for run-level failure diagnosis, workflow dispatch, or artifact triage; outputs queue status snapshots and cleanup reclaim metrics with dry-run then apply evidence.
---

# Queue Health Cleanup

Inspect queue health first, then clean retention safely.

## Procedure
1. Choose queue root explicitly.
```powershell
$queueRoot = "C:\polish\anviloop\space4x\queue"
```
2. Generate queue status snapshots.
```powershell
pwsh -NoProfile -File Polish/queue_status.ps1 -QueueRoot $queueRoot
```
3. Run dry-run cleanup and inspect delete candidates.
```powershell
pwsh -NoProfile -File Polish/cleanup_queue.ps1 `
  -QueueRoot $queueRoot `
  -RetentionDays 7 `
  -KeepLastPerScenario 3
```
4. Apply cleanup only after reviewing dry-run totals.
```powershell
pwsh -NoProfile -File Polish/cleanup_queue.ps1 `
  -QueueRoot $queueRoot `
  -RetentionDays 7 `
  -KeepLastPerScenario 3 `
  -Apply
```
5. Re-run queue status after apply to confirm health.

## Outputs And Success Criteria
- `queue_status_written path=...` exists for each queue root.
- Dry-run reports expected delete candidates and reclaim size.
- Apply run prints deleted file count and reclaimed bytes.
- Latest artifacts/results remain intact for active scenarios.

## Common Failures - What To Check Next
- `QueueRoot does not exist`: verify queue root path and title-specific queue location.
- Unexpectedly high delete counts: rerun without `-Apply` and lower retention aggressiveness.
- Disk still below gate after cleanup: trim staging/inspect/worktree directories per nightly protocol.
- Missing latest artifact/result after cleanup: restore from backup, then tighten keep policy.

## Negative Examples
- Do not call this skill when the user asks to enqueue a new buildbox run.
- Do not call this skill when the user asks to inspect one specific `result_*.zip` deeply.
- Do not call this skill when the user asks to run headless tasks through `headlessctl`.

## Receipt (Required)
Write the standardized receipt after status/cleanup pass.
```powershell
pwsh -NoProfile -File .agents/skills/_shared/scripts/write_skill_receipt.ps1 `
  -SkillSlug queue-health-cleanup `
  -Status pass `
  -Reason "queue cleanup complete" `
  -InputsJson '{"queue_root":"C:\\polish\\anviloop\\space4x\\queue","retention_days":7,"keep_last_per_scenario":3}' `
  -CommandsJson '["Polish/queue_status.ps1","Polish/cleanup_queue.ps1"]' `
  -PathsConsumedJson '["C:\\polish\\anviloop\\space4x\\queue"]' `
  -PathsProducedJson '[".agents\\skills\\artifacts\\queue-health-cleanup\\latest_manifest.json",".agents\\skills\\artifacts\\queue-health-cleanup\\latest_log.md"]'
```

## References
- `references/queue-paths.md`

