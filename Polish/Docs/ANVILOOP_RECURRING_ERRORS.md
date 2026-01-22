# Anviloop Recurring Errors

## 2026-01-22
- Symptom: Start-Process redirect error when stdout/stderr point to the same file.
  - Root cause: Windows PowerShell forbids RedirectStandardOutput and RedirectStandardError using identical paths.
  - Fix: always split stdout/stderr to different files.
  - Prevention: add a guard that asserts output/error paths differ before launch.
- Other recent pitfalls:
  - Unity project lock: another Unity instance already has the project open.
  - Missing local PureDOTS package path in worktree (junction not created or stale).
  - Bee "Require frontend run" / BeeDriver interrupted build cache.
  - Stale Editor.log vs per-run -logFile (must capture per-run logs).
  - Start-Process argument quoting: -ArgumentList without quoting paths causes UnityExe to bind to wrong parameter (TimeoutSec).
    - Root cause: Start-Process tokenization without quoting whitespace arguments.
    - Fix: quote args before Start-Process (stdout/stderr split).
    - Verification: EngineerTick rerun produced artifact zip `C:\polish\queue\artifacts\artifact_20260122_075109_330_ae9de3ca.zip` (build started).
