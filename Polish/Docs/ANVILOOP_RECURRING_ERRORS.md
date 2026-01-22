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
