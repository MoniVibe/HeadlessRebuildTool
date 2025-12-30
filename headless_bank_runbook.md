# Headless Runbook - Build Channels + Test Bank (TRI)

Purpose: keep headless agents productive without rebuild churn and protect a pinned current build by enforcing:
1) two build channels (scratch vs current),
2) a promotion gate (bank green/stable),
3) a test bank (tiered, explicit pass signals).

This runbook applies to PureDOTS + Godgame + Space4X.

## Cross-OS caveats
- Avoid editing `Assets/` or `.meta` from WSL; presentation owns those files.
- Keep `Packages/manifest.json` and `Packages/packages-lock.json` synced across clones when logic changes.
- Headless rebuilds in WSL should use Windows Unity interop (set `FORCE_WINDOWS_UNITY=1`); do not rely on Linux Unity licensing.

## Productivity requirement (non-negotiable)
- Each cycle must attempt at least one headlesstask from `headlesstasks.md`.
- If telemetry already exposes the metric, compute it and update `headlesstasks.md` (status, baseline/threshold, notes).
- If the metric is missing, add minimal telemetry in logic repos (PureDOTS) and rebuild; if it requires `Assets/` or `.meta` edits, log the requirement and switch to another task.
- Do not end a cycle with only bank runs; the bank is gating, not sufficient.

## Compile-error remediation (non-negotiable)
- If a rebuild fails with compiler errors, attempt a minimal, logic-only fix, rebuild scratch, then rerun Tier 0.
- If the compiler errors point to `Assets/` or `.meta` and the agent is running in WSL, log the blocker and switch tasks; do not edit those files from WSL.
- If the agent is running in a Windows/presentation context, it may fix `Assets/` or `.meta` compiler errors before retrying the rebuild.
- Record compile-fix attempts in the cycle log and note any blockers in `headlesstasks.md`.

---

## Build Channels (scratch vs current)

Definitions:
- scratch build: any build produced during the shift
- current build: the pinned build used by others (must remain stable)

Rules:
1) Scratch builds may be rebuilt at will.
2) Do not overwrite current build artifacts with scratch output.
3) Promote scratch -> current only when the bank is green and stable.
4) Promotion gate: Tier 0 passes twice consecutively (same seed), then Tier 1 passes once (or twice if affordable).
5) Two-fail rule for escalation: a failure is actionable only after 2 consecutive FAIL runs (same seed).
6) Keep artifacts for every promoted build (binary + logs + telemetry).

---

## Bank Contract (Non-negotiables)

- Tier 0 is a gate: if any Tier 0 test fails, stop and triage until green before Tier 1/2.
- Two-green rule: a tier is stable only after 2 consecutive PASS runs (same seed).
- Two-fail rule: treat a failure as real only after 2 consecutive FAIL runs (same seed).
- Seed + minimum simSeconds are required for every bank entry; report both after each run.
- Current build is immutable during a shift; scratch builds may be rebuilt at will, but do not promote until the gate passes.
- Prefer changes that can be validated without rebuilding:
  - Scenario JSON (swap/copy into build folder)
  - Environment flags (proof toggles, telemetry level, thresholds)
  - Report/telemetry output paths
- If a proof is incompatible with a scenario, disable it for that scenario and document the reason in the headless proof system.

Telemetry defaults (use unless debugging):
- PUREDOTS_TELEMETRY_LEVEL=summary
- PUREDOTS_TELEMETRY_MAX_BYTES=524288000

---

## Machine-checkable PASS/FAIL contract

Required log markers (exact strings):
- Logs must contain: BANK:<testId>:PASS
- Logs must not contain: BANK:<testId>:FAIL
- Logs must contain exactly one telemetry path line: TELEMETRY_OUT:<path>
- Every BANK line must include: tickTime=<TickTimeState.Tick>, scenarioTick=<ScenarioRunnerTick>, delta=<tickTime-scenarioTick>
stdout is the source of truth for harness parsing; BANK and TELEMETRY_OUT must be written to stdout (not stderr).
Optional: emit TAP ok/not ok lines in addition to BANK markers.

PASS is only when:
- exit code is 0
- required PASS proof lines exist
- no FAIL proof lines
- telemetry file exists, is fresh, and size <= cap

FAIL is when:
- exit code != 0
- any FAIL lines
- missing or stale telemetry
- telemetry exceeds cap (unless explicitly allowed for a deep-dive run)

Note: Proof systems and scenario entry points must emit the BANK and TELEMETRY_OUT lines. If they do not, add them in the headless proof system when batching a rebuild.

---

## Promotion Gate (scratch -> current)

Promote only if:
- Tier 0 is green twice (two-green, same seed), and
- Tier 1 is green once (or twice if affordable).

---

## Failure triage (two-fail rule)

Before escalating a failure or blocking promotion:
1) Re-run the same scenario twice (same seed), confirm failure is repeatable.
2) Confirm proof enable/disable env flags are correct.
3) Confirm scenario spawns required subjects for the proof (villagers/storehouse, mining vessels, strike craft, etc.).
4) Ensure telemetry output is fresh (truncate/rotate between runs).
5) Only then escalate.

Note: authoring/baker/SubScene changes typically require rebuild; scenario/env changes do not.

---

## Scratch rebuild policy

Scratch rebuilds are allowed and encouraged for fast iteration, but:
- never overwrite current build artifacts
- rerun the affected bank tier(s) after each scratch build
- do not promote until the promotion gate is satisfied

Avoid scratch rebuilds during active presentation/editor sessions unless coordinated.

---

## Build stamping + artifact retention

Every scratch build should emit a single stamp line early:
- BUILD_STAMP: sha=<...> utc=<...> unity=<...> bank_rev=<...>

bank_rev should map to the test bank revision (runbook update or version tag).
Keep artifacts for every promoted build (binary + logs + telemetry) for traceability.

---

## Test Bank (tiered)

### Tier 0 - Sanity (gate)

P0.TIME_REWIND_MICRO (PureDOTS / ScenarioRunner)
- Scenario: Packages/com.moni.puredots/Runtime/Runtime/Scenarios/Samples/headless_time_rewind_short.json
- Seed: 13
- Minimum simSeconds: 6 (runTicks 360 at 60hz)
- Proofs: Headless time + rewind proofs
- Command IDs: time.pause, time.play, time.setspeed, time.rewind, time.stoprewind, time.step
- PASS signals:
  - BANK:P0.TIME_REWIND_MICRO:PASS
  - [HeadlessTimeControlProof] PASS ...
  - [HeadlessRewindProof] PASS ...

G0.GODGAME_COLLISION_MICRO
- Scenario: Assets/Scenarios/Godgame/godgame_collision_micro.json
- Seed: 12345 (GodgameScenarioLoaderSystem default)
- Minimum simSeconds: 10
- PASS signals:
  - BANK:G0.GODGAME_COLLISION_MICRO:PASS
  - [GodgameCollisionProof] PASS ...

G0.GODGAME_SMOKE
- Scenario: Assets/Scenarios/Godgame/godgame_smoke.json
- Seed: 12345 (GodgameScenarioLoaderSystem default)
- Minimum simSeconds: 30
- PASS signals:
  - BANK:G0.GODGAME_SMOKE:PASS
  - smoke diagnostics report TimeState/RewindState healthy

S0.SPACE4X_COLLISION_MICRO
- Scenario: Assets/Scenarios/space4x_collision_micro.json
- Seed: 77
- Minimum simSeconds: 20 (duration_s)
- PASS signals:
  - BANK:S0.SPACE4X_COLLISION_MICRO:PASS
  - [Space4XCollisionProof] PASS ...

S0.SPACE4X_SMOKE
- Scenario: Assets/Scenarios/space4x_smoke.json
- Seed: 77
- Minimum simSeconds: 150 (duration_s)
- PASS signals:
  - BANK:S0.SPACE4X_SMOKE:PASS
  - [Space4XMiningScenario] Loaded '...space4x_smoke.json' ...
  - scenario telemetry expectations + export paths exist (json/csv)

### Tier 1 - Canonical loops (nightly core)

G1.VILLAGER_LOOP_SMALL
- Scenario: Assets/Scenarios/Godgame/villager_loop_small.json
- Seed: 12345
- Minimum simSeconds: 60
- PASS signals:
  - BANK:G1.VILLAGER_LOOP_SMALL:PASS
  - [GodgameHeadlessVillagerProof] PASS ...
  - telemetry loop logistics/gather_deliver > 0

G2.VILLAGER_MOVEMENT_DIAGNOSTICS
- Scenario: Assets/Scenarios/Godgame/villager_movement_diagnostics.json
- Seed: 12345
- Minimum simSeconds: 120
- PASS signals:
  - BANK:G2.VILLAGER_MOVEMENT_DIAGNOSTICS:PASS
  - no FAIL lines
  - telemetry size stable
  - no stuck patterns beyond thresholds

S1.MINING_ONLY
- Scenario: Assets/Scenarios/space4x_mining.json
- Seed: 42
- Minimum simSeconds: 120 (duration_s)
- Proofs: SPACE4X_HEADLESS_MINING_PROOF=1
- PASS signals:
  - BANK:S1.MINING_ONLY:PASS
  - [Space4XHeadlessMiningProof] PASS ...
  - telemetry extract/gather_dropoff > 0

S2.MINING_COMBAT
- Scenario: Assets/Scenarios/space4x_mining_combat.json
- Seed: 42
- Minimum simSeconds: 120 (duration_s)
- PASS signals:
  - BANK:S2.MINING_COMBAT:PASS
  - exports exist + expectations true (expectMiningYield, expectInterceptAttempts, etc.)

S3.REFIT_REPAIR
- Scenario: Assets/Scenarios/space4x_refit.json
- Seed: 42
- Minimum simSeconds: 180 (duration_s)
- PASS signals:
  - BANK:S3.REFIT_REPAIR:PASS
  - expectRefitCount: 1
  - expectFieldRepairCount: 1
  - modules restored to >=0.95
  - assertions ok
- Note: emit BANK lines via a ScenarioExpectationsProofSystem that reads telemetryExpectations/exports.

S4.RESEARCH_MVP
- Scenario: Assets/Scenarios/space4x_research_mvp.json
- Seed: 341
- Minimum simSeconds: 240 (duration_s)
- PASS signals:
  - BANK:S4.RESEARCH_MVP:PASS
  - expectResearchHarvest and minimumHarvests met
  - exports exist
- Note: emit BANK lines via a ScenarioExpectationsProofSystem that reads telemetryExpectations/exports.

### Tier 2 - Behavior loop proofs (run after Tier 1 is green)

S5.SPACE4X_BEHAVIOR_LOOPS
- Scenario: Assets/Scenarios/space4x_mining_combat.json (use a dedicated behavior scenario if available)
- Seed: 42
- Minimum simSeconds: 120 (duration_s)
- PASS signals:
  - BANK:S5.SPACE4X_BEHAVIOR_LOOPS:PASS
  - [Space4XHeadlessLoopProof] PASS Patrol ...
  - [Space4XHeadlessLoopProof] PASS Escort ...
  - [Space4XHeadlessLoopProof] PASS AttackRun ...
  - [Space4XHeadlessLoopProof] PASS Docking ...
- Notes:
  - Behavior proof disables patrol/attack/wing directive checks when the scenario path ends with space4x_smoke.json.

---

## Time + rewind telemetry pack (required)

Minimum metrics:
- time.tick, time.fixedDelta, time.speed, time.isPaused, time.isPlaying
- scenario.tick, time.tick_minus_scenario_tick
- rewind.mode, rewind.isActive, rewind.targetTick, rewind.progressTicks
- rewind.subjectCount, rewind.snapshotCount, rewind.snapshotBytes

Minimum events (sparse):
- time.pause, time.play, time.setspeed, time.step
- rewind.start, rewind.stop, rewind.apply_snapshot
- timebubble.add_probe, timebubble.remove_probe

---

## Telemetry hygiene

- Keep metric/event names stable and hierarchical (time.*, rewind.*, scenario.*).
- Use consistent attribute keys; keep units in metadata, not in names.
- Treat logs, metrics, and events as a correlated pack for time/rewind runs.

---

## Time/rewind rebuild batch (do all three)

When batching a rebuild for time/rewind reliability, include:
1) Scenario-aware proof so ScenarioRunner commands do not fight proofs.
2) Explicit fail if ScenarioRunnerTick advances but TickTimeState does not.
3) Sparse bubble membership markers to debug time bubbles.

---

## Overnight work without promoting current build

Allowed:
1) Scenario JSON tweaks (counts, spawn distances, durations, scripted actions)
2) Env flag tuning (proof toggles, thresholds, telemetry levels)
3) Telemetry output/report path changes
4) Report hygiene (fresh output, size cap honored)
5) Scratch rebuilds to validate code changes

Not allowed without promotion:
- overwriting the current build
- promoting scratch without meeting the promotion gate

If a code fix is needed:
- implement the change in a PR
- validate via a scratch build
- add a reproduction command + which bank entry it unblocks
- tag it REBUILD_BATCH_CANDIDATE

---

## Nightly backlog format

- Test: <testId>
- Build ID: <commit SHA or build stamp>
- Seed: <seed>
- Minimum simSeconds: <value>
- Repro command: <exact CLI + env>
- Observed: <exit code, FAIL line, missing telemetry, perf budget fail>
- Expected: <PASS line + telemetry loop proof>
- Likely slice: Body / Mind / Aggregate + suspected system(s)
- Fix type: Scenario | Env | Code(PR)
- Status: Investigating | Mitigated(no rebuild) | PR opened | Needs rebuild batch
- Artifacts: logs + telemetry ndjson path

---

## Promotion request template (scratch -> current)

- Scratch build stamp: (BUILD_STAMP line)
- Bank evidence: Tier 0 two-green, Tier 1 pass (or two-green if required)
- Artifacts: binary + logs + telemetry paths
- PRs included: (list)
- Expected impact: (which tests flip red to green)
- Post-promotion plan: (run full bank once; if green, freeze promotions)
