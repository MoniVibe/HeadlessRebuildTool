---
name: anviloop-forecast
description: Forecast likely nightly progress by reading the current deck JSON and key Anviloop markdown docs, then summarizing focus slices, expected jobs, and likely risks. Use when the user asks to anticipate nightly direction or to interpret a deck.
---

# Anviloop Nightly Forecast

## Inputs to scan

- Deck JSON used for the run (DeckPath in `Polish/run_deck.ps1`).
- Defaults: `C:/Dev/unity_clean/headlessrebuildtool/Polish/pipeline_defaults.json`
- Key docs:
  - `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/HEADLESS_DOCS_INDEX.md`
  - `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/NIGHTLY_PROTOCOL.md`
  - `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/MORNING_VIEW.md`
  - `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/ANVILOOP_RECURRING_ERRORS.md`

## Deck parsing focus

Extract from each job:

- `title`, `project_path_override`, `scenario_id`, `scenario_rel`, `seed`, `timeout_sec`, `repeat`
- `goal_id`, `goal_spec`, `base_ref`, `required_bank`, `args`
- Queue root and timing: `queue_root`, `poll_sec`, `pending_grace_sec`, `max_minutes`

Resolve defaults from `pipeline_defaults.json` for any missing fields.

## Forecast rules

- Focus slices = unique `goal_id` or `scenario_id` + repeats.
- Direction is defined by:
  - Main focus slice(s) and their repeats.
  - Whether goals are code-only vs scenario changes (Nightly Protocol).
  - Any required bank/goal spec gating.
- Risk modifiers:
  - Prior recurring errors matching the scenario or goal.
  - INVALID gates (telemetry/oracle/invariants).
  - Disk gate and cleanup status.

## Output format (concise)

```
Focus slices: <goal_id/scenario_id list + repeats>
Expected jobs: <count, key scenarios, seeds, timeouts>
Direction: <what the night is likely to attempt>
Risks: <top 1-3 risks from ledger or validity gates>
Next checks: <headline/scoreboard/intel files to validate>
```

## References

- `C:/Dev/unity_clean/headlessrebuildtool/Polish/run_deck.ps1`
- `C:/Dev/unity_clean/headlessrebuildtool/Polish/pipeline_defaults.json`
