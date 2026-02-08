---
name: scenario-goal-cards
description: Create goal-driven scenario cards and scenario JSON stubs for Space4X, Godgame, and PureDOTS. Use when the user asks for a scenario, goal cards, test this system, we need a scenario, or wants to define or organize simulation scenarios, metrics, and acceptance criteria.
---

# Scenario Goal Cards

## Overview

Draft goal cards and scenario JSON stubs that define what a scenario should prove, how it is measured, and how it should be run. Keep goal cards in the game docs folder (not in PureDOTS root).

## Workflow

1. Identify target game and slice
   - Game: Space4X, Godgame, or PureDOTS
   - Slice: the system or behavior to test (for example, ECM/ECW targeting)

2. Locate or create the goal card folder
   - Path: <repo>/Docs/Scenarios/GoalCards
   - If missing, create it.

3. Create the goal card from the template
   - Copy assets/_goalcard_template.md into the goal card folder.
   - Naming convention: <game>_goalcard_<slice>_<intent>.md
   - Keep ASCII unless the repo already uses Unicode.

4. Fill the goal card
   - Goal: 1 to 2 sentences
   - Hypotheses: ranked expected outcomes
   - Setup and Script: concrete, reproducible
   - Metrics and Scoring: explicit, measurable
   - Acceptance: pass or fail or range
   - Dependencies: required systems or data
   - Risks/Notes: blockers or stubs
   - Link the scenario JSON path

5. Create the scenario JSON stub
   - Copy assets/_scenario_stub.json into <repo>/Assets/Scenarios/.
   - Naming convention: <game>_<slice>_micro.json
   - Update:
     - scenarioId
     - duration_s
     - headlessQuestions IDs
     - spawn and actions

6. Optional scan for existing scenarios
   - Run scripts/scan_scenarios.py --root <repo> to list current scenario files and IDs.
   - Use it to avoid duplicates or to align with existing IDs.

## Naming and Organization Rules

- Goal cards live in the game-side docs folder:
  - space4x/Docs/Scenarios/GoalCards/
  - godgame/Docs/Scenarios/GoalCards/
  - puredots/Docs/Scenarios/GoalCards/ (only if this is the game's docs root)
- Avoid putting goal cards in shared tool repos unless explicitly requested.
- If multiple scenarios exist for a slice, use numbered or variant suffixes.

## Quality Bar

- Each goal card must define a measurable outcome.
- Each scenario stub must include a stable scenarioId and a minimal headlessQuestions entry.
- If the system is stubbed or unimplemented, note it in Risks/Notes so later work is explicit.

## Resources

- assets/_goalcard_template.md
- assets/_scenario_stub.json
- scripts/scan_scenarios.py
