---
name: docs-to-plans
description: Translate game/project docs into executable plans and lightweight schemas aligned to scenario templates. Use when asked to turn docs or vision into a plan, schema, or actionable sprint plan for PureDOTS, Space4X, or Godgame.
---

# Docs to Plans

## Overview

Convert docs into a compact plan that is ready for implementation and headless validation. The output must mirror scenario-template nuance (scenarioId, duration, questions, metrics, acceptance) and enforce DOTS 1.4, Burst-safe hot paths, and deterministic simulation.

## Workflow

1. Identify target repo(s)
   - Default repos: `C:\dev\Tri\puredots`, `C:\dev\Tri\space4x`, `C:\dev\Tri\godgame`.
   - Docs live under `<repo>/Docs/` and subfolders.

2. Auto-scan docs
   - List docs: `rg --files -g "Docs/**/*.md" <repo>`
   - Filter by keywords from the user request (system, mechanic, feature name).
   - Prioritize docs that look like: `Docs/**/Scenarios`, `Docs/**/Mechanics`, `Docs/**/Architecture`, `TRI_PROJECT_BRIEFING.md`.
   - Read the 2–5 most relevant docs only.

3. Extract requirements
   - Goals and constraints
   - Entities/components/data schema
   - Systems and data flow
   - Determinism and Burst constraints
   - Scenario expectations (inputs, outputs, metrics)

4. Produce plan file
   - Output path: `<repo>/Docs/Plans/<topic>_plan.md` (create folder if missing).
   - Use `assets/_plan_template.md` as the base.
   - Fill **Scenario Template Parity** with the same nuance as scenario templates.

5. Enforce constraints
   - DOTS 1.4
   - Burst-safe on hot paths (mark any exceptions)
   - Deterministic sim (document any nondeterministic risk)

6. Provide verification
   - Headless scenario to run (or stub path to create)
   - Minimal validation steps or test harness

7. Close with open questions
   - List blockers or unknowns explicitly.

## Output Rules

- Prefer ASCII unless the repo already uses Unicode.
- Keep the plan concise (1–3 pages).
- Always include the source docs list.

## Resources

- assets/_plan_template.md
