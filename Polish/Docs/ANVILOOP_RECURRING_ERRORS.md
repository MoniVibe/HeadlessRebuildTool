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

## Entries (ERR-*)

ERR-20260122-001
- FirstSeen: 2026-01-22
- Symptom: Start-Process redirect error when stdout/stderr point to the same file.
- Signature: RedirectStandardOutput and RedirectStandardError are same.
- RootCause: Windows PowerShell forbids redirecting stdout and stderr to the same path.
- Fix: split stdout and stderr into separate files.
- Prevention: guard that asserts output/error paths differ before launch.
- Verification: commit 92fd2bf (stdout/stderr split in EngineerTick).
- Commit: 92fd2bf

ERR-20260122-002
- FirstSeen: 2026-01-22
- Symptom: pipeline_smoke parameter binding fails when Unity path contains spaces.
- Signature: Cannot convert value "C:\Program Files\Unity\Hub\Editor\6000.3.1f1\Editor\Unity.exe" to type System.Int32.
- RootCause: Start-Process tokenization without quoting whitespace arguments.
- Fix: quote args before Start-Process (UnityExe remains a single argument).
- Prevention: Quote-IfNeeded for every Start-Process argument.
- Verification: artifact zip `C:\polish\queue\artifacts\artifact_20260122_075109_330_ae9de3ca.zip`.
- Commit: 4f51501

ERR-20260122-003
- FirstSeen: 2026-01-22
- Symptom: Aborting batchmode another Unity instance is running with this project open.
- Signature: Aborting batchmode due to fatal error: It looks like another Unity instance is running with this project open.
- RootCause: orphan Unity processes or stale lockfiles.
- Fix: project-scoped mutex + kill Unity for same project path + lockfile cleanup.
- Prevention: singleflight + preflight vacuum in EngineerTick.
- Verification: TBD
- Commit: 578d649

ERR-20260122-004
- FirstSeen: 2026-01-22
- Symptom: PureDOTS package path missing in worktree builds.
- Signature: PureDOTS package.json missing in worktree junction.
- RootCause: missing junction to local PureDOTS repo in worktree.
- Fix: auto-create junction to C:\Dev\unity_clean\puredots in worktree.
- Prevention: ensure junction exists before Unity launch.
- Verification: TBD
- Commit: 56331f5

ERR-20260122-005
- FirstSeen: 2026-01-22
- Symptom: Bee build stalls / Require frontend run / BeeDriver connection terminated.
- Signature: Require frontend run. Library/Bee/*.dag couldn't be loaded OR BeeDriver connection terminated.
- RootCause: Bee cache corruption or interrupted build cache state.
- Fix: clean worktree Bee/ScriptAssemblies/Temp BeeArtifacts before build.
- Prevention: per-worktree cache cleanup when Bee/Tundra stall detected.
- Verification: TBD
- Commit: 9c4913b

ERR-20260122-006
- FirstSeen: 2026-01-22
- Symptom: build logs show stale Editor.log instead of per-run logFile.
- Signature: missing unity_full_<build_id>.log content for current run.
- RootCause: Unity invoked without per-run -logFile or log capture order wrong.
- Fix: force -logFile per run and copy global logs as backup.
- Prevention: require per-run logFile in supervisor.
- Verification: TBD
- Commit: TBD

ERR-20260122-007
- FirstSeen: 2026-01-22
- Symptom: build fails with ScriptCompilation recompile flag.
- Signature: PRIMARY_ERROR: [ScriptCompilation] Requested script compilation because: InitialRefresh: Force Refresh Recompile flag enabled
- RootCause: TBD
- Fix: TBD
- Prevention: TBD
- Verification: TBD
- Commit: TBD

ERR-20260122-008
- FirstSeen: 2026-01-22
- Stage: RUNNER
- Symptom: TEST_FAIL space4x_collision_micro seed=7 exit_code=10 runtime_sec=7.0 telemetry_bytes=0 telemetry_summary=missing
- Signature: 9af157abb7a115bb738f99c20bffe635c0fa6bf1bf9a7c21b745b4096e5f6377
- RawSignature: TEST_FAIL|space4x_collision_micro|    "memorysetup-temp-allocator-size-gfx=262144"|exit_code=10
- RootCause: TBD
- Fix: TBD
- Prevention: TBD
- Verification: TBD
- Evidence: /mnt/c/polish/queue/results/result_20260121_101755_201_b3ade9f0_space4x_collision_micro_7.zip (meta.json, out/watchdog.json, out/run_summary.json)
- Commit: TBD

ERR-20260122_102459
- FirstSeen: 2026-01-22
- Symptom: [Space4XHeadlessBuilder] Build failed. Details written to C:\polish\queue\artifacts\staging_20260122_093123_022_b67ce739_20260122_093127\build\Space4X_HeadlessBuildFailure.log
- Signature: [Space4XHeadlessBuilder] Build failed. Details written to C:\polish\queue\artifacts\staging_20260122_093123_022_b67ce739_20260122_093127\build\Space4X_HeadlessBuildFailure.log
- RootCause: TBD
- Fix: TBD
- Prevention: TBD
- Verification: TBD
- Commit: TBD

ERR-20260122_112718
- FirstSeen: 2026-01-22
- Symptom: DisplayProgressNotification: Build Failed
- Signature: DisplayProgressNotification: Build Failed
- RootCause: TBD
- Fix: TBD
- Prevention: TBD
- Verification: TBD
- Commit: TBD

ERR-20260122-009
- FirstSeen: 2026-01-22
- Symptom: Player build fails with PPtr cast errors during script-only build.
- Signature: PPtr cast failed when dereferencing! Casting from Texture2D to MonoScript.
- RootCause: TBD
- Fix: TBD
- Prevention: TBD
- Verification: TBD
- Commit: TBD
