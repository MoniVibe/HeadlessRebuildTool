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

## Anatomy + Conditions (v0)
- Body parts are hierarchical with coverage/target chance and subparts.
- Parts carry tags (LIMB, JOINT, INTERNAL) to express damage and reachability.
- Conditions (hediffs) attach to the whole entity or a specific part:
  - severity + stages + stat/capacity modifiers.
- Implants/augments are attachments to part slots and can be removed with part loss.

## Derived Capacities (stable interface)
- Derived from anatomy + conditions + skills (not hardcoded per part).
- Examples: Sight, Manipulation, Consciousness, Locomotion, ReactionTime.
- Some entities can ignore capacities (autonomous/hive) but must declare overrides.
- Stability lives here: ship systems consume capacities, not raw anatomy.

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

## Station/Action Consumption (v0)
- Stations consume capacities via thresholds and weights (not hardcoded limbs).
- Action vectors define which capacities are required:
  - Spinal targeting: Sight + Alignment + ReactionTime.
  - Boarding/anti-personnel: Sight + Manipulation + Consciousness.
- Failures degrade performance (latency, accuracy), never crash the sim.

## Scenario Contract (v0)
Scenarios should reference templates + overrides, not full entities.
- Scenario defines: ship_template + crew_template + overrides (seeded).
- Overrides may adjust single axes (injury, augments, skill deltas).
- Keep scenarios minimal (2-4 ships) but mechanically faithful.

## Proof Scenarios (micro)
- Crew existence proof: roster + station occupancy matches template (BANK PASS).
- Causality proof: targeted injury/condition shifts relevant station metrics.
- Autonomous vs crewed: capacity overrides behave as expected.

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

## Template Schema Sketch (v0 JSON)
Entity template (file: `Assets/Scenarios/Templates/entity.*.json`):
```json
{
  "templateId": "entity.baseline.v0",
  "statsPreset": "baseline",
  "skills": {
    "command": 60,
    "tactics": 60,
    "logistics": 60,
    "diplomacy": 55,
    "engineering": 55,
    "resolve": 60
  },
  "behaviorProfileId": "baseline",
  "anatomyPreset": "baseline",
  "conditions": ["one_eye_missing"]
}
```

Crew template (file: `Assets/Scenarios/Templates/crew.*.json`):
```json
{
  "templateId": "crew.sensors.v0",
  "namedCrew": [
    {
      "name": "SENS-BASELINE",
      "seatRole": "ship.sensors_officer",
      "statsPreset": "rookie",
      "entityTemplateId": "entity.baseline.v0"
    }
  ]
}
```

Ship template (file: `Assets/Scenarios/Templates/ship.*.json`):
```json
{
  "templateId": "ship.capitalship.v0",
  "governanceMode": "crewed",
  "stationRequirements": [
    { "seatRole": "ship.sensors_officer", "minCount": 1 }
  ]
}
```

Scenario reference (2-line crew setup):
```json
{
  "scenarioConfig": {
    "crewTemplates": [
      { "carrierId": "carrier-1", "crewTemplateId": "crew.sensors.v0" }
    ]
  }
}
```
