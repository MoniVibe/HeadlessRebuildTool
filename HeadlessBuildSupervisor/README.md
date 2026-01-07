# Headless Build Supervisor (Windows)

## Purpose
Runs Unity in batchmode with a hard timeout, enforces kill-tree, and publishes an immutable `artifact_<build_id>.zip` that includes build output, manifest, logs, and failure diagnostics.

## Command Line
Example (Space4X):
```
dotnet run --project Tools/HeadlessBuildSupervisor/HeadlessBuildSupervisor.csproj -- ^
  --unity-exe "C:\Program Files\Unity\Hub\Editor\6000.3.1f1\Editor\Unity.exe" ^
  --project-path "C:\dev\Tri\space4x" ^
  --build-id "space4x_20260107_0001" ^
  --commit "abcdef123456" ^
  --artifact-dir "C:\dev\Tri\nightly_artifacts\space4x"
```

Optional flags:
- `--execute-method` (default `Tri.BuildTools.HeadlessLinuxBuild.Build`)
- `--timeout-minutes` (default `30`)
- `--max-retries` (default `1`, only for cache-clean signatures)
- `--default-args` (semicolon or comma separated)
- `--scenarios` (semicolon or comma separated)
- `--notes`
- `--staging-dir` (override staging location)

## Artifact Output
Publishes:
- `artifact_<build_id>.zip` (in `--artifact-dir`)

Contains:
- `build_manifest.json`
- `build/` (Unity Linux server output)
- `logs/unity_build.log`
- `logs/supervisor.log`
- `logs/build_outcome.json`
- `logs/build_report.json` + `logs/build_report.txt`
- `logs/unity_build_tail.txt` (failures)
- `logs/process_snapshot.txt` (failures)
- `logs/crash/` (if crash artifacts exist)
- `failure_reason.txt` (failures)

Note: `build_manifest.json` includes a `content_hashes` entry for itself computed from the manifest content without the self-hash field.

## Validation Plan (20-build reliability test)
- Run 20 consecutive builds with unique `build_id` values.
- Force three failures: a compile error, a missing scene, and an invalid target.
- Pass criteria: every run exits within timeout and publishes `artifact_<build_id>.zip` with `build_manifest.json`, `build_outcome.json`, and logs.
