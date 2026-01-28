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

ERR-20260128-001
- FirstSeen: 2026-01-28
- Stage: RUNNER
- Symptom: TEST_FAIL godgame_smoke seed=42 exit_code=10; telemetry missing.
- Signature: ef6333bb8a141c03774ae0bdfb2e552c27f2f5bb154199efe94cfaf7fa9c67fc
- RawSignature: TEST_FAIL|godgame_smoke|    "memorysetup-temp-allocator-size-gfx=262144"|exit_code=10
- RootCause: TBD (no invariants; telemetry missing; stdout tail is memory config).
- Fix: TBD (identify exit-request source; add explicit exit logging).
- Prevention: Always capture player.log tail and include exit-request source in diagnostics.
- Verification: TBD
- Evidence: C:\polish\queue\reports\_diag_downloads\21449057793\buildbox_diag_godgame_21449057793\results\result_20260128_174031_042_b6c656ba_godgame_smoke_42 (meta/run_summary/watchdog)
- Commit: TBD

ERR-20260128-002
- FirstSeen: 2026-01-28
- Stage: RUNNER
- Symptom: Scenario file not found; ScenarioEntryPoint exits with exit_code=1 despite job scenario_rel.
- Signature: Scenario file not found (space4x_collision_micro / godgame_smoke).
- RawSignature: TEST_FAIL|*|    "memorysetup-temp-allocator-size-gfx=262144"|exit_code=10
- RootCause: scenario_arg resolves to scenario_id instead of an absolute path in WSL runner.
- Fix: Ensure scenario_rel is resolved to an absolute path (fallback map + repo_root); validate and log scenario_arg_value before launch.
- Prevention: Always log scenario_arg_value and fail fast if scenario_path_missing.
- Verification: TBD (rerun shows ScenarioEntryPoint uses resolved path, exit_code!=1).
- Evidence: C:\polish\queue\reports\_diag_downloads\21451850412\buildbox_diag_space4x_21451850412\results\result_20260128_190740_990_257a38e6_space4x_collision_micro_7\out\player.log (Scenario not found)
- Evidence: C:\polish\queue\reports\_diag_downloads\21452652903\buildbox_diag_godgame_21452652903\results\result_20260128_193321_093_3974b046_godgame_smoke_42\out\player.log (Scenario file not found)
- Commit: 29fa30a

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
- Symptom: TEST_FAIL space4x_collision_micro seed=7 exit_code=10 (also seen as space4x seed=7)
- Signature: 9af157abb7a115bb738f99c20bffe635c0fa6bf1bf9a7c21b745b4096e5f6377
- RawSignature: TEST_FAIL|space4x_collision_micro|    "memorysetup-temp-allocator-size-gfx=262144"|exit_code=10
- RootCause: TBD (exit_code=10 persists; telemetry missing; no invariants; DigGate now opt-in and not firing).
- Fix: TBD (add explicit exit-request logging to identify which system requests TestFailExitCode).
- Prevention: Always capture player.log tail in diagnostics and include exit-request source in logs.
- Verification: Repro persists: buildbox run 21450290817 commit 2ecc8ae exit_code=10, telemetry missing, no invariants.
- Evidence: /mnt/c/polish/queue/results/result_20260121_101755_201_b3ade9f0_space4x_collision_micro_7.zip (meta.json, out/watchdog.json, out/run_summary.json)
- Evidence: build_id=20260128_061826_349_29972412 (meta.json, out/watchdog.json, out/run_summary.json) from buildbox_diag_space4x_21427439803
- Evidence: build_id=20260128_181831_329_2ecc8ae8 (meta.json, out/watchdog.json, out/run_summary.json) from buildbox_diag_space4x_21450290817
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

ERR-20260122_142658
- FirstSeen: 
2026-01-22
- Symptom: 
Build succeeded
- Signature: 
BUILD_FAIL
- RootCause: TBD
- Fix: TBD
- Prevention: TBD
- Verification: TBD
- Commit: TBD

ERR-20260122-010
- FirstSeen: 2026-01-22
- Symptom: EngineerTick fails pre-build because base ref is missing.
- Signature: fatal: invalid reference: nightly/base_space4x_YYYYMMDD
- RootCause: nightly base ref not created for the day.
- Fix: auto-create/update base ref from origin/main before worktree add.
- Prevention: EngineerTick base ref auto-heal.
- Verification: TBD
- Commit: TBD

ERR-20260122_171250
- FirstSeen: 
2026-01-22
- Symptom: 
Assets\Scripts\Space4x\Headless\Space4XHeadlessDiagnosticsSystem.cs(23,17): error CS0246: The type or namespace name 'float3' could not be found (are you missing a using directive or an assembly reference?)
- Signature: 
Assets\Scripts\Space4x\Headless\Space4XHeadlessDiagnosticsSystem.cs(23,17): error CS0246: The type or namespace name 'float3' could not be found (are you missing a using directive or an assembly reference?)
- RootCause: TBD
- Fix: TBD
- Prevention: TBD
- Verification: TBD
- Commit: TBD

ERR-20260122_183250
- FirstSeen: 
2026-01-22
- Symptom: 
Assets\Scripts\Space4x\Headless\Space4XHeadlessDiagnosticsSystem.cs(70,36): error CS0103: The name 'transform' does not exist in the current context
- Signature: 
Assets\Scripts\Space4x\Headless\Space4XHeadlessDiagnosticsSystem.cs(70,36): error CS0103: The name 'transform' does not exist in the current context
- RootCause: TBD
- Fix: TBD
- Prevention: TBD
- Verification: TBD
- Commit: TBD

ERR-20260122_215913
- FirstSeen: 
2026-01-22
- Symptom: 
[Licensing::Module] Error: Access token is unavailable; failed to update
- Signature: 
[Licensing::Module] Error: Access token is unavailable; failed to update
- RootCause: TBD
- Fix: TBD
- Prevention: TBD
- Verification: TBD
- Commit: TBD

ERR-20260123_095023
- FirstSeen: 
2026-01-23
- Symptom: 
Library\PackageCache\com.unity.test-framework@0b7a23ab2e1d\UnityEngine.TestRunner\NUnitExtensions\Commands\EnumerableMaxTimeCommand.cs(11,47): error CS0246: The type or namespace name 'DelegatingTestCommand' could not be found (are you missing a using directive or an assembly reference?)
- Signature: 
Library\PackageCache\com.unity.test-framework@0b7a23ab2e1d\UnityEngine.TestRunner\NUnitExtensions\Commands\EnumerableMaxTimeCommand.cs(11,47): error CS0246: The type or namespace name 'DelegatingTestCommand' could not be found (are you missing a using directive or an assembly reference?)
- RootCause: TBD
- Fix: TBD
- Prevention: TBD
- Verification: TBD
- Commit: TBD
