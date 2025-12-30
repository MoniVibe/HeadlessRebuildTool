# Headless Tasks

Mini goals for headless agents to pursue during unattended runs.
Scope: logic-only changes (no `Assets/` or `.meta` edits). Update status as goals are achieved.

## Rules
- Use WSL clone `/home/oni/Tri` for logic changes; avoid `/mnt/c` for active WSL work.
- Do not touch `Assets/` or `.meta` from WSL (presentation owns those files).
- When rebuilding, align `UNITY_WIN` to the Unity version in `ProjectSettings/ProjectVersion.txt` for the target repo.
- Keep `Packages/manifest.json` and `Packages/packages-lock.json` in sync across clones when logic changes.
- Scenario authoring is allowed only in headless-only locations (prefer `/home/oni/Tri/.tri/scenarios` or `$TRI_STATE_DIR/scenarios`); always reference the explicit scenario path in task notes.
- Each task must include a scenario, measurable metric, and target threshold.
- If a metric is missing, add minimal telemetry to support it.
- If a bank failure is fixed or proof/env toggles change, update the runbook/prompt in the same cycle and note the update in the cycle log.
- Nightly headless agents must attempt at least one task per cycle and update this file with baseline/threshold and status (even if still pending).
- Keep tasks project-scoped: Godgame agents use Godgame + Cross-cutting tasks; Space4X agents use Space4X + Cross-cutting tasks.
- Task-first budget: max 6 runs per cycle; at least 2 runs must be tied to the chosen headlesstask. Only rerun Tier 0 if a build/scenario/env changed or a failure needs the two-run rule.
- If a task is blocked (Assets/.meta) for 2 consecutive cycles, switch tasks and log the blocker.
- If a task needs `Assets/` or `.meta` changes, log the requirement here and switch to another task.

## Cycle Log (append-only)
Append one entry per cycle below. Capture baseline/threshold even if the task is still pending.
Format:
- UTC:
- Agent:
- Project:
- Task:
- Scenario:
- Baseline:
- Threshold:
- Action:
- Result:
- Notes:
- UTC: 2025-12-30T21:11:25Z
- Agent: headless-godgame
- Project: Godgame
- Task: H-C04 Telemetry health
- Scenario: /home/oni/Tri/godgame/Assets/Scenarios/Godgame/godgame_smoke.json
- Baseline: sizes 5,769,701 and 4,190,005 bytes (summary telemetry)
- Threshold: <= 7,000,000 bytes; no truncation markers
- Action: Ran G0.GODGAME_SMOKE twice with summary telemetry; checked file size + stdout for truncation markers
- Result: PASS
- Notes: No truncation markers in stdout; sizes well below cap.
- UTC: 2025-12-30T21:04:40Z
- Agent: headless-godgame
- Project: Godgame
- Task: H-C03 Determinism smoke
- Scenario: /home/oni/Tri/godgame/Assets/Scenarios/Godgame/godgame_smoke.json
- Baseline: tick=39 villagers=59 storehouses=5 stored=7.00
- Threshold: exact match (epsilon=0) across 2 runs
- Action: Ran G0.GODGAME_SMOKE twice with villager proof exit; compared villager/storehouse/stored values from proof log
- Result: PASS (run1==run2)
- Notes: Build 6000.3.1f1 via Windows Unity; default scenario seed.
- UTC: 2025-12-30T20:49:35Z
- Agent: codex-wsl
- Project: Space4X
- Task: H-S03 Collision micro stability
- Scenario: space4x/Assets/Scenarios/space4x_collision_micro.json
- Baseline: NaN/Inf=0 (2 runs; telemetry 20251230_224230, 20251230_224310)
- Threshold: NaN/Inf=0
- Action: Ran S0 collision micro twice with SPACE4X_HEADLESS_MINING_PROOF=0; scanned telemetry for NaN/Infinity tokens
- Result: Baseline set; no NaN/Inf detected
- Notes: Initial collision run tripped Space4XHeadlessMiningProof; disabled mining proof for collision/smoke.

## Cross-cutting
- H-C01 Frame-rate independence (Godgame). Scenario: `godgame/Assets/Scenarios/Godgame/villager_loop_small.json`. Metric: end-of-run total resource delta (pile + storehouse). Target: 30 vs 120 tick rate drift <= 1 unit. Status: pending.
- H-C02 Resource conservation (Godgame). Scenario: `godgame/Assets/Scenarios/Godgame/villager_loop_small.json`. Metric: AggregatePile.Take/Add and Storehouse.Add totals. Target: siphon 200 and dump 200 with no loss; events match totals. Status: pending.
- H-C03 Determinism smoke (Godgame). Scenario: `godgame/Assets/Scenarios/Godgame/godgame_smoke.json`. Metric: end-tick counts (villagers, storehouse totals). Target: same seed produces identical summary within epsilon. Baseline: tick=39 villagers=59 storehouses=5 stored=7.00 (seed default). Threshold: exact match (epsilon=0) across 2 consecutive runs. Status: flaky (requires two identical runs; last run drifted).
- H-C04 Telemetry health (all). Scenario: any headless run. Metric: telemetry payload length and file size. Target: no payload truncation and no sudden spikes above expected bounds. Baseline: godgame_smoke sizes 5,769,701 and 4,190,005 bytes (summary telemetry). Threshold: <= 7,000,000 bytes; no truncation markers. Status: pass (cycle50).

## Godgame
- H-G01 Villager loop latency. Scenario: `godgame/Assets/Scenarios/Godgame/villager_loop_small.json`. Metric: time from siphon start -> storehouse add. Target: average latency <= baseline, no long-tail stalls. Status: pending.
- H-G02 Idle ratio. Scenario: `godgame/Assets/Scenarios/Godgame/villager_loop_small.json`. Metric: idle ticks / total ticks. Target: <= target threshold after warm-up (set baseline, then enforce). Status: pending.
- H-G03 Task scheduling liveliness. Scenario: `godgame/Assets/Scenarios/Godgame/villager_loop_small.json`. Metric: task queue non-empty while work exists. Target: no starvation window > N ticks. Status: pending.
- H-G04 Stuck movement. Scenario: `godgame/Assets/Scenarios/Godgame/villager_movement_diagnostics.json`. Metric: units with zero displacement for N seconds. Target: 0 after warm-up. Status: pending.

## Space4X
- H-S01 Mining throughput. Scenario: `space4x/Assets/Scenarios/space4x_mining.json`. Metric: total yield per simulated minute. Target: >= baseline; no regressions. Status: pending.
- H-S02 Dropoff stall. Scenario: `space4x/Assets/Scenarios/space4x_mining.json`. Metric: time from full cargo -> dropoff. Target: no stall events after warm-up. Status: pending.
- H-S03 Collision micro stability. Scenario: `space4x/Assets/Scenarios/space4x_collision_micro.json`. Metric: velocity/position NaNs, excessive spikes. Target: zero NaNs, bounded deltas. Status: baseline set (NaN/Inf=0 on 2 runs; spikes pending).
- H-S04 Fleet cohesion. Scenario: `space4x/Assets/Scenarios/space4x_smoke.json`. Metric: miner distance to carrier band. Target: within band for > X% of ticks. Status: pending.

## Movement + Steering
- H-M01 Movement smoothness. Scenario: `godgame/Assets/Scenarios/Godgame/villager_movement_diagnostics.json`. Metric: acceleration/jerk bounds + overshoot. Target: no oscillation; overshoot below threshold. Status: pending.
- H-M02 Path efficiency. Scenario: `godgame/Assets/Scenarios/Godgame/villager_movement_diagnostics.json`. Metric: actual distance / straight-line distance. Target: <= 1.2 after warm-up. Status: pending.
- H-M03 Avoidance separation. Scenario: `godgame/Assets/Scenarios/Godgame/villager_movement_diagnostics.json`. Metric: min separation vs collision radius. Target: no interpenetration; min separation >= radius. Status: pending.
- H-M04 Heading stability. Scenario: `space4x/Assets/Scenarios/space4x_mining.json`. Metric: heading variance during straight travel. Target: <= baseline after warm-up. Status: pending.

## Intent + Needs
- H-I01 Need response time. Scenario: `godgame/Assets/Scenarios/Godgame/villager_loop_small.json`. Metric: need threshold -> task assignment latency. Target: <= target ticks. Status: pending.
- H-I02 Intent thrash. Scenario: `godgame/Assets/Scenarios/Godgame/villager_loop_small.json`. Metric: intent switches per minute. Target: <= threshold. Status: pending.
- H-I03 Task churn. Scenario: `godgame/Assets/Scenarios/Godgame/villager_loop_small.json`. Metric: canceled/restarted tasks per minute. Target: <= threshold. Status: pending.
- H-I04 Idle-with-work. Scenario: `godgame/Assets/Scenarios/Godgame/villager_loop_small.json`. Metric: idle ticks while work exists. Target: <= threshold after warm-up. Status: pending.

## Resource Flow (Godgame)
- H-R01 Storehouse utilization band. Scenario: `godgame/Assets/Scenarios/Godgame/villager_loop_small.json`. Metric: storehouse fill ratio. Target: stay within band; no sustained overfill. Status: pending.
- H-R02 Transfer fairness. Scenario: `godgame/Assets/Scenarios/Godgame/villager_loop_small.json`. Metric: distribution across storehouses. Target: skew ratio <= threshold. Status: pending.
- H-R03 Backlog drain. Scenario: `godgame/Assets/Scenarios/Godgame/villager_loop_small.json`. Metric: queued deliveries. Target: drains to near-zero within N ticks. Status: pending.

## Space4X Loop Quality
- H-SQ01 Mining routing. Scenario: `space4x/Assets/Scenarios/space4x_mining.json`. Metric: average travel distance to asteroid. Target: <= baseline. Status: pending.
- H-SQ02 Docking service time. Scenario: `space4x/Assets/Scenarios/space4x_mining.json`. Metric: time from full cargo -> dropoff complete. Target: <= threshold. Status: pending.
- H-SQ03 Cohesion under stress. Scenario: `space4x/Assets/Scenarios/space4x_mining_combat.json`. Metric: miner-to-carrier distance band during combat. Target: within band for > X% of ticks. Status: pending.

## Telemetry Integrity
- H-T01 Event ordering. Scenario: any headless run. Metric: monotonic tick + no duplicate IDs. Target: 0 violations. Status: pending.
- H-T02 Payload stability. Scenario: any headless run. Metric: payload truncation and event rate. Target: zero truncation; stable rate within bounds. Status: pending.

## Advanced Combat Tactics (Space4X)
- H-CA01 Flanking behavior. Scenario: `space4x/Assets/Scenarios/space4x_mining_combat.json`. Metric: flank angle at first contact. Target: >= baseline flank rate with no path stalls. Status: pending.
- H-CA02 Kiting behavior. Scenario: `space4x/Assets/Scenarios/space4x_mining_combat.json`. Metric: time within kite distance band while firing. Target: >= threshold; no oscillation. Status: pending.
- H-CA03 Focus fire. Scenario: `space4x/Assets/Scenarios/space4x_mining_combat.json`. Metric: targets engaged concurrently. Target: reduce target spread; improved time-to-kill. Status: pending.
- H-CA04 Retreat logic. Scenario: `space4x/Assets/Scenarios/space4x_mining_combat.json`. Metric: retreat triggers before critical hull; survival rate. Target: <= threshold for suicides. Status: pending.

## Production Chains (Godgame)
- H-P01 Chain conservation. Scenario: `godgame/Assets/Scenarios/Godgame/godgame_smoke.json`. Metric: input consumed vs output produced per chain. Target: no negative deltas; output <= expected ratios. Status: pending.
- H-P02 Bottleneck detection. Scenario: `godgame/Assets/Scenarios/Godgame/godgame_smoke.json`. Metric: idle reason codes when input is missing. Target: telemetry exposes bottlenecks; no silent stalls. Status: pending.
- H-P03 Throughput optimization. Scenario: `godgame/Assets/Scenarios/Godgame/godgame_smoke.json`. Metric: output per worker per minute. Target: >= baseline without regressions. Status: pending.
- H-P04 Waste minimization. Scenario: `godgame/Assets/Scenarios/Godgame/godgame_smoke.json`. Metric: dropped/spoiled/overflowed resources. Target: <= threshold. Status: pending.

## Strike Craft + Formations (Space4X)
- H-SF01 Formation coherence. Scenario: `space4x/Assets/Scenarios/space4x_mining_combat.json`. Metric: RMS deviation from formation offsets. Target: <= threshold after warm-up. Status: pending.
- H-SF02 Re-form time. Scenario: `space4x/Assets/Scenarios/space4x_mining_combat.json`. Metric: time to re-acquire formation after disturbance. Target: <= N ticks. Status: pending.
- H-SF03 Maneuver response. Scenario: `space4x/Assets/Scenarios/space4x_mining_combat.json`. Metric: time to align to new heading/target. Target: <= threshold. Status: pending.
- H-SF04 Separation under combat. Scenario: `space4x/Assets/Scenarios/space4x_mining_combat.json`. Metric: min craft-to-craft separation. Target: no interpenetration; min separation >= radius. Status: pending.

## Proto-learning (Optional)
- H-L01 Single-parameter tuning. Scenario: `godgame/Assets/Scenarios/Godgame/villager_loop_small.json`. Metric: improve one primary metric (latency, idle ratio, or throughput). Target: >= X% improvement over baseline in one run, gated by debug flag. Status: pending.

## Communications + Cooperation
- H-CC01 Task handoff latency (Godgame). Scenario: `godgame/Assets/Scenarios/Godgame/godgame_smoke.json`. Metric: ticks from intent/task emission -> first worker pickup. Target: <= 120 ticks after warm-up. Status: pending.
- H-CC02 Cooperative completion rate (Godgame). Scenario: `godgame/Assets/Scenarios/Godgame/villager_loop_small.json`. Metric: multi-actor tasks completed / started. Target: >= 0.9, no abandonment spikes. Status: pending.
- H-CC03 Squad response time (Space4X). Scenario: `space4x/Assets/Scenarios/space4x_mining_combat.json`. Metric: time from fleet command -> first unit action. Target: <= 180 ticks, no long-tail stalls. Status: pending.

## Strategic + Aggregate AI (Space4X)
- H-SA01 Objective stability. Scenario: `space4x/Assets/Scenarios/space4x_mining_combat.json`. Metric: strategic objective switches per simulated minute. Target: <= 2 after warm-up. Status: pending.
- H-SA02 Allocation efficiency. Scenario: `space4x/Assets/Scenarios/space4x_mining.json`. Metric: active miners assigned to top-yield targets / total miners. Target: >= 0.8 sustained. Status: pending.
- H-SA03 Threat response latency. Scenario: `space4x/Assets/Scenarios/space4x_mining_combat.json`. Metric: ticks from hostile appearance -> reassigned defenders. Target: <= 240 ticks. Status: pending.

## Relations + Diplomacy (Godgame)
- H-D01 Relation stability. Scenario: `godgame/Assets/Scenarios/Godgame/godgame_smoke.json`. Metric: relation edge flips per in-game day. Target: <= threshold; no oscillation. Status: pending.
- H-D02 Diplomacy throughput. Scenario: `godgame/Assets/Scenarios/Godgame/godgame_smoke.json`. Metric: diplomacy events per in-game day. Target: >= baseline with no spam bursts. Status: pending.
- H-D03 Coalition formation. Scenario: `godgame/Assets/Scenarios/Godgame/godgame_smoke.json`. Metric: % of aligned agents forming stable groups. Target: >= baseline after warm-up. Status: pending.

## Craft + Vessel Production Chains (Space4X)
- H-PC01 Craft chain conservation. Scenario: `space4x/Assets/Scenarios/space4x_mining.json`. Metric: inputs consumed vs outputs produced per craft chain. Target: no negative deltas; output <= expected ratios. Status: pending.
- H-PC02 Queue-to-launch latency. Scenario: `space4x/Assets/Scenarios/space4x_mining.json`. Metric: time from craft order -> spawn. Target: <= threshold after warm-up. Status: pending.
- H-PC03 Supply pressure. Scenario: `space4x/Assets/Scenarios/space4x_mining.json`. Metric: production stalls due to missing inputs. Target: <= baseline, no silent stalls. Status: pending.

## Lifecycle + Progression (Space4X)
- H-LC01 Promotion ladder. Scenario: `space4x/Assets/Scenarios/space4x_smoke.json`. Metric: time from spawn -> first promotion. Target: <= threshold; at least one promotion. Status: pending.
- H-LC02 Rank stability. Scenario: `space4x/Assets/Scenarios/space4x_smoke.json`. Metric: promotions + demotions per unit per day. Target: low oscillation; no rapid flip-flop. Status: pending.
- H-LC03 Career completion. Scenario: `space4x/Assets/Scenarios/space4x_smoke.json`. Metric: % of units reaching mid-rank (e.g., lieutenant). Target: >= baseline after N days. Status: pending.

## Procedural Learning (PureDOTS)
- H-PL01 Parameter sweep gains. Scenario: `godgame/Assets/Scenarios/Godgame/villager_loop_small.json`. Metric: primary KPI improvement vs baseline. Target: >= 5% with no new regression counters. Status: pending.
- H-PL02 Stability guard. Scenario: `space4x/Assets/Scenarios/space4x_mining.json`. Metric: regression counters and NaN events. Target: zero increases after tuning. Status: pending.
- H-PL03 Movement auto-tuning. Scenario: `godgame/Assets/Scenarios/Godgame/villager_movement_diagnostics.json`. Metric: jerk/overshoot reductions. Target: >= 10% improvement without path efficiency regressions. Status: pending.

## PureDOTS Core MVPs
- H-PD01 Comms bridge MVP. Scenario: `$TRI_STATE_DIR/scenarios/puredots_comms_bridge_micro.json`. Metric: `CommSendRequest` -> `CommReceipt` ratio + ack latency. Target: >= 0.95 receipts; median ack <= 60 ticks. Status: pending.
- H-PD02 Signal sampling radius. Scenario: `$TRI_STATE_DIR/scenarios/puredots_signal_radius_micro.json`. Metric: non-zero samples at 1-2 cell offsets; zero beyond range. Target: detection within range by 30 ticks; no out-of-range detections. Status: pending.
- H-PD03 LOS gating. Scenario: `$TRI_STATE_DIR/scenarios/puredots_los_micro.json`. Metric: occluded target confidence/detections vs unobstructed baseline. Target: occluded confidence <= 0.2 or detections <= 10% of baseline. Status: pending.
- H-PD04 Commitment window. Scenario: `godgame/Assets/Scenarios/Godgame/villager_loop_small.json`. Metric: goal/intent switches per minute. Target: <= 2 after warm-up. Status: pending.
- H-PD05 AI policy profile wiring. Scenario: `space4x/Assets/Scenarios/space4x_smoke.json`. Metric: % AI entities with policy component + budget adherence. Target: >= 0.9 coverage; no budget overruns. Status: pending.
- H-PD06 Cooperation session primitive. Scenario: `$TRI_STATE_DIR/scenarios/puredots_coop_session_micro.json`. Metric: session completion + contribution sum. Target: completes <= 300 ticks; contributions == required. Status: pending.

## Performance + Determinism
- H-PF01 100k soak stability. Scenario: `$TRI_STATE_DIR/scenarios/puredots_100k_soak.json`. Metric: avg tick time + memory delta. Target: avg tick time <= baseline + 10%; no unbounded growth. Status: pending.
- H-PF02 Rewind hash determinism. Scenario: `Packages/com.moni.puredots/Runtime/Runtime/Scenarios/Samples/headless_time_rewind_short.json`. Metric: tick hash/summary equality across 2 runs. Target: identical hashes. Status: pending.
- H-PF03 Perception/AI budget counters. Scenario: `space4x/Assets/Scenarios/space4x_mining.json`. Metric: counters for perception/sensor/AI work. Target: all counters <= configured budgets. Status: pending.

## Physics + Collision (Long Term)
- H-PLT01 Impulse collision response. Scenario: `$TRI_STATE_DIR/scenarios/physics_impulse_micro.json`. Metric: post-collision velocity changes vs mass/impulse. Target: conserve momentum within tolerance; no tunneling. Status: pending.
- H-PLT02 Multi-body interaction. Scenario: `$TRI_STATE_DIR/scenarios/physics_chain_push_micro.json`. Metric: chain reaction propagation through multiple bodies. Target: energy transfer follows mass ratios; no stuck overlap. Status: pending.
- H-PLT03 Push/slide stability. Scenario: `$TRI_STATE_DIR/scenarios/physics_slide_micro.json`. Metric: contact resolution + separation. Target: no jitter; separation >= radius after resolve. Status: pending.
- H-PLT04 Restitution tuning. Scenario: `$TRI_STATE_DIR/scenarios/physics_restitution_micro.json`. Metric: coefficient of restitution vs bounce height/speed. Target: observed restitution within ±0.05 of configured value. Status: pending.
- H-PLT05 Angular impulse response. Scenario: `$TRI_STATE_DIR/scenarios/physics_angular_impulse_micro.json`. Metric: angular velocity change vs applied torque and inertia. Target: within ±10% of expected. Status: pending.

## Combat Systems (Long Term)
- H-CB01 Godgame knockback response. Scenario: `$TRI_STATE_DIR/scenarios/godgame_knockback_micro.json`. Metric: displacement/velocity vs impulse + mass. Target: within tolerance; no interpenetration after resolve. Status: pending.
- H-CB02 Godgame damage resolution. Scenario: `$TRI_STATE_DIR/scenarios/godgame_damage_micro.json`. Metric: health delta per hit + death state transitions. Target: exact expected deltas; no double-applies. Status: pending.
- H-CB03 Space4X damage pipeline. Scenario: `$TRI_STATE_DIR/scenarios/space4x_damage_layers_micro.json`. Metric: shield->armor->hull->module order + residual damage. Target: correct order; no skipped layers. Status: pending.
- H-CB04 Space4X module disable/repair. Scenario: `$TRI_STATE_DIR/scenarios/space4x_module_damage_micro.json`. Metric: module health/disable flags + repair recovery. Target: disable on threshold; recover on repair. Status: pending.
- H-CB05 Strike craft formation vs capital. Scenario: `$TRI_STATE_DIR/scenarios/space4x_strike_vs_capital_micro.json`. Metric: formation cohesion + attack window timing. Target: maintain offsets within threshold; coordinated strike within window. Status: pending.
- H-CB06 Strike craft vs strike craft. Scenario: `$TRI_STATE_DIR/scenarios/space4x_strike_vs_strike_micro.json`. Metric: separation + time-to-engage. Target: no interpenetration; engage within N ticks. Status: pending.
- H-CB07 Capital ship steering roles. Scenario: `$TRI_STATE_DIR/scenarios/space4x_capital_positioning_micro.json`. Metric: desired standoff distance + facing alignment by situation. Target: maintain band; correct orientation > X% ticks. Status: pending.
- H-CB08 Target selection stability. Scenario: `$TRI_STATE_DIR/scenarios/space4x_targeting_micro.json`. Metric: target switches per minute + time-to-kill. Target: <= threshold switches; improved TTK. Status: pending.

## Entity Agency + Collective Behavior (Long Term)
- H-EA01 Personal goal loop. Scenario: `$TRI_STATE_DIR/scenarios/agency_personal_goals_micro.json`. Metric: self-chosen goal selection + completion rate. Target: >= 0.8 completion; low thrash. Status: pending.
- H-EA02 Career progression. Scenario: `$TRI_STATE_DIR/scenarios/agency_career_progression_micro.json`. Metric: role changes + skill growth. Target: progression visible by N ticks; no dead-end loops. Status: pending.
- H-EA03 Collective formation. Scenario: `$TRI_STATE_DIR/scenarios/agency_guild_formation_micro.json`. Metric: group/guild formation events + stability. Target: >= 1 stable group; churn <= threshold. Status: pending.
- H-EA04 Solo roaming + leveling. Scenario: `$TRI_STATE_DIR/scenarios/agency_solo_roam_micro.json`. Metric: exploration coverage + level gains. Target: coverage >= baseline; level gains > 0. Status: pending.
- H-EA05 Multi-party management. Scenario: `$TRI_STATE_DIR/scenarios/agency_multi_party_micro.json`. Metric: party assignment balance + task throughput. Target: balanced utilization; no idle parties with work. Status: pending.
- H-EA06 Strategic planning at entity scale. Scenario: `$TRI_STATE_DIR/scenarios/agency_entity_strategic_micro.json`. Metric: plan horizon length + plan success rate. Target: >= 0.7 success; no runaway plan churn. Status: pending.
- H-EA07 Empire management by entity. Scenario: `$TRI_STATE_DIR/scenarios/agency_empire_manager_micro.json`. Metric: resource stability + policy shifts. Target: stability within band; no oscillatory policies. Status: pending.
- H-EA08 Post-task roaming. Scenario: `$TRI_STATE_DIR/scenarios/agency_idle_roam_micro.json`. Metric: % idle time spent at last task location + movement entropy. Target: <= 0.3 idle-at-origin; entropy above baseline. Status: pending.

## Godgame MVP Slices
- H-GM05 Miracle detection. Scenario: `$TRI_STATE_DIR/scenarios/godgame_miracle_detection_micro.json`. Metric: miracle entity appears in perception/AI readings. Target: detection within 120 ticks. Status: pending.
- H-GM06 Miracle interrupt. Scenario: `$TRI_STATE_DIR/scenarios/godgame_miracle_interrupt_micro.json`. Metric: interrupt ticket/emergency intent triggered on miracle. Target: >= 1 interrupt within 120 ticks; no spam. Status: pending.
- H-GM07 Mana grid MVP. Scenario: `$TRI_STATE_DIR/scenarios/godgame_mana_grid_micro.json`. Metric: ambient mana increases near emitter, decays when removed. Target: monotonic rise then decay; no negative values. Status: pending.
- H-GA07 Village aggregation integrity. Scenario: `godgame/Assets/Scenarios/Godgame/godgame_smoke.json`. Metric: aggregate snapshot matches sum of member resources. Target: delta <= 1 unit. Status: pending.
- H-GA08 Group objective latency. Scenario: `$TRI_STATE_DIR/scenarios/godgame_threat_micro.json`. Metric: ticks from threat spawn -> group objective set. Target: <= 240 ticks. Status: pending.
- H-GP05 Pleads/prayers MVP. Scenario: `$TRI_STATE_DIR/scenarios/godgame_pleads_micro.json`. Metric: plea events under distress + spam rate. Target: >= 1 plea under threshold; <= 1 plea per 300 ticks. Status: pending.

## Space4X MVP Slices
- H-SX05 Alignment/compliance trigger. Scenario: `$TRI_STATE_DIR/scenarios/space4x_alignment_micro.json`. Metric: compliance events under mismatch; no mutiny under alignment. Target: mismatch triggers >= 1 event; aligned = 0 mutinies. Status: pending.
- H-SX06 Mobility graph resolution. Scenario: `$TRI_STATE_DIR/scenarios/space4x_mobility_graph_micro.json`. Metric: path requests resolved + time to first path. Target: 100% resolved; first path <= 120 ticks. Status: pending.
- H-SX07 Tech diffusion MVP. Scenario: `$TRI_STATE_DIR/scenarios/space4x_tech_diffusion_micro.json`. Metric: diffusion reach. Target: >= 50% nodes within 600 ticks. Status: pending.
- H-SX08 Situation phase progression. Scenario: `$TRI_STATE_DIR/scenarios/space4x_situation_brownout_micro.json`. Metric: ordered phase transitions + event counts. Target: no skipped phases; events match phase. Status: pending.
- H-SX09 Refit/repair loop MVP. Scenario: `$TRI_STATE_DIR/scenarios/space4x_refit_micro.json`. Metric: refit start -> completion + maintenance events. Target: completion <= 600 ticks; events > 0. Status: pending.
