Below is a practical “bank” you can start with right now, tailored to your stated MVP pillars (Space4X first), and aligned to how mature farms structure work (blockers first, then core, then wide).
Start here for pipeline context: Tools/Polish/Docs/HEADLESS_DOCS_INDEX.md.

How to think about each bank item (so an agent can act on it)
Every item should have: (1) a deterministic scenario, (2) an oracle/proof (BANK line, invariant, or snapshot), (3) required telemetry keys, (4) a success threshold, and optionally (5) a polish metric to optimize once it’s passing. This is the same “tests as executable spec” concept used in CI, and for complex outputs you can use an approval/snapshot (“golden master”) workflow where humans approve the expected output once, then automation guards it. Property-based testing is also useful for sims: randomize inputs but keep runs repeatable via seeds, and check invariants (no NaN, conservation bounds, no stuck states).

Bank v0 for your nightlies (start small, promote only after stability)
A) Tier-0 “Blocker / BVT” (must be green before anything else)
These are short, deterministic, and should be the first jobs every night. “Smoke/BVT” is explicitly about “is the build even worth further testing.”

Space4X:

S0.SPACE4X_SMOKE — Scenario loads, sim runs to end, required BANK emits, required telemetry present.

S0.SPACE4X_MINING_PROOF — Ore or cargo delta > 0 by end; proves basic extraction loop.

S0.SPACE4X_NAV_REACH_TARGET_MICRO — A ship reaches a waypoint in time; no stuck; path length within band.

S0.SPACE4X_SENSORS_CONTACTS_MICRO — Contacts appear and remain consistent across frames; no flicker beyond band.

S0.SPACE4X_COMBAT_FIRE_MICRO — Weapons fire, damage applied, at least one kill/disable occurs (or explicit “engaged” proof).

Godgame:
6) G0.GODGAME_SMOKE — Same idea: load/run/quit cleanly, required outputs.
7) G0.GODGAME_PATHING_MICRO — Unit reaches target; no oscillation/stuck.
8) G0.GODGAME_COMBAT_MICRO — Engage + resolve combat event; no NaN; no infinite loops.

Factory-wide:
9) F0.CONTRACT_CHECK + validate — Harness contract intact.
10) F0.TELEMETRY_HEALTH — heartbeat seen; truncation=0; required files exist.
11) F0.FLAKE_POLICY — any Tier-0 failure reruns once; only marked FAIL if it fails twice (mirrors Google’s mitigation pattern).

B) Tier-1 “Core MVP mechanics” (what you actually want to build on)
These are your “combat/relations/crew/production/carrier ops” pillars. They can be longer than Tier-0 but should still be deterministic and scenario-driven.

Space4X MVP core:
12) S1.SPACE4X_CREW_TEMPLATES_LOAD — Template resolves; crew instantiated; a condition (e.g., “one_eye_missing”) changes stats/behavior.
13) S1.SPACE4X_CREW_ASSIGNMENT — Crew assigned to stations; station outputs reflect crew.
14) S1.SPACE4X_PRODUCTION_CHAIN — Extract → refine → component produced; inventory deltas prove the chain.
15) S1.SPACE4X_CARRIER_LAUNCH_RECOVER — Fighters launch, acquire targets, return/recover; no orphan craft.
16) S1.SPACE4X_COMMS_COHESION — Group comms “beat” present; formation/cohesion maintained within radius band.
17) S1.SPACE4X_RELATIONS_DECISION_MICRO — A simple diplomatic decision fires (stance change, trade accept/deny) with explicit telemetry proof.
18) S1.SPACE4X_FTL_JUMP_MICRO — Intent emitted, preconditions met, jump completes; post-jump invariants hold.
19) S1.SPACE4X_SENSORS_TRACKING_QUALITY — Track quality increases with range/signal; false positives below band.
20) S1.SPACE4X_COMBAT_TTK_BAND — Time-to-kill or damage-per-second within band; no degenerate “never hits” behavior.
21) S1.SPACE4X_RESOURCE_LOGIC_SANITY — Conservation-ish checks: no negative mass/credits; no NaN/Inf.

Godgame MVP core:
22) G1.GODGAME_ECONOMY_LOOP — Resource production/consumption loop stable; no runaway; deltas match expected bands.
23) G1.GODGAME_FORMATIONS — Squad cohesion maintained; no split-brain.
24) G1.GODGAME_AI_INTENT_DECISIONS — Intent selection emits; agent chooses sensible actions (within a simple score band).
25) G1.GODGAME_SCALE_SMOKE — A medium-scale scenario runs without perf collapse.

C) Tier-2 “Wide / Showcase / Long soak”
This is your “canonical wide baseline” after Tier0/Tier1 are solid. Riot does this conceptually by only deploying further tests if Blocker is green, and promoting tests only after stability is demonstrated.

Space4X wide:
26) S2.SPACE4X_FULL_MVP_LOOP — Start → extract → build → move → fight → recover; end-state snapshot matches approved baseline (golden master / approval test style).
27) S2.SPACE4X_LONG_SOAK_STABILITY — 30–60 min sim soak; invariants only (no asserts that force constant tuning).

Godgame wide:
28) G2.GODGAME_LONG_SOAK — Similar.

D) “Polish goals” (agent can optimize after PASS is stable)
Once a mechanic is PASS, give the agent a scalar objective to improve while preserving proofs.
Examples:
29) Reduce “stuck frames” rate in nav micro by X%.
30) Reduce aim error / increase hit rate distribution (vets vs rookies) by X, while keeping fairness/bounds.
31) Reduce formation break frequency.
32) Improve sensor tracking stability (fewer track drops).
33) Improve perf: frame time or sim tick time within band (and store baseline history rather than single-run comparisons).

How your nightly agent should operate against this bank (so it fulfills the vision)
First, run Tier-0. If any Tier-0 item is red, stop feature work and file a “factory/mechanic triage” fix (this is the “build not worth further testing” rule).
Second, run Tier-1 for any MVP items you care about right now. Only after Tier-1 is mostly green do you run Tier-2 wide.
Third, allow “agent improvement mode” only on items that are already PASS and stable (run-to-run), otherwise you risk learning from noise. Google’s flake mitigation experience strongly supports doing reruns and quarantining flaky tests rather than letting them poison the signal.
