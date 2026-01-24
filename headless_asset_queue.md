> STATUS: LEGACY REFERENCE. Nightly is EngineerTick + queue + runner + intel/scoreboard.
> See: `Polish/Docs/HEADLESS_DOCS_INDEX.md`
> Still useful for: asset escalation requests when Assets/.meta changes are required.

# Headless Asset Queue

Append one entry per request. Keep it short and action-oriented.

Format:
- UTC:
- Project:
- Priority: (Tier0 | Tier1 | Task)
- Requester:
- Owner:
- Paths:
- Change:
- Repro:
- BuildStamp:
- Validation:
- Status: (NEW | CLAIMED | IN_PROGRESS | DONE | FAILED)

Asset batch policy:
- Assets/.meta edits are daytime-only and must be grouped into an approved batch.
- Nightly agents may only add queue entries; they must not edit Assets/.meta directly.

---
2026-01-23T21:41:00Z REQUEST: Address metric regression s4x.heading_oscillation_score (failure_signature=996df7ccf3c30578fab524a8b0a9c5988885d358811af6476f9c25ea62188035). Likely in Space4x Assets/Scripts/Space4x/Systems/AI/VesselMovementSystem.cs: add approach/hold hysteresis or damping per TelemetryPlaybook; scenario space4x_turnrate_micro seed 1101.
2026-01-23T22:18:00Z REQUEST: Fix headless build compile error in Assets/Scripts/Space4x/Registry/Space4XPerfSummaryTelemetrySystem.cs: error CS0246 ResourceSystemGroup not found. Likely add using PureDOTS.Systems or fully-qualify type (PureDOTS.Systems.ResourceSystemGroup). Blocks entrypoint build; result zip INFRA_FAIL entrypoint_missing.
