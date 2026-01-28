# Headless Docs Index (Current)

## CURRENT LOOP (Buildbox + Queue + WSL runner)
- **Primary flow**: push code → trigger `buildbox_on_demand.yml` → desktop buildbox builds artifact (pipeline_smoke) → watch daemons enqueue jobs → WSL runner consumes → result zips + diagnostics artifacts.
- Diagnostics: Buildbox uploads `buildbox_diag_*` artifacts (meta/run_summary/watchdog/log tails). Summarize with `Polish/Ops/diag_summarize.ps1`.
- Intel sidecar ingests result zips and emits explain/score artifacts: `Polish/Intel/anviloop_intel.py`.
- Scoreboard/headline (optional): `Polish/Goals/scoreboard.py`.

## OPTIONAL / SECONDARY
- `nightly-evals.yml` uses runner label `headless-e2e`. If no runner with that label is online, it will stay queued. This is not a failure.
- EngineerTick (laptop) is optional for local smoke; buildbox is the main remote iteration path.

## Fallback (desktop unavailable)
- Local rebuilds are allowed if the desktop runner is offline:
  - Run `Polish/pipeline_smoke.ps1` against the local repo with a small scenario.
  - Use the legacy local queue root (`C:\polish\queue`) to avoid mixing with desktop queues.
  - Expect slower runs; keep seeds low and repeats = 1.

## Key Outputs (where to look)
- Buildbox diagnostics: `C:\polish\queue\reports\_diag_downloads\<run_id>\buildbox_diag_*`
- Diag summaries: `diag_*.md` in the same folder
- Queue results: `C:\polish\anviloop\<title>\queue\results\result_*.zip` (desktop)
- Pipeline logs: `pipeline_smoke.log` artifact from the workflow

## Golden Rules
- Disk gate: do not build if C: free < 40 GB.
- Retention cleanup after each cycle (queue, staging, inspect, worktrees).
- Single-variable rule: do not change scenario and code in the same cycle.
- Chain-of-custody: commit in artifact manifest must match `meta.json` in the result zip.
- VALID vs INVALID: do not tune behavior when evidence is INVALID (missing telemetry/invariants/oracle keys).
- Green-but-meaningless: progress scenarios must have BANK PASS or metric thresholds; smoke is not proof.
- Assets/.meta changes only in approved daytime asset batch; nightly agents only queue requests.

## Paths (current)
- Desktop queue roots: `C:\polish\anviloop\space4x\queue` and `C:\polish\anviloop\godgame\queue`.
- Laptop legacy queue root: `C:\polish\queue` (do not mix with desktop queues).
- WSL runner consumes `/mnt/c/polish/anviloop/<title>/queue`.

## Links
- `Polish/Docs/NIGHTLY_PROTOCOL.md`
- `Polish/Docs/MORNING_VIEW.md`
- `Polish/Docs/DEPENDENCY_POLICY.md`
- `Polish/Docs/ANVILOOP_RECURRING_ERRORS.md`
- `Polish/Docs/ENTITY_SIM_TEMPLATE_CONTRACT.md`
