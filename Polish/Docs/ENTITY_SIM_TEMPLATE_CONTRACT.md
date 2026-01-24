# Entity/Ship Simulation Template Contract (v0)

Purpose: codify the intended simulation model so nightly work stays aligned with real mechanics.
This is a design contract, not a mandate for immediate implementation.

## North Star
- Ships are containers of entities; crew (or AI/hive) drives performance.
- Outcomes (time to first hit, stability, alignment) must be emergent from the sim.
- Scenarios stay small and deterministic; simulation inside them is real and dynamic.

## Entity Template (v0)
Each entity is a blank ID card with runtime-modifiable parts.
- Identity: id, affiliation, culture, role.
- Body: limbs[], organs[], sensory_limbs[].
- Mind: consciousness, reaction_time_ms, focus, fatigue.
- Skills: per-role skill profile (pilot, nav, weapons, systems).
- Modifiers: augments[], status_effects[].
- Behavior profile: profile_id (selects decision weights/heuristics).

Mutability (non-negotiable):
- Limbs/organs/sensors are mutable, replaceable, and augmentable at runtime.
- Bodies can be controlled as vehicles/ships or act as autonomous agents.
- Sensors can be deceived or degraded (countermeasures, damage, status effects).
- All template fields should allow overrides and runtime state changes.

## Ship Template (v0)
Ships are physical systems plus governance.
- Physics: mass, thrust, inertia, angular_limits.
- Power: capacity, draw_by_system, brownout rules.
- Protection: hull, armor, shields (if applicable).
- Systems: targeting, nav, weapons, sensors, comms (each with state).
- Governance: autonomous | crewed | hive | hybrid.
- Station requirements: which roles are required, optional, or pooled.

## Station Assignment Contract
- Station -> entity mapping is explicit (pilot, nav, weapons, systems).
- Missing stations degrade performance but do not crash the sim.
- Cohesion and comms influence cross-station handoffs (e.g., spinal alignment).

## Scenario Contract (v0)
Scenarios should reference templates + overrides, not full entities.
- Scenario defines: ship_template + crew_template + overrides (seeded).
- Overrides may adjust single axes (injury, augments, skill deltas).
- Keep scenarios minimal (2-4 ships) but mechanically faithful.

## Metrics and Proof (must be emergent)
- Primary metric: time to first hit (TTFH) from real sim state transitions.
- Supporting metrics: solution_time, alignment_error, stability, hit_rate.
- Proof must be BANK PASS or validate_metric_keys + thresholds.
- Do not compute the outcome via weighted formulas; weights are diagnostics only.

## Determinism and Performance
- Fixed seeds; avoid nondeterministic calls.
- Keep per-tick loops bounded; prefer cached lookups.
- Emit sparse telemetry; cap size and avoid truncation.

## Implementation Phases (suggested)
- P0: telemetry hooks + proof markers only (no gameplay change).
- P1: template-driven spawner + crew assignment.
- P2: reaction time + station handoff effects.
- P3: limb/organ/augment effects + injuries/status.

## Nightly Guardrails
- One variable per iteration (code OR scenario).
- No Assets/.meta edits at night; queue asset requests only.
- Do not tune behavior on INVALID evidence.
