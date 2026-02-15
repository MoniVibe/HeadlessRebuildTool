# Task Snippets: New Micro Proofs

**Warning:** Do not edit `Tools/Headless/headless_tasks.json` until PR #23 merges.

These are candidate task blocks to paste under `tasks` later.

## PureDOTS: `scenario_tickwheel_micro.json` (PR #37)

```json
"P0.PUREDOTS_TICKWHEEL_MICRO": {
  "project": "godgame",
  "runner": "scenario_runner",
  "scenario_path": "puredots/Packages/com.moni.puredots/Runtime/Runtime/Scenarios/Samples/scenario_tickwheel_micro.json",
  "tick_budget": 1200,
  "timeout_s": 900,
  "seed_policy": "none",
  "default_seeds": [4101],
  "default_pack": "nightly-default",
  "tags": ["informational", "micro", "puredots"],
  "allow_fail": true,
  "allow_exit_codes": [0, 10],
  "required_bank": "",
  "metric_keys": [
    "tickwheel.scheduled_count",
    "tickwheel.fired_count",
    "tickwheel.max_lateness_ticks",
    "tickwheel.digest"
  ]
}
```

## PureDOTS: `scenario_ai_biasproof_micro.json` (PR #38)

```json
"P0.PUREDOTS_AI_BIASPROOF_MICRO": {
  "project": "godgame",
  "runner": "scenario_runner",
  "scenario_path": "puredots/Packages/com.moni.puredots/Runtime/Runtime/Scenarios/Samples/scenario_ai_biasproof_micro.json",
  "tick_budget": 1200,
  "timeout_s": 900,
  "seed_policy": "none",
  "default_seeds": [4101],
  "default_pack": "nightly-default",
  "tags": ["informational", "micro", "puredots"],
  "allow_fail": true,
  "allow_exit_codes": [0, 10],
  "required_bank": "",
  "metric_keys": [
    "ai.biasproof.groupA.aggression_chosen",
    "ai.biasproof.groupB.social_chosen",
    "ai.biasproof.digest"
  ]
}
```

## PureDOTS: `scenario_ai_tiercadence_micro.json` (PR #40)

```json
"P0.PUREDOTS_AI_TIERCADENCE_MICRO": {
  "project": "godgame",
  "runner": "scenario_runner",
  "scenario_path": "puredots/Packages/com.moni.puredots/Runtime/Runtime/Scenarios/Samples/scenario_ai_tiercadence_micro.json",
  "tick_budget": 1200,
  "timeout_s": 900,
  "seed_policy": "none",
  "default_seeds": [41029],
  "default_pack": "nightly-default",
  "tags": ["informational", "micro", "puredots"],
  "allow_fail": true,
  "allow_exit_codes": [0, 10],
  "required_bank": "",
  "metric_keys": [
    "ai.tiercadence.tier0.eval_count",
    "ai.tiercadence.tier1.eval_count",
    "ai.tiercadence.tier2.eval_count",
    "ai.tiercadence.tier3.eval_count",
    "ai.tiercadence.digest"
  ]
}
```

## Space4x: `space4x_battle_slice_01_profilebias.json` (PR #49)

```json
"S0.SPACE4X_BATTLE_SLICE_01_PROFILEBIAS": {
  "project": "space4x",
  "runner": "space4x_loader",
  "scenario_path": "space4x/Assets/Scenarios/space4x_battle_slice_01_profilebias.json",
  "tick_budget": 2000,
  "timeout_s": 1200,
  "seed_policy": "none",
  "default_seeds": [43107],
  "default_pack": "nightly-default",
  "tags": ["informational", "micro", "space4x"],
  "allow_fail": true,
  "allow_exit_codes": [0, 10],
  "required_bank": "",
  "metric_keys": [
    "space4x.battle.profilebias.side0.avg_enemy_range",
    "space4x.battle.profilebias.side1.avg_enemy_range",
    "space4x.battle.profilebias.side0.flank_ratio",
    "space4x.battle.profilebias.side1.flank_ratio",
    "space4x.battle.profilebias.range_delta",
    "space4x.battle.profilebias.flank_ratio_delta"
  ]
}
```
