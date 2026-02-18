# Agents Guide (HeadlessRebuildTool)

## Skill Discovery (Required)
- Primary operator skill surface is `.agents/skills/`.
- Start routing from `.agents/skills/SKILLS_INDEX.md`.
- Skill definitions live at `.agents/skills/<skill-slug>/SKILL.md`.
- Shared validation/scripts live under `.agents/skills/_shared/scripts/`.
- Skill eval prompts live in `.agents/skills/_evals/starter-pack-prompts.md`.

## Routing Rules
- For buildbox dispatch, monitoring, triage, queue health, nightly orchestration, lock ops, and evidence extraction: prefer `.agents/skills/*`.
- Treat `.cursor/skills/*` as legacy/draft intent; use only if no `.agents` equivalent exists.
- Queue-touching operations must use explicit `QueueRoot`.
- Local fallback deck execution is emergency-only and must include `-AllowLocalBuild`.

## Receipt Contract
Each skill run should write:
- `.agents/skills/artifacts/<skill-slug>/run_manifest_<run-id>.json`
- `.agents/skills/artifacts/<skill-slug>/run_log_<run-id>.md`
- `.agents/skills/artifacts/<skill-slug>/latest_manifest.json`
- `.agents/skills/artifacts/<skill-slug>/latest_log.md`

## Validation
- `pwsh -NoProfile -File .agents/skills/_shared/scripts/lint_skills.ps1`
- `pwsh -NoProfile -Command "Invoke-Pester -Script .agents/skills/_shared/tests -EnableExit"`
