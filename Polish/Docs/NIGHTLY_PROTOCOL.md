# Nightly Protocol (Current)

## 0) Disk gate + cleanup
- Gate: `pwsh -NoProfile -Command "'C_free_GB=' + [math]::Round((Get-PSDrive C).Free/1GB,1)"` and stop if < 40 GB.
- Queue cleanup (desktop): `pwsh -NoProfile -File Polish/cleanup_queue.ps1 -QueueRoot "C:\polish\anviloop\space4x\queue" -RetentionDays 7 -KeepLastPerScenario 3 -Apply` (repeat for godgame).
- Trim after each cycle: keep `staging_*` last 5, `_inspect` last 10, worktrees last 2.

## 1) Required daemons (desktop buildbox)
- WSL runner (per title): `./Polish/WSL/wsl_runner.sh --queue /mnt/c/polish/anviloop/<title>/queue --daemon --print-summary --status-interval 60`.
- Intel sidecar ingest: `Polish/Intel/anviloop_intel.py` (writes `reports/intel/explain_*.json` and `questions_*.json`).
- Watch daemons (Windows): `Polish/pipeline_watch_daemon.ps1 -Title <title> -QueueRoot C:\polish\anviloop\<title>\queue`.
- Scoreboard/headline (optional): `Polish/Goals/scoreboard.py`.

## 2) Primary execution path (remote)
- **Buildbox on-demand** is the default loop:
  1) Push a branch/SHA.
  2) Trigger `buildbox_on_demand.yml` with `title` + `ref`.
  3) Buildbox runs `pipeline_smoke.ps1`, builds artifact, enqueues jobs.
  4) WSL runner consumes jobs and writes result zips.
  5) Download `buildbox_diag_*` artifacts and summarize with `Polish/Ops/diag_summarize.ps1`.
- Local deck runs are **blocked by default** in `run_deck.ps1`. Use `-AllowLocalBuild` only for emergency local rebuilds.

## 2b) Fallback (desktop unavailable)
- Use local rebuilds only when buildbox is offline.
- Keep runs minimal:
  - `Repeat = 1`, single seed.
  - Prefer `space4x_collision_micro` or `godgame_smoke`.
- Use local queue root: `C:\polish\queue`.
- You must explicitly pass `-AllowLocalBuild` to `run_deck.ps1` when doing this.
- After the run, clean up local staging to avoid disk pressure.

## 3) Optional nightly (CI)
- `nightly-evals.yml` uses runner label `headless-e2e`. If no runner has this label, runs stay queued (expected).
- `unity-tests` job is gated by `UNITY_TESTS_ENABLED == '1'` and is skipped by default.

## 4) Validity gate
- If telemetry is missing/truncated, invariants missing, or required oracle keys missing, mark INVALID and fix instrumentation/infra first.

## 5) Commit/proof policy
- Only keep a commit if a headless proof exists (log or telemetry).
- Mechanic proofs must be real: BANK PASS or validate_metric_keys + thresholds, not just “telemetry exists”.
- Chain-of-custody: commit in artifact manifest must match `meta.json` in the result zip.
- Assets/.meta edits are daytime-only; nightly agents may only queue requests.

## 6) Stop/switch rules
- If the same failure signature repeats twice, stop and consult the ledger.
- If disk drops below the gate, switch to analysis/doc only (no builds).
- Treat `OK_WITH_WARNINGS` as PASS for pipeline health but record counts.

## 7) Where to look for proof
- Buildbox diagnostics: `buildbox_diag_*` artifact (meta/run_summary/watchdog/log tails).
- Queue results: `C:\polish\anviloop\<title>\queue\results\result_*.zip`.
- Intel: `reports/intel/explain_*.json` and `questions_*.json`.
- Ledger: `Polish/Docs/ANVILOOP_RECURRING_ERRORS.md`.

## 8) Principles
- Scenarios stay small/deterministic; the simulation inside them is real and dynamic.
- Primary metrics must be emergent from the sim, not computed by a flat formula.
- Simulation template contract: `Polish/Docs/ENTITY_SIM_TEMPLATE_CONTRACT.md`.
