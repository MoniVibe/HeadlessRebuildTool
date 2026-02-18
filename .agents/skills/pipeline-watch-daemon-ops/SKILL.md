---
name: pipeline-watch-daemon-ops
description: Use when managing pipeline_watch_daemon lifecycle for a title and queue root (status, start, stop, ensure single instance); dont use for generic enqueue operations or run-level failure diagnosis; outputs daemon process status plus deterministic start-stop logs.
---

# Pipeline Watch Daemon Ops

Manage daemon lifecycle only.

## Procedure
1. Set title and queue root explicitly.
```powershell
$title = "space4x"
$queueRoot = "C:\polish\anviloop\space4x\queue"
```
2. Check daemon status.
```powershell
pwsh -NoProfile -File .agents/skills/pipeline-watch-daemon-ops/scripts/manage_watch_daemon.ps1 `
  -Action status `
  -Title $title `
  -QueueRoot $queueRoot
```
3. Ensure exactly one instance is running.
```powershell
pwsh -NoProfile -File .agents/skills/pipeline-watch-daemon-ops/scripts/manage_watch_daemon.ps1 `
  -Action ensure `
  -Title $title `
  -QueueRoot $queueRoot `
  -PollSeconds 15
```
4. Stop daemon when needed.
```powershell
pwsh -NoProfile -File .agents/skills/pipeline-watch-daemon-ops/scripts/manage_watch_daemon.ps1 `
  -Action stop `
  -Title $title `
  -QueueRoot $queueRoot
```

## Outputs And Success Criteria
- `status` prints `running_count` and process ids.
- `start`/`ensure` prints `started_pid` or `already_running_pid`.
- `stop` prints stopped process ids and ends with `running_count=0`.
- Stdout/stderr logs are written under `.agents/skills/artifacts/pipeline-watch-daemon-ops/`.

## Common Failures - What To Check Next
- Daemon script missing: verify `Polish/pipeline_watch_daemon.ps1`.
- Multiple instances detected repeatedly: run `-Action ensure`, then check for external schedulers creating duplicates.
- Queue not progressing: validate queue root path and confirm enqueue skill is populating jobs.
- Access denied on stop: rerun in shell with process ownership privileges.

## Negative Examples
- Do not call this skill when user asks to enqueue a specific artifact manually.
- Do not call this skill when user asks to triage `result_*.zip` evidence.
- Do not call this skill when user asks to dispatch GitHub buildbox workflow.

## Receipt (Required)
Write the standardized receipt after lifecycle actions.
```powershell
pwsh -NoProfile -File .agents/skills/_shared/scripts/write_skill_receipt.ps1 `
  -SkillSlug pipeline-watch-daemon-ops `
  -Status pass `
  -Reason "daemon lifecycle action complete" `
  -InputsJson '{"title":"space4x","queue_root":"C:\\polish\\anviloop\\space4x\\queue","action":"ensure"}' `
  -CommandsJson '[".agents/skills/pipeline-watch-daemon-ops/scripts/manage_watch_daemon.ps1"]' `
  -PathsConsumedJson '["Polish/pipeline_watch_daemon.ps1"]' `
  -PathsProducedJson '[".agents\\skills\\artifacts\\pipeline-watch-daemon-ops\\latest_manifest.json",".agents\\skills\\artifacts\\pipeline-watch-daemon-ops\\latest_log.md"]'
```

## References
- `references/daemon-lifecycle.md`

