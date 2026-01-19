> **What this is**  
> A local-first gameplay CI loop for Unity/DOTS: Windows builds a Linux headless server, WSL runs deterministic scenarios, and each run emits a reproducible result bundle (logs, invariants/progress, triage JSON, and a simple score).
>
> **Support**  
> If this saves you time, you can sponsor development: https://github.com/sponsors/MoniVibe

# Polish Queue + Pipeline Smoke (Windows -> WSL)

## Canonical Queue Root (Windows <-> WSL)
Windows queue root:
- `C:\polish\queue`

WSL view of the same queue root:
- `/mnt/c/polish/queue`

Queue layout (under the root):
- `artifacts/` immutable build zips (`artifact_<build_id>.zip`)
- `jobs/` incoming `*.json` job requests
- `leases/` claimed jobs (WSL runner moves jobs here)
- `results/` published `result_<job_id>.zip` bundles

## Queue retention cleanup (safe-by-default)
Script:
- `Tools/Polish/cleanup_queue.ps1`

Dry-run (default):
```powershell
pwsh -File Tools/Polish/cleanup_queue.ps1 -QueueRoot "C:\polish\queue" -RetentionDays 21 -KeepLastPerScenario 5
```

Apply deletions:
```powershell
pwsh -File Tools/Polish/cleanup_queue.ps1 -QueueRoot "C:\polish\queue" -RetentionDays 21 -KeepLastPerScenario 5 -Apply
```

Notes:
- Keeps the last K result bundles per scenario even if older than the cutoff.
- Artifacts referenced by kept results are preserved.
- Prints estimated reclaim before deletion.

## Path Mapping Rules
- Windows path `C:\polish\queue\...` is read in WSL as `/mnt/c/polish/queue/...`.
- `artifact_uri` in job JSON should use the WSL-visible path:
  - `/mnt/c/polish/queue/artifacts/artifact_<build_id>.zip`
- The WSL runner always unzips artifacts into an ext4 run dir and forces `-logFile`; it does not rely on Unity default logs.

## Job JSON Schema (required fields)
```json
{
  "job_id": "20260108_003012_abcd1234_space4x_smoke_42",
  "commit": "abcd1234",
  "build_id": "20260108_003012_abcd1234",
  "scenario_id": "space4x_smoke",
  "seed": 42,
  "timeout_sec": 120,
  "args": [],
  "param_overrides": {},
  "feature_flags": {},
  "artifact_uri": "/mnt/c/polish/queue/artifacts/artifact_20260108_003012_abcd1234.zip",
  "created_utc": "2026-01-08T00:30:12Z"
}
```

## Per-title Defaults
Config:
- `Tools/Polish/pipeline_defaults.json`

Fields per title:
- `project_path`, `scenario_id`, `seed`, `timeout_sec`, `args`

## Pipeline Smoke Driver
Script:
- `Tools/Polish/pipeline_smoke.ps1`

Examples:
```powershell
pwsh -File Tools/Polish/pipeline_smoke.ps1 -Title space4x -UnityExe "C:\Program Files\Unity\Hub\Editor\6000.3.1f1\Editor\Unity.exe"
pwsh -File Tools/Polish/pipeline_smoke.ps1 -Title godgame -UnityExe "C:\Program Files\Unity\Hub\Editor\6000.3.1f1\Editor\Unity.exe"
```

Override defaults:
```powershell
pwsh -File Tools/Polish/pipeline_smoke.ps1 -Title space4x -UnityExe "C:\Program Files\Unity\Hub\Editor\6000.3.1f1\Editor\Unity.exe" -ScenarioId space4x_mining -Seed 7 -TimeoutSec 180
```

Optional polling for results:
```powershell
pwsh -File Tools/Polish/pipeline_smoke.ps1 -Title space4x -UnityExe "C:\Program Files\Unity\Hub\Editor\6000.3.1f1\Editor\Unity.exe" -WaitForResult
```
