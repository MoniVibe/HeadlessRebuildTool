---
name: anviloop-deck
description: Design and write Anviloop nightly deck JSONs that set direction, jobs, and polish tasks for a cycle. Use when the user asks to create a deck, choose nightly direction, or plan nightly tasks.
---

# Anviloop Deck Builder

## Purpose

Create a deck JSON for `Polish/run_deck.ps1` that defines the nightly direction, jobs, and polish tasks while respecting Nightly Protocol rules.

## Inputs to consult

- `C:/Dev/unity_clean/headlessrebuildtool/Polish/run_deck.ps1`
- `C:/Dev/unity_clean/headlessrebuildtool/Polish/pipeline_defaults.json`
- `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/NIGHTLY_PROTOCOL.md`
- `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/ANVILOOP_RECURRING_ERRORS.md`
- `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/MORNING_VIEW.md`

## Guardrails (must follow)

- Single-variable rule: do not change scenario and code in the same cycle.
- If a failure signature repeats twice, consult the ledger before changing code.
- Pins must exist in all requested repos (space4x, godgame) to avoid pathspec errors.

## Deck design steps

1. Choose a single nightly direction:
   - Set one primary `goal_id` or `scenario_id`.
   - Decide if the cycle is code-only or scenario-only.
2. Select jobs:
   - Use `pipeline_defaults.json` for defaults (title, scenario, seed, timeout, args).
   - Add overrides only when necessary.
3. Apply risk checks:
   - Scan the ledger for matching signatures.
   - Avoid scenarios with known unstable signatures unless explicitly testing a fix.
4. Set queue + timing:
   - Use `C:/polish/queue` unless instructed otherwise.
   - Keep `poll_sec`, `pending_grace_sec`, `max_minutes` aligned to expected run time.

## Deck JSON template (minimal)

```json
{
  "queue_root": "C:/polish/queue",
  "poll_sec": 60,
  "pending_grace_sec": 600,
  "max_minutes": 720,
  "jobs": [
    {
      "title": "space4x",
      "scenario_id": "space4x_collision_micro",
      "scenario_rel": "Assets/Scenarios/space4x_collision_micro.json",
      "seed": 7,
      "timeout_sec": 90,
      "repeat": 1,
      "goal_id": "ARC",
      "goal_spec": "Polish/Goals/arc_goal.json",
      "base_ref": "origin/main",
      "required_bank": "BANK_PASS",
      "args": ["--telemetryEnabled", "1"]
    }
  ]
}
```

## Output format (concise)

When asked to create a deck, respond with:

```
Direction: <goal_id/scenario_id + code-only or scenario-only>
Jobs: <count + titles + repeats>
Risks: <ledger matches or INVALID gates>
Deck: <JSON>
```
