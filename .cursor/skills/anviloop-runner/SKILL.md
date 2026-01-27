---
name: anviloop-runner
description: Start and verify the Anviloop WSL runner and ML sidecar summarizer, plus run the Morning View checklist for nightly headless runs. Use when the user mentions Anviloop, WSL runner, queue paths, nightly runs, scoreboard, or morning view.
---

# Anviloop Runner Ops

## Quick Start

- WSL only runs headless Linux players plus the queue consumer (no Unity Editor).
- Canonical runner command:
  - `./Polish/WSL/wsl_runner.sh --queue /mnt/c/polish/queue --daemon --print-summary --requeue-stale-leases --ttl-sec 600`
- Default workdir: `~/polish/runs`
- Logs typically: `/home/oni/polish/wsl_runner.log`
- Windows watch daemons auto-enqueue jobs when new artifacts land:
  - `pwsh -NoProfile -File C:/Dev/unity_clean/headlessrebuildtool/Polish/pipeline_watch_daemon.ps1 -Title space4x`
  - `pwsh -NoProfile -File C:/Dev/unity_clean/headlessrebuildtool/Polish/pipeline_watch_daemon.ps1 -Title godgame`

## Paths (WSL + Windows)

- Queue root: `/mnt/c/polish/queue`
- Artifacts: `/mnt/c/polish/queue/artifacts/artifact_<build_id>.zip`
- Results: `/mnt/c/polish/queue/results/result_<job_id>.zip`
- Runner tools repo: `/home/oni/headless/HeadlessRebuildTool`
- WSL runner script: `/home/oni/headless/HeadlessRebuildTool/Polish/WSL/wsl_runner.sh`
- ML summarizer script: `/home/oni/headless/HeadlessRebuildTool/Polish/ML/analyze_run.py`
- Queue status snapshot: `C:/polish/queue/reports/queue_status.md`
- Watch state (per title): `C:/polish/queue/reports/watch_state_<title>.json`

## Runner Workflow

1. Ensure only one runner is active (avoid parallel runners).
2. Start the runner with the canonical command.
3. Start the Windows watch daemons (space4x/godgame) to auto-enqueue from artifacts.
4. If the queue is empty, the runner may stay silent; this is expected.
5. Keep Windows writing jobs and artifacts to `/mnt/c/polish/queue` while WSL consumes.

## ML Sidecar Summarizer

- Per-run invocation:
  - `python3 Polish/ML/analyze_run.py --meta <run>/meta.json --outdir <run>/out`
- Current sidecar behavior: a simple loop that watches `/home/oni/headless/runs/*` and invokes the script when a new run appears.

## Quick Status

- Run `pwsh -NoProfile -File C:/Dev/unity_clean/headlessrebuildtool/Polish/queue_status.ps1`
- Read `C:/polish/queue/reports/queue_status.md` for the latest artifact/job/result.

## Morning View Checklist

Use this order to decide next actions quickly:

1. `C:/polish/queue/reports/nightly_headline_YYYYMMDD.md`
2. `C:/polish/queue/reports/scoreboard.json`
3. `C:/polish/queue/reports/intel/explain_<job_id>.json`
4. `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/ANVILOOP_RECURRING_ERRORS.md`

## References

- `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/HEADLESS_DOCS_INDEX.md`
- `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/NIGHTLY_PROTOCOL.md`
- `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/MORNING_VIEW.md`
