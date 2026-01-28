# Desktop Buildbox Runbook (Anviloop)

## Required env vars (machine-level)
- TRI_ROOT = <local Tri root> (example: C:\dev\Tri)
- UNITY_EXE = <full path to Unity.exe>
- Optional for BuildStamp: GIT_COMMIT, GIT_BRANCH (buildbox workflow sets these from ref).

## Runner labels
- Required: buildbox
- Optional: headless-e2e (only if you want nightly-evals.yml to run)

## Services + tasks (must auto-restart)
- GitHub Actions runner as Windows service (repo: MoniVibe/HeadlessRebuildTool)
- Scheduled tasks (per title: space4x, godgame):
  - WSL runner daemon
  - Intel sidecar daemon
  - pipeline_watch_daemon.ps1
  - Watchdog (every 2 minutes + at startup)

## Queue roots (desktop)
- C:\polish\anviloop\space4x\queue
- C:\polish\anviloop\godgame\queue
- Logs: C:\polish\anviloop\logs

## Quick health checks
- Runner service running
- WSL runner produces results in queue\results
- pipeline_watch_daemon is enqueueing jobs when artifacts appear
- Buildbox workflow dispatch runs (no "queued" stall unless runner is offline)

## Trigger build from laptop
- GitHub Actions: Buildbox: on-demand rebuild + headless sim
- Inputs: title + ref + repeat

## If nightly-evals stays queued
- Ensure runner has label headless-e2e OR change nightly-evals.yml to buildbox.
