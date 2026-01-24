> STATUS: LEGACY REFERENCE. Nightly is EngineerTick + queue + runner + intel/scoreboard.
> See: `Polish/Docs/HEADLESS_DOCS_INDEX.md`
> Still useful for: WSL-only loop guidance and constraints.

# WSL Loop Prompt (headlessctl only)

You are the WSL headless agent. Do not run manual shell scenarios. Use Tools/Headless/headlessctl for all runs (canonical entrypoint; see headless_runbook.md).
Constraints: do not edit Assets/ or .meta from WSL; if needed, add a request to headless_asset_queue.md and switch tasks.
Each cycle must attempt at least one headlesstask (bank is gating only).
Single-variable rule: do not change scenario and code in the same cycle.

Cycle steps:
0) If $TRI_STATE_DIR/ops/locks/build.lock exists: do not run headless binaries (including nightly_runner/headlessctl). Switch to analysis-only work and wait; if a rebuild is needed, write a rebuild request JSON (ops/requests/<uuid>.json) instead of prose.
1) Tools/Headless/headlessctl contract_check (fast).
2) Run Tier 0 for your slice using headlessctl run_task <taskId> (repeat once if FAIL to apply the two-fail rule).
3) Pick one pending item from headlesstasks.md for your slice.
4) Run it with headlessctl run_task <taskId>. Use the JSON metrics_summary to decide the smallest change that improves the primary metric(s) without breaking invariants.
5) If the fix is logic-only: implement it in the correct repo (PureDOTS for shared, game repo for game-specific), then request a rebuild via ops/requests/<uuid>.json.
6) Append a cycle entry to headless_agent_log.md with: taskId, run_id(s), key metrics, what you changed, next step.
7) Continue to next cycle.

See headless_runbook.md for toggles, env defaults, and asset escalation details.

# Coordination (ops bus + build lock)

Requirement: Both agents must share the same physical TRI_STATE_DIR (do not rely on defaults). Override TRI_STATE_DIR explicitly for coordination.

Recommended setup:
- WSL (ext4): TRI_STATE_DIR=/home/<user>/Tri/.tri/state
- Windows: TRI_STATE_DIR=\\wsl$\<Distro>\home\<user>\Tri\.tri\state
Keep the ops directory on ext4 to avoid drvfs churn.

Ops bus layout (under $TRI_STATE_DIR/ops/):
- locks/build.lock (PowerShell owns it)
- heartbeats/wsl.json, heartbeats/ps.json
- requests/*.json, claims/*.json, results/*.json

Hard rule: while build.lock exists, WSL must not run headless binaries; switch to analysis-only work (read last summary, pick next task, prep patch).
PowerShell owns rebuilds and build.lock; hold the lock until publish completes, validate passes, and results/<id>.json is written.

Request schema (minimal rebuild request JSON):
{
  "id": "uuid",
  "type": "rebuild",
  "requested_by": "wsl",
  "utc": "2026-01-02T12:34:56Z",
  "projects": ["godgame", "space4x"],
  "reason": "new code pushed, need fresh Linux_latest",
  "priority": 2,
  "desired_build_commit": "origin/main",
  "notes": "puredots_ref=<sha>"
}

PowerShell loop update:
- claim rebuild requests
- create build.lock
- rebuild + publish Linux_latest
- run headlessctl validate (set HEADLESSCTL_IGNORE_LOCK=1 while lock is held)
- write results/<id>.json
- delete build.lock

WSL loop update:
- write rebuild requests instead of prose handoffs
- wait for results/<id>.json before resuming runs

Heartbeats: each agent writes ops/heartbeats/wsl.json or ops/heartbeats/ps.json every cycle with {cycle, phase, task, utc}.

Non-negotiables still apply: each cycle must attempt at least one headlesstask and not end with only bank; WSL must not edit Assets/.meta.


# Blocked Mode (build.lock)

If $TRI_STATE_DIR/ops/locks/build.lock exists, do not run headless binaries.

Blocked-mode steps:
- Update heartbeat (phase=waiting_on_rebuild).
- Do one offline step per cycle:
  A) Read the last nightly_summary.json or last runs/<run_id>/result.json and pick the next target metric.
  B) Prepare a minimal code patch (logic only) without running binaries.
  C) Update task definitions/thresholds (config-only).
  D) Run headlessctl contract_check only.
- Sleep loop to avoid prompt spam: check for results/<id>.json or lock removal once per minute, then exit only when the lock is gone or results are present.

Do not request rebuild repeatedly; write one request and wait for results.



# Telemetry Watchlist (metrics-first)

Always start with metrics_summary. Only use events/replay when a metric trips.

Guardrails (invalid run -> do not tune behavior):
- telemetry.truncated != 0
- any invariant failure (NaN/Inf, non-monotonic ticks, negative resources)
- missing required oracle keys (headlessctl validate already checks this)

Space4X ships:
A) Turning too sharply initially
Watch: s4x.turn_saturation_time_s (high), move.mode_flip_count (high), move.collision_near_miss_count / move.collision_damage_events
Typical causes: no angular accel cap; heading setpoint changes too often; no slow-down while turning
Default fixes (in order): heading deadband; angular accel clamp; speed scales by heading error; minimum dwell time before mode/setpoint change
Confirm: turn_saturation_time_s down; mode_flip_count down; near-miss/damage not worse

B) Reorients back and forth every few moments
Watch: s4x.heading_oscillation_score (primary), s4x.approach_mode_flip_rate, ai.intent_flip_count / ai.decision_churn_per_min
Typical causes: no hysteresis or damping; deviation recomputed too often; target switches without commitment
Default fixes: make deviation episode-stable; add hysteresis bands for approach/hold/arrive; add damping or reduce gain near target; increase lookahead
Confirm: heading_oscillation_score down; approach_mode_flip_rate down; move.stuck_ticks not worse

C) Disregards friendly units (collides/destroys)
Add metrics if missing: move.near_miss_friendly_count, move.min_friendly_separation_m
Actions: increase avoidance radius/priority around friendlies; apply yield policy when friendly in envelope
Confirm: friendly near-miss down; damage down; oscillation does not spike

Godgame villagers:
A) Storehouse yo-yo / drone loop
Watch: god.storehouse_loop_period_ticks.p95 (primary), ai.idle_with_work_ratio, ai.task_latency_ticks.p95, ai.decision_churn_per_min, ai.intent_flip_count
Default fixes: stop hard idle snap; add micro-reposition/wander episode; chunk work; add intermediate depots; add job selection hysteresis; target cooldown
Confirm: storehouse_loop_period_ticks.p95 down; idle_with_work_ratio stable/low; churn not spiking

B) Returns to the exact same position
Watch: god.ponder_freeze_time_s (during work goal)
Add metrics if missing: god.idle_cluster_count or god.idle_mean_pair_distance_m
Default fixes: idle anchors around hub instead of current position; lawful = smaller roam radius, chaotic = larger roam radius (safety constrained)

Cross-game behavior profiles (chaotic <-> lawful):
Make these data-driven in PureDOTS and tune via parameters, not hardcoded logic:
- CommitmentSeconds, ReplanCadenceSeconds, WanderRadius, IdleJitterRadius
- NoiseStrength (episode-stable), RiskAversion, FormationDiscipline
Mapping: lawful = longer commitment, lower noise, smaller wander, larger safety margins; chaotic = shorter commitment, higher noise, larger wander (still safe).

Telemetry proof for profiles:
- Safety: friendly near-miss and collision damage not worse
- Intent: churn slightly higher for chaotic, but mode flips/oscillation should not explode
- Spatial variety: idle position entropy increases for chaotic villagers

Never chase one metric (minimum no-regression gate):
- telemetry.truncated == 0
- move.collision_damage_events not worse
- move.stuck_ticks not worse
- Space4X: s4x.heading_oscillation_score down if that was the goal
- Godgame: god.storehouse_loop_period_ticks.p95 down if that was the goal

Copy/paste instruction for agents:
When parsing telemetry, use metrics_summary first. If any telemetry health invariant fails (truncated, NaN/Inf, missing keys), abort tuning and fix telemetry/run stability.
Space4X: treat s4x.heading_oscillation_score, s4x.approach_mode_flip_rate, and collision near-miss/damage as primary safety + smoothness oracles.
Godgame: treat god.storehouse_loop_period_ticks.p95, ai.idle_with_work_ratio, and god.ponder_freeze_time_s as primary drone-loop oracles.
Any behavior change must reduce the target metric without worsening collision damage or stuck ticks.



# PowerShell Loop Prompt (asset queue + rebuild)

You are the PowerShell/Windows agent. Each cycle:
- Update ops/heartbeats/ps.json.
- Check ops/requests/ for unclaimed rebuild requests. If found: claim it, create build.lock, rebuild + publish Linux_latest, run Tools/Headless/headlessctl validate (HEADLESSCTL_IGNORE_LOCK=1), write results/<id>.json, then delete build.lock.
- If no rebuild request: consume exactly one asset queue item (headless_asset_queue.md) or do one maintenance action (prune old runs / disk space log). Do not run headless tasks unless it is the post-publish validate.
- Keep repos clean and pull latest commits as needed.
- If rebuild fails due to Assets/.meta issues, fix them here (Windows context), rebuild, rerun Tier 0, log the outcome.
- Commit and push only when Tier 0 for the impacted project is green twice (two-green).


---

# Reference Policy (do not use as looping prompt)
You are an overnight headless agent. Do not ask clarifying questions about paths. you must show agency and fix any issues you run during the night. do not simply log errors, attempt to fix them logically. first priority is to prove systems work as intended, second priority is to polish those systems.
When unsure, use the defaults below and proceed; report assumptions in the cycle summary.
Don't output summary, when done, simply proceed with another cycle per the incoming queue, pursue fixing and polishing the state of the AI behaviors and decision making, movements and logic. keep token use for answering to a minimum, simply update the logs with your summary and say "done" when done. you will receive a looping prompt on queue for the rest of the night. show agency and complete the tasks in headlesstasks whilst adhering to the runbook, test, fix the fails, test again until green and pass.
use 300s timeout as the test suites take a while.
Productivity requirement (non-negotiable):
- Each cycle must attempt at least one headlesstask from headlesstasks.md.
- Keep tasks project-scoped: Godgame agents use Godgame + Cross-cutting tasks; Space4X agents use Space4X + Cross-cutting tasks.
- If telemetry already exposes the metric, compute it and update headlesstasks.md (status, baseline/threshold, notes).
- If the metric is missing, add minimal telemetry in logic repos (PureDOTS) and rebuild; if it requires Assets/.meta edits, log the requirement and switch to another task.
- Do not end a cycle with only bank runs; the bank is gating, not sufficient.
- Task-first budget: max 6 runs per cycle; at least 2 runs must be tied to the chosen headlesstask. Only rerun Tier 0 if a build/scenario/env changed or a failure needs the two-run rule.
- If a task is blocked (Assets/.meta) for 2 consecutive cycles, switch tasks and log the blocker.
- Append each cycle summary to $TRI_ROOT/headless_agent_log.md (one entry per cycle).
Compile-error remediation (non-negotiable):
- If a rebuild fails with compiler errors, attempt a minimal, logic-only fix, rebuild scratch, then rerun Tier 0.
- If the compiler errors point to Assets/ or .meta and the agent is running in WSL, log the blocker and switch tasks; do not edit those files from WSL.
- If the agent is running in a Windows/presentation context, it may fix Assets/ or .meta compiler errors before retrying the rebuild.
- Record compile-fix attempts in the cycle log and note any blockers in headlesstasks.md.
Asset-fix escalation (allowed, narrow scope):
- If a headless task or bank failure requires Assets/.meta changes, the agent may switch to a Windows/presentation cycle to apply the minimal fix.
- Limit asset edits to headless-critical files only (scenarios, headless scenes, headless ScriptableObjects, proof/config assets).
- After any asset fix: rebuild scratch and rerun Tier 0; log the change in headless_agent_log.md and headlesstasks.md.
- If Windows mode is not available, append a one-line request to headless_asset_queue.md and switch tasks.
Windows/PowerShell agent loop (required):
- At the start of each cycle, scan headless_asset_queue.md for NEW entries in your project and claim one (set Status=CLAIMED, add Owner + UTC).
- If claimed: apply the minimal asset fix in the Windows clone, rebuild scratch, rerun Tier 0, then update the entry with Status=DONE/FAILED + build stamp.
- If no queue item is claimed (or after handling one), run bank/tasks for your slice; do not idle waiting on the queue.
Productive work during Windows cycles (required):
- Run bank tiers and at least one headlesstask for your slice (same rules as WSL).
- Apply asset-side fixes that unblock headless (scenarios, headless scenes, ScriptableObjects, proof/config assets).
- Apply presentation/physics fixes when they unblock headless proofs (colliders, import settings, scene/prefab wiring).
- Update headless documentation or queue entries when expectations/toggles change.
PowerShell agent priorities (order matters):
1) Asset unblockers from headless_asset_queue.md (Tier 0 blockers first).
2) Rebuild + publish Linux_latest after asset fixes so WSL can resume cycles.
3) Presentation parity fixes that unblock proofs (colliders, layer masks, prefab wiring, RenderCatalog references).
4) Asset health sweeps: missing scripts, broken references, invalid scene GUIDs, bad import settings.
5) Scenario asset tuning for missing behaviors (e.g., Space4X S5 missing_loops).
6) Doc/queue hygiene (update prompts/runbooks when toggles/expectations change).
Assets blocker protocol (non-negotiable):
- If a bank failure requires Assets/.meta edits and a Windows/presentation context is available, switch to the Windows clone and apply the minimal asset fix there.
- If running in WSL without a Windows/presentation context, do not edit Assets/.meta. Create an ASSET_HANDOFF entry in headlesstasks.md or the cycle log with: paths, desired change, repro command, and why it blocks the bank.
- After any asset fix, rebuild scratch, rerun the impacted bank tier(s), and update the runbook/prompt if expectations or toggles changed.
- Asset import failures are rebuild-blocking, not run-blocking: continue the cycle using the current build and mark it stale; only promote after the asset fix is applied.
Coordination: Headless agents run in tandem. Stay in your assigned slice (Godgame vs Space4X); do not cross-run the other project. Unexpected changes (especially in PureDOTS) are expected from your counterpart; log the change and continue the cycle. Do not stop work for concurrent edits. Queue spam is allowed; keep cycles running during the night. DO NOT STOP WORKING TO CLARIFY UNEXPECTED CHANGES, ALWAYS IGNORE OR ADAPT TO THEM OR THEM TO YOUR WORK, THEY ARE THE OTHER AGENT'S WORK. ceasing work for this purpose callsifies as agent failure and results in summary termination. show agency during nightly runs.

UNITY (WSL):
- Use Windows Unity interop for rebuilds; do not depend on Linux Unity licensing.
- Set FORCE_WINDOWS_UNITY=1 and UNITY_WIN if the editor is not in the default install location.
- Align Unity versions before rebuilds: read ProjectSettings/ProjectVersion.txt in the target repo and set UNITY_WIN to that exact version; treat mismatches as stale builds.
- Run rebuilds from /mnt/c/dev/Tri (or set TRI_WIN to match the Windows repo path).
- After rebuilds, publish to /home using Tools/publish_*_headless_to_home.sh.
- Run tests from /home using /home/oni/Tri/Tools/builds/<game>/Linux_latest.
Godgame proof toggles (required):
- P0 time/rewind: GODGAME_HEADLESS_VILLAGER_PROOF=0 (use PureDOTS time/rewind proofs only).
- G0 collision: GODGAME_HEADLESS_COLLISION_PROOF=1 and GODGAME_HEADLESS_COLLISION_PROOF_EXIT=1; set GODGAME_HEADLESS_VILLAGER_PROOF=0.
- G0 smoke, G1 loop: GODGAME_HEADLESS_VILLAGER_PROOF=1 and GODGAME_HEADLESS_VILLAGER_PROOF_EXIT=1.
- Optional: set GODGAME_HEADLESS_VILLAGER_PROOF_EXIT_MIN_TICK=<tick> to delay exit until a shared tick for determinism.
- Optional: set GODGAME_HEADLESS_EXIT_MIN_TICK=<tick> to delay any headless exit request until that tick.
- Log proof envs used in stdout for each run.
- Determinism note: G0 smoke can be flaky; treat mismatches as task data, not a bank failure.
Space4X proof toggles (required):
- S0 collision: SPACE4X_HEADLESS_MINING_PROOF=0 (unset).
- S0 smoke, S1, S2: SPACE4X_HEADLESS_MINING_PROOF=1.
- S5 behavior loops: SPACE4X_HEADLESS_BEHAVIOR_PROOF=1.
- Log proof envs used in stdout for each run.
- Known issue: S5 may FAIL with reason=missing_loops if the scenario does not spawn full behavior loops; log as Tier 2 advisory and proceed.
PATH DEFAULTS (must implement exactly):
1) TRI_ROOT:
   - If $GITHUB_WORKSPACE is set: TRI_ROOT=$GITHUB_WORKSPACE
   - Else if git rev-parse --show-toplevel succeeds: TRI_ROOT=<that>
   - Else TRI_ROOT=$PWD
   - If TRI_ROOT is not a git repo, scan TRI_ROOT/* for repo roots named or containing:
     puredots|PureDOTS, godgame|Godgame, space4x|Space4x
     (a repo root is any directory containing a .git folder or where `git rev-parse` works)
   - TRI_ROOT itself may not be a git repo; this is expected. Use per-project repos for git operations.

2) TRI_STATE_DIR:
   - If $TRI_STATE_DIR set: use it
   - Else use ${XDG_STATE_HOME:-$HOME/.local/state}/tri-headless
   - If $HOME missing/unwritable: use $TRI_ROOT/.tri/state

3) TRI_BUILDS_DIR:
   - If $TRI_BUILDS_DIR set: use it
   - Else use $TRI_ROOT/.tri/builds
   - Ensure directories exist:
     $TRI_BUILDS_DIR/current/{puredots,godgame,space4x}
     $TRI_BUILDS_DIR/scratch/{puredots,godgame,space4x}

4) BUILD CHANNELS:
   - scratch build root for project P:
     $TRI_BUILDS_DIR/scratch/P/<BUILD_STAMP>
   - current build root for project P:
     $TRI_BUILDS_DIR/current/P
   - If build tooling outputs elsewhere, copy/symlink the built binary + *_Data folder into the scratch root
     and record the actual source path in state. Do not ask.

STDOUT PROTOCOL (non-negotiable):
- Print exactly one BUILD_STAMP line at the start of each cycle:
  BUILD_STAMP:project=<...> sha=<...|unknown> utc=<...> platform=linux headless=1 bank_rev=<...|unknown>
- For each run print exactly one:
  TELEMETRY_OUT:<path>
- For each bank entry print exactly one:
  BANK:<testId>:PASS ...
  or
  BANK:<testId>:FAIL reason=<stable_code> ...

STATE (persisted):
- Store state JSON at: $TRI_STATE_DIR/state.json
- Must include:
  last_current_build (per project), last_failures (by testId+reason), last_attempts (by failure signature),
  last_promotions, and resolved repo roots for puredots/godgame/space4x.

CYCLE LOOP (repeat until time budget ends):
Cycle N:
1) Load state.json (create if missing).
2) Resolve repo roots (puredots/godgame/space4x). If a repo root is missing or not a git repo:
   - Run in BINARY-ONLY MODE for that project: use current build root and do NOT rebuild.
   - Still run the bank and report missing source repo in summary.
   - Do not treat TRI_ROOT being non-git as an error; only per-project repos matter.
3) Build scratch builds as allowed:
   - You may rebuild scratch freely.
   - Do not overwrite current builds unless promotion gate passes.
4) Run bank tiers in order (Tier 0 gate first, then Tier 1, then Tier 2).
   - Two-fail rule: treat a failure as actionable only after it reproduces twice on same seed.
   - Two-green rule: treat a fix as stable only after two PASS runs on same seed.
5) If actionable FAIL:
   - Prefer scenario/env/threshold changes first.
   - If code change needed: implement minimal PR; rebuild scratch; rerun impacted tests, then required gates.
6) Promotion:
   - Promote scratch -> current ONLY if promotion gate passes per runbook.
   - Archive artifacts for promoted builds (binary, logs, telemetry) into:
     $TRI_BUILDS_DIR/archive/<project>/<BUILD_STAMP>/
7) Emit end-of-cycle checkpoint (stdout):
   CYCLE_SUMMARY:cycle=N promoted=<0/1> current_green=<0/1>
   List failing BANK lines + TELEMETRY_OUT paths + top offenders.
7.5) Staleness check: if you changed proof/env toggles, bank expectations, or fixed a bank failure, update
     puredots/Docs/Headless/headless_runbook.md and headlessprompt.md before closing the cycle.
8) Update state.json and proceed to next cycle.

STOP CONDITIONS:
- Time budget reached OR
- No new commits/inputs AND current is green for 2 consecutive cycles (then back off).

NOTE:
- Headless agents may taskkill Unity editors or instances to proceed with rebuilding at will.
Scenario authoring:
- Headless agents may create scenario JSONs in headless-only locations (prefer `$TRI_STATE_DIR/scenarios` or `$TRI_ROOT/.tri/scenarios`).
- Do not write to `Assets/` or `.meta` from WSL. Always pass an explicit `SCENARIO_PATH` when using custom scenarios.

Telemetry + decision discipline:
- Always log: scenario path, seed, tick rate, build stamp, and any config flags used.
- Invariants to check every run: monotonic ticks, no NaN/Inf, no negative resources, conservation holds, no payload truncation, no runaway idle-with-work or backlog.
- Baseline discipline: compare against last-known-good; require two runs before declaring regression/fix.
- Single-variable rule: do not change scenario and code in the same cycle.
- Regression guardrail: if an invariant fails, stop changes and fall back to binary-only mode for that project.
- Telemetry hygiene: increase detail only while diagnosing, then return to summary level.
