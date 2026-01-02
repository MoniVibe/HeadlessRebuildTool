# Telemetry Playbook (Metrics-First)

Purpose: help agents improve behavior without overfitting to logs or changing oracles mid-cycle. Start with metrics_summary, use traces only when a metric trips.

## Guardrails (run validity)

If any of these are true, the run is invalid and behavior should NOT be tuned:
- telemetry.truncated != 0
- any invariant failure (NaN/Inf, non-monotonic ticks, negative resources)
- missing required oracle keys

## Oracle Contract (no silent changes)

- Oracles are contracts. If a metric is removed/renamed, do it as a telemetry-only change (separate PR), not mixed with behavior tuning.
- One lever per cycle. Do not change controller gains, avoidance radii, and path smoothing in the same change.

## Metrics-First Workflow

1) Read metrics_summary and compare to last-known-good.
2) Choose one primary regression metric.
3) Apply one minimal change.
4) Re-run and confirm the metric moves in the right direction without safety regressions.
5) Only use event/replay traces after a metric trips and the root cause is unclear.

## Space4X Ship Motion

### Watchlist
- s4x.heading_oscillation_score
- s4x.approach_mode_flip_rate
- s4x.turn_saturation_time_s
- move.mode_flip_count
- move.collision_near_miss_count / move.collision_damage_events
- move.stuck_ticks

### Control Model (copy ORCA-style interface)
- planner -> preferred velocity/heading
- local avoidance -> safe velocity correction
- controller -> rate limits (deadband, angular accel clamp) to avoid oscillation

### Cookbook

| Metric regression | Likely causes | Allowed fixes (one per cycle) | Confirmation metrics |
| --- | --- | --- | --- |
| s4x.turn_saturation_time_s high | No angular accel cap; heading setpoint changes too often; no slow-down while turning | Add heading deadband; add angular accel clamp; scale speed by heading error; add min dwell before mode/setpoint change | turn_saturation_time_s down; mode_flip_count down; near_miss/damage not worse |
| s4x.heading_oscillation_score high | No hysteresis or damping; deviation recomputed too often; target switches without commitment | Make deviation episode-stable; add approach/hold/arrive hysteresis; add damping or reduce gain near target; increase lookahead | heading_oscillation_score down; approach_mode_flip_rate down; stuck_ticks not worse |
| collision near-miss/damage high (oscillation low) | Avoidance envelope too small; yield policy missing | Increase avoidance radius/priority around friendlies; apply yield/slow policy when friendlies in envelope | near_miss down; damage down; oscillation not worse |

## Godgame Villager Loops

### Watchlist
- god.storehouse_loop_period_ticks.p95 (primary)
- ai.idle_with_work_ratio
- ai.task_latency_ticks.p95
- ai.decision_churn_per_min / ai.intent_flip_count
- god.ponder_freeze_time_s

### Cookbook

| Metric regression | Likely causes | Allowed fixes (one per cycle) | Confirmation metrics |
| --- | --- | --- | --- |
| storehouse_loop_period_ticks.p95 high | Hard idle snap after task; no micro-reposition; long-haul loops for all workers | Add micro-reposition/wander episode; chunk work; add intermediate depots; add job selection hysteresis; target cooldown | loop_period_p95 down; idle_with_work_ratio stable/low; churn not spiking |
| ponder_freeze_time_s high during work | Idle anchor is current position; no idle spatial variety | Choose idle anchors around hub; lawful = small roam radius, chaotic = larger roam radius (safety constrained) | ponder_freeze_time_s down; idle variety increases |

## Cross-Game Behavior Profiles (chaotic <-> lawful)

Make profiles data-driven in PureDOTS and tune via parameters, not hardcoded logic.

Parameters:
- CommitmentSeconds
- ReplanCadenceSeconds
- NoiseStrength (episode-stable, not per tick)
- RiskAversion (avoidance radius multiplier / yield strength)
- IdleRoamRadius
- FormationDiscipline

Expected telemetry signature:
- Lawful: lower churn + higher safety margin
- Chaotic: higher spatial entropy + slightly higher churn, but collision damage must not worsen

## New Metrics to Add (Backlog)

Space4X motion:
- move.min_friendly_separation_m (minimum distance to friendlies)
- move.time_to_collision_min_s (minimum predicted TTC vs friendly)
- move.angular_jerk_p95 (p95 of |delta angular accel|)
- move.avoid_override_time_s (time avoidance overrides desired heading)

Godgame spatial variety:
- god.idle_anchor_entropy (or simpler: god.idle_cluster_count / god.idle_mean_pair_distance_m)

## No-Regression Gate (always enforce)

- telemetry.truncated == 0
- move.collision_damage_events not worse
- move.stuck_ticks not worse
- Space4X: s4x.heading_oscillation_score down if that was the goal
- Godgame: god.storehouse_loop_period_ticks.p95 down if that was the goal

## When to Use Traces

Only after a metric trips and the root cause is ambiguous:
- Enable a short, bounded replay/trace (sampled pack).
- Keep it short; use it to explain causality, then return to metrics-only.
