# Orchestrator Script

- `Polish/run_nightly.ps1`

# Main Output Locations

- `<queueRoot>\reports\nightly_<date>_<title>.json`
- `<queueRoot>\reports\expected_jobs.json`
- `<queueRoot>\reports\triage_*.json`

# Inputs To Keep Explicit

- `QueueRootSpace4x`
- `QueueRootGodgame`
- `UnityExe` (or env `UNITY_EXE` / `UNITY_WIN`)
- optional `WslDistro`, `WslRepoRoot`

# Related Docs

- `Polish/Docs/NIGHTLY_PROTOCOL.md`
- `Polish/Docs/MORNING_VIEW.md`
