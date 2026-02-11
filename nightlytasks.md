# Nightly task mapping

Source: Tools/nightlylist.md
Tasks: Tools/Tools/Headless/headless_tasks.json
Start here for pipeline usage: Tools/Polish/Docs/HEADLESS_DOCS_INDEX.md

## Bank mapping
| Bank ID | Headless task | Scenario | Required bank | Status |
| --- | --- | --- | --- | --- |
| F0.CONTRACT_CHECK | - | - | - | MISSING |
| F0.FLAKE_POLICY | - | - | - | MISSING |
| F0.TELEMETRY_HEALTH | - | - | - | MISSING |
| G0.GODGAME_COMBAT_MICRO | G0.GODGAME_COMBAT_MICRO | godgame/Assets/Scenarios/Godgame/godgame_collision_micro.json | G0.GODGAME_COLLISION_MICRO | READY |
| G0.GODGAME_PATHING_MICRO | G0.GODGAME_PATHING_MICRO | godgame/Assets/Scenarios/Godgame/villager_movement_diagnostics.json | G2.VILLAGER_MOVEMENT_DIAGNOSTICS | READY |
| G0.GODGAME_SMOKE | G0.GODGAME_SMOKE | godgame/Assets/Scenarios/Godgame/godgame_smoke.json | G0.GODGAME_SMOKE | READY |
| G1.GODGAME_AI_INTENT_DECISIONS | - | - | - | MISSING |
| G1.GODGAME_ECONOMY_LOOP | G1.GODGAME_ECONOMY_LOOP | godgame/Assets/Scenarios/Godgame/villager_loop_small.json | G1.VILLAGER_LOOP_SMALL | READY |
| G1.GODGAME_FORMATIONS | - | - | - | MISSING |
| G1.GODGAME_SCALE_SMOKE | G1.GODGAME_SCALE_SMOKE | godgame/Assets/Scenarios/Godgame/godgame_scale_50k.json |  | READY |
| G2.GODGAME_LONG_SOAK | - | - | - | MISSING |
| S0.SPACE4X_COMBAT_FIRE_MICRO | S0.SPACE4X_COMBAT_FIRE_MICRO | space4x/Assets/Scenarios/space4x_dogfight_headless.json | S0.SPACE4X_COMBAT_FIRE_MICRO | READY |
| S0.SPACE4X_MINING_PROOF | S0.SPACE4X_MINING_PROOF | .tri/scenarios/space4x_mining.json | S1.MINING_ONLY | READY |
| S0.SPACE4X_NAV_REACH_TARGET_MICRO | S0.SPACE4X_NAV_REACH_TARGET_MICRO | space4x/Assets/Scenarios/space4x_turnrate_micro.json | S0.SPACE4X_NAV_REACH_TARGET_MICRO | READY |
| S0.SPACE4X_SENSORS_CONTACTS_MICRO | S0.SPACE4X_SENSORS_CONTACTS_MICRO | space4x/Assets/Scenarios/space4x_sensors_micro.json | S0.SPACE4X_SENSORS_CONTACTS_MICRO | READY |
| S0.SPACE4X_SMOKE | S0.SPACE4X_SMOKE | space4x/Assets/Scenarios/space4x_smoke.json | S0.SPACE4X_SMOKE | READY |
| S1.SPACE4X_CARRIER_LAUNCH_RECOVER | - | - | - | MISSING |
| S1.SPACE4X_COMBAT_TTK_BAND | - | - | - | MISSING |
| S1.SPACE4X_COMMS_COHESION | S1.SPACE4X_COMMS_COHESION | space4x/Assets/Scenarios/space4x_comms_micro.json | S1.SPACE4X_COMMS_COHESION | READY |
| S1.SPACE4X_CREW_ASSIGNMENT | - | - | - | MISSING |
| S1.SPACE4X_CREW_TEMPLATES_LOAD | - | - | - | MISSING |
| S1.SPACE4X_FTL_JUMP_MICRO | S1.SPACE4X_FTL_JUMP_MICRO | space4x/Assets/Scenarios/space4x_ftl_micro.json | S4.SPACE4X_FTL_MICRO | READY |
| S1.SPACE4X_PRODUCTION_CHAIN | - | - | - | MISSING |
| S1.SPACE4X_RELATIONS_DECISION_MICRO | - | - | - | MISSING |
| S1.SPACE4X_RESOURCE_LOGIC_SANITY | - | - | - | MISSING |
| S1.SPACE4X_SENSORS_TRACKING_QUALITY | - | - | - | MISSING |
| S2.SPACE4X_FULL_MVP_LOOP | - | - | - | MISSING |
| S2.SPACE4X_LONG_SOAK_STABILITY | - | - | - | MISSING |

## Extra headless tasks (not in bank)
| Task ID | Scenario | Required bank |
| --- | --- | --- |
| P0.TIME_REWIND_MICRO | puredots/Packages/com.moni.puredots/Runtime/Runtime/Scenarios/Samples/headless_time_rewind_short.json |  |
| S0.SPACE4X_COLLISION | space4x/Assets/Scenarios/space4x_collision_micro.json | S0.SPACE4X_COLLISION_MICRO |
| S2.SPACE4X_MINING_COMBAT | .tri/scenarios/space4x_mining_combat.json | S2.MINING_COMBAT |
| S3.SPACE4X_REFIT_REPAIR | space4x/Assets/Scenarios/space4x_refit.json | S3.REFIT_REPAIR |
| S4.SPACE4X_RESEARCH_MVP | space4x/Assets/Scenarios/space4x_research_mvp.json | S4.RESEARCH_MVP |
