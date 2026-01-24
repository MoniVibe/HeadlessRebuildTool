> STATUS: LEGACY REFERENCE. Nightly is EngineerTick + queue + runner + intel/scoreboard.
> See: `Polish/Docs/HEADLESS_DOCS_INDEX.md`
> Still useful for: WSL run commands + asset escalation notes.

# Headless Runbook (WSL/Linux)

These commands run the already-built Linux headless players and write NDJSON telemetry to `/home/oni/Tri/telemetry/`.
If your WSL clone lives elsewhere, replace `/home/oni/Tri` with your local TRI root; avoid `/mnt/c` for active WSL runs due to drvfs I/O errors.
Rebuilds are done via Windows Unity interop from `/mnt/c/dev/Tri`, then published into `/home/oni/Tri/Tools/builds` for runs.


Cross-OS caveats:
- Avoid editing `Assets/` or `.meta` from WSL; presentation owns those files.
- Keep `Packages/manifest.json` and `Packages/packages-lock.json` synced across clones when logic changes.
- Headless rebuilds in WSL should use Windows Unity interop (set `FORCE_WINDOWS_UNITY=1`); do not rely on Linux Unity licensing.
- Align Unity versions before rebuilds: read `ProjectSettings/ProjectVersion.txt` in the target repo and set `UNITY_WIN` to that exact version; mismatches mean stale builds.
Asset-fix escalation (Windows-only):
- If a bank failure or headless task requires `Assets/` or `.meta` edits and a Windows/presentation context is available, switch to that mode for the fix only.
- Keep edits minimal and limited to headless-critical assets (scenarios, headless scenes, headless ScriptableObjects, proof/config assets).
- If Windows mode is not available, add a one-line request to `headless_asset_queue.md` with: paths, desired change, repro command, and why it blocks the bank.
- After any asset fix, rebuild scratch, rerun the impacted bank tier(s), and update the runbook/prompt if expectations or toggles changed.
- Asset import failures are rebuild-blocking, not run-blocking: continue the cycle using the current build and mark it stale; only promote after the asset fix is applied.

## WSL + Windows cooperation (async)
- WSL headless agents log asset blockers to `headless_asset_queue.md` and keep cycling other tasks.
- Windows/PowerShell agents check the queue at the start of each cycle, claim one NEW item, apply the minimal fix, rebuild, rerun Tier 0, and then continue with their own bank/tasks.
- Do not idle waiting on the queue; always do productive work each cycle.
Productive Windows-cycle work includes:
- Running bank tiers + at least one headlesstask for the assigned slice.
- Asset-side fixes that unblock headless (scenarios, headless scenes, ScriptableObjects, proof/config assets).
- Presentation/physics fixes when they unblock headless proofs (colliders, import settings, scene/prefab wiring).
- Documentation updates when toggles/expectations change.
PowerShell agent priorities (order matters):
1) Asset unblockers from headless_asset_queue.md (Tier 0 blockers first).
2) Rebuild + publish Linux_latest after asset fixes so WSL can resume cycles.
3) Presentation parity fixes that unblock proofs (colliders, layer masks, prefab wiring, RenderCatalog references).
4) Asset health sweeps: missing scripts, broken references, invalid scene GUIDs, bad import settings.
5) Scenario asset tuning for missing behaviors (e.g., Space4X S5 missing_loops).
6) Doc/queue hygiene (update prompts/runbooks when toggles/expectations change).


## Important (avoid mixed runs)
Telemetry export appends to existing NDJSON files. Before each run, delete the target file so you don’t mix multiple runs:

```bash
rm -f /home/oni/Tri/telemetry/<file>.ndjson
```

## Success checklist (both games)
- Log contains the scenario start line (game-specific; see below).
- No fatal exceptions.
- Telemetry file exists and the last line has a higher `tick` than the first.

## Smoke validation checklist
- **Godgame**: after the run starts, logs should mention `godgame_smoke.json`, `GodgameScenarioLoaderSystem` should print villager/storehouse counts, and `Godgame_RenderKeySimDebugSystem` in the Editor should warn only if villagers/villages are truly missing.
- **Space4X**: CLI log should show `[ScenarioEntryPoint] ... space4x_smoke.json` and `[Space4XMiningScenario] Loaded '...space4x_smoke.json'`; in the Editor, `Space4XSmokeWorldCountsSystem` should list carriers, miners, asteroids (with no fallback warnings).

## Mode Matrix (avoid mixed modes)

Editor smoke (interactive):
- Do not set any PUREDOTS_* env vars globally.
- Rely on the editor smoke override (Space4X now; Godgame after Agent 2).

Nightly headless (no visuals):
- `PUREDOTS_HEADLESS=1`
- `PUREDOTS_NOGRAPHICS=1`
- `PUREDOTS_TELEMETRY_ENABLE=1`
- `PUREDOTS_TELEMETRY_PATH=<out>/...ndjson`
- Unset: `PUREDOTS_FORCE_RENDER`, `PUREDOTS_RENDERING`, `PUREDOTS_HEADLESS_PRESENTATION`

Headless presentation capture (rare, explicit):
- Same as nightly headless, plus:
  - `PUREDOTS_FORCE_RENDER=1`
  - `PUREDOTS_HEADLESS_PRESENTATION=1`

## Nightly rebuild policy
- Nightly headless agents may rebuild during their window to keep the implement -> test -> fix loop moving.
- Still honor the rebuild gate + test bank in `puredots/Docs/Headless/headless_runbook.md`; avoid rebuilds during active presentation/editor sessions.

## Cycle close-out (staleness check)
- If you changed proof/env toggles, bank expectations, or fixed a bank failure, update `puredots/Docs/Headless/headless_runbook.md`
  and `headlessprompt.md` before ending the cycle.

## Godgame

```bash
mkdir -p /home/oni/Tri/telemetry
timeout 30s env \
  GODGAME_HEADLESS_VILLAGER_PROOF=1 \
  GODGAME_HEADLESS_VILLAGER_PROOF_EXIT=1 \
  PUREDOTS_TELEMETRY_ENABLE=1 \
  PUREDOTS_TELEMETRY_FLAGS=metrics,events \
  PUREDOTS_TELEMETRY_PATH=/home/oni/Tri/telemetry/godgame_headless_run.ndjson \
  /home/oni/Tri/Tools/builds/godgame/Linux_latest/Godgame_Headless.x86_64 \
    -batchmode -nographics -logFile - \
    --scenario /home/oni/Tri/godgame/Assets/Scenarios/Godgame/godgame_smoke.json
```

Expected log lines:
- `[GodgameScenarioEntryPoint] Scenario='...godgame_smoke.json'...`
- `Streamed scene ... 06e6ed0a02467d442bd620cfbcc2d281.0.entities` (ConfigSubScene streamed)
- `[GodgameScenarioLoaderSystem] Loading scenario: Godgame Smoke`
- `[GodgameHeadlessVillagerProof] PASS ...` (proves gather + deliver)

Notes:
- Godgame can run ScenarioRunner-style JSON too (see Time/Rewind section). For the smoke showcase it still uses `GodgameScenarioLoaderSystem`.
- Current state: “Godgame Smoke” seeds two settlements and shared resource belts; telemetry reports villager + storehouse counts once storehouse metrics are wired.
- Optional: enable build proof by setting `GODGAME_HEADLESS_VILLAGE_BUILD_PROOF=1` + `GODGAME_HEADLESS_VILLAGE_BUILD_PROOF_EXIT=1`.

## Space4X

```bash
mkdir -p /home/oni/Tri/telemetry
timeout 30s env \
  SPACE4X_HEADLESS_MINING_PROOF=1 \
  SPACE4X_HEADLESS_MINING_PROOF_EXIT=1 \
  PUREDOTS_TELEMETRY_ENABLE=1 \
  PUREDOTS_TELEMETRY_FLAGS=metrics,events \
  PUREDOTS_TELEMETRY_PATH=/home/oni/Tri/telemetry/space4x_headless_run.ndjson \
  /home/oni/Tri/Tools/builds/space4x/Linux_latest/Space4X_Headless.x86_64 \
    -batchmode -nographics -logFile - \
    --scenario /home/oni/Tri/space4x/Assets/Scenarios/space4x_smoke.json \
    --report /home/oni/Tri/telemetry/space4x_headless_run_report.json
```

Expected log lines:
- `[ScenarioEntryPoint] Space4X mining scenario requested: '...space4x_smoke.json'...`
- `[Space4XMiningScenario] Loaded '...space4x_smoke.json'...`
- `Streamed scene ... 3448579597b6d43408eac98ec9a8ec94.0.entities` (Space4XConfig SubScene streamed)
- `[Space4XHeadlessMiningProof] PASS ...` (proves gather + dropoff in headless)

Notes:
- `space4x_smoke.json` runs for `duration_s=150` (auto-quit happens at the end); keep using `timeout` for short smoke runs.
- The non-combat variant is `space4x_mining.json`.
- Set `SPACE4X_HEADLESS_MINING_PROOF_EXIT=1` to have the process exit immediately on PASS/FAIL.
- If the proof FAILs at `tick=900`, you’re almost certainly running a stale headless build (source now uses a longer timeout); rebuild and rerun.
- If you see `scenario.default` / “never reached initialized state”, you’re running the old ScenarioRunner path (rebuild required).
- If you see `LoadSceneAsync - Invalid sceneGUID` / `SubScene.AddSceneEntities()`, the headless bootstrap scene has a null SubScene entry (rebuild required).
Proof toggles (Space4X):
- S0 collision micro: unset `SPACE4X_HEADLESS_MINING_PROOF` to avoid false FAILs.
- S0 smoke + S1/S2 mining scenarios: set `SPACE4X_HEADLESS_MINING_PROOF=1`.
- S5 behavior loops: set `SPACE4X_HEADLESS_BEHAVIOR_PROOF=1` (known issue: may FAIL with reason=missing_loops if behaviors are absent).

## Time + Rewind (ScenarioRunner sample)

This runs the shared ScenarioRunner test that issues time/rewind commands.
You can run it from either game now.

### Godgame (ScenarioRunner)
```bash
mkdir -p /home/oni/Tri/telemetry
timeout 30s env \
  PUREDOTS_HEADLESS_TIME_PROOF=1 \
  PUREDOTS_HEADLESS_REWIND_PROOF=1 \
  PUREDOTS_TELEMETRY_ENABLE=1 \
  PUREDOTS_TELEMETRY_FLAGS=metrics,events \
  PUREDOTS_TELEMETRY_PATH=/home/oni/Tri/telemetry/godgame_time_rewind.ndjson \
  /home/oni/Tri/Tools/builds/godgame/Linux_latest/Godgame_Headless.x86_64 \
    -batchmode -nographics -logFile - \
    --scenario /home/oni/Tri/puredots/Packages/com.moni.puredots/Runtime/Runtime/Scenarios/Samples/headless_time_rewind_short.json \
    --report /home/oni/Tri/telemetry/godgame_time_rewind_report.json
```

Expected log lines:
- `[GodgameScenarioEntryPoint] ScenarioRunner '...headless_time_rewind_short.json' completed. ...`
- `[HeadlessTimeControlProof] PASS ...`
- `[HeadlessRewindProof] PASS ... subjects=...`

### Space4X (ScenarioRunner)
```bash
mkdir -p /home/oni/Tri/telemetry
timeout 30s env \
  PUREDOTS_HEADLESS_TIME_PROOF=1 \
  PUREDOTS_HEADLESS_REWIND_PROOF=1 \
  PUREDOTS_TELEMETRY_ENABLE=1 \
  PUREDOTS_TELEMETRY_FLAGS=metrics,events \
  PUREDOTS_TELEMETRY_PATH=/home/oni/Tri/telemetry/space4x_time_rewind.ndjson \
  /home/oni/Tri/Tools/builds/space4x/Linux_latest/Space4X_Headless.x86_64 \
    -batchmode -nographics -logFile - \
    --scenario /home/oni/Tri/puredots/Packages/com.moni.puredots/Runtime/Runtime/Scenarios/Samples/headless_time_rewind_short.json \
    --report /home/oni/Tri/telemetry/space4x_time_rewind_report.json
```

Notes:
- `PUREDOTS_HEADLESS_TIME_PROOF` defaults to on in headless now; set `PUREDOTS_HEADLESS_TIME_PROOF=0` to suppress it.
- `PUREDOTS_HEADLESS_REWIND_PROOF` runs automatically in headless unless explicitly disabled.

---

## Presentation Parity & Progress Scenes

### Canonical Pairings

- **Godgame**: `godgame/Assets/Scenarios/Godgame/godgame_smoke.json` ↔ `godgame/Assets/Scenes/TRI_Godgame_Smoke.unity`
  - Vision: A few villages in a vast landscape; villagers, village guards/armies, and roaming bands of adventurers, all driven by real AI/simulation systems.
  - Use the same scenario asset and config SubScenes as the Godgame headless command above.
  - When headless gains a new proven behavior (e.g., storehouse fill, villager classes, patrols, band movement), surface it here via presentation (entities, overlays, or debug UI).
  - Constraint: If something cannot be observed in headless telemetry/logs, it must not appear in the smoke scene except as neutral debug UI.

- **Space4X**: `space4x/Assets/Scenarios/space4x_smoke.json` ↔ `space4x/Assets/Scenes/TRI_Space4X_Smoke.unity`
  - Vision: A few carriers deploying mining vessels to harvest resources; strike craft deploying automatically when enemies are nearby.
  - Use the same scenario JSON and config SubScenes as the Space4X headless command.
  - New headless milestones (mining loop, combat, fleet behavior) are added visually here first.
  - Constraint: If an entity/interaction is not present in the headless run, it must not be "faked" in the smoke scene beyond neutral debug overlays.

- **Rule**: Do not fork separate "headless-only" scenes. Presentation smoke scenes are the single place where headless scenario progress is showcased; headless runs stay text/telemetry-only. No hardcoded behaviors, no presentation-only illusions.

Refer to the DOCS folders of each project to understand more about the vision and scope when necessary for implementations.
