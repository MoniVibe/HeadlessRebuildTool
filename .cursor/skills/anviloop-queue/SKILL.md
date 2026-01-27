---
name: anviloop-queue
description: Manage Anviloop queue paths, artifacts/results, cleanup, and basic queue health checks. Use when handling queue issues, retention, or path questions.
---

# Anviloop Queue Ops

## Paths

- Queue root: `/mnt/c/polish/queue` (WSL) and `C:/polish/queue` (Windows)
- Artifacts: `C:/polish/queue/artifacts/artifact_<build_id>.zip`
- Results: `C:/polish/queue/results/result_<job_id>.zip`

## Health checks

- Windows writes jobs and artifacts to the queue root.
- WSL runner consumes from `/mnt/c/polish/queue`.
- Avoid running multiple runners simultaneously.
- Runner silence when queue is empty is expected.

## Cleanup

- Disk gate: `pwsh -NoProfile -Command "'C_free_GB=' + [math]::Round((Get-PSDrive C).Free/1GB,1)"`
- Queue cleanup: `pwsh -NoProfile -File Polish/cleanup_queue.ps1 -QueueRoot "C:/polish/queue" -RetentionDays 7 -KeepLastPerScenario 3 -Apply`

## References

- `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/NIGHTLY_PROTOCOL.md`
