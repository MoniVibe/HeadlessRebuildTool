# Headless Docs Index (Current vs Legacy)

## CURRENT (Tonight)
- EngineerTick (Windows PowerShell) is the engineer loop that creates branches/commits and builds artifacts.
- WSL runner consumes jobs and produces result zips.
- ML analyzer (sidecar) runs inside the WSL runner: `Polish/ML/analyze_run.py`.
- Nightly pattern: Sentinel once (FTL) + one concept goal (ARC) cycles.
- Outputs to check:
  - `C:\polish\queue\reports\engineer_tick_v1_*.md`
  - `C:\polish\queue\results\result_*.zip`
  - `C:\polish\queue\reports\nightly_cycle_*.json` and `nightly_timeline.log`
  - Run analysis: `out/run_summary.json`, `out/polish_score_v0.json` inside result zips

## LEGACY / Reference
- These docs are still useful for background: scenarios, assets, WSL-only loops.
- They are not the nightly driver now (EngineerTick + queue + runner is).

## Golden Rules
- Disk gate: do not build if C: free < 40 GB.
- Retention cleanup after every cycle (queue, staging, inspect, worktrees).
- Single-variable rule: do not change scenario and code in the same cycle.
- Chain-of-custody: commit in artifact manifest must match result meta.

## Links
- `Polish/Docs/NIGHTLY_PROTOCOL.md`
- `Polish/Docs/MORNING_VIEW.md`
- `Polish/Docs/DEPENDENCY_POLICY.md`
- `Polish/Docs/ANVILOOP_RECURRING_ERRORS.md`
- `Polish/ML/analyze_run.py`
