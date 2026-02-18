# Validator Workflow (Single-Lane)

## Goal

Many worker agents can push feature branches and PRs. One validator agent owns buildbox dispatch, greenification loops, and final merge decisions.

## Roles

- Worker agents:
  - Create feature branches with one goal.
  - Open PR with an intent card.
  - Add `needs-validate` label.
  - Do not run buildbox workflows.
- Validator agent:
  - Picks PRs labeled `needs-validate`.
  - Applies `validator-running`.
  - Dispatches buildbox runs.
  - Applies minimal fix-up commits and reruns until green/stop condition.
  - Sets final labels (`buildbox-green`, `buildbox-red`, `blocked-infra`).

## Labels

- Intake labels:
  - `needs-validate`
  - `needs-intent-card`
- Validator control labels:
  - `run-buildbox`
  - `validator-running`
  - `buildbox-green`
  - `buildbox-red`
  - `blocked-infra`

`validator-label-guard.yml` protects control labels so only validator actors can apply them.

## Required Repo Variables

- `VALIDATOR_ACTOR`:
  - Single GitHub username for the validator actor (optional, but recommended).
- `VALIDATOR_ACTORS`:
  - Comma-separated allowlist for additional validator actors (optional).

`buildbox_on_demand.yml` allows:
- `github-actions[bot]`
- `VALIDATOR_ACTOR`
- any actor listed in `VALIDATOR_ACTORS`

All other actors are rejected by the validator gate.

## PR Intent Card

Use `.github/PULL_REQUEST_TEMPLATE.md`. `validator-intake.yml` enforces required sections:

- `## Intent Card`
- `### What Changed`
- `### Invariants`
- `### Acceptance Checks`
- `### Risk Flags`
- `### Validation Routing`
- `### Notes For Validator`

If missing, `needs-intent-card` is added and `needs-validate` is removed.

## Dispatching Buildbox From a PR

Use:

```powershell
pwsh -NoProfile -File Polish/Ops/validator_dispatch_buildbox.ps1 `
  -Project godgame `
  -PrNumber 123 `
  -PrRepo MoniVibe/Godgame `
  -ScenarioRel Assets/Scenarios/Godgame/godgame_smoke.json `
  -PuredotsRef feat/band-combat-aggregation
```

The script:

- validates intake (`needs-validate` + required intent sections) by default
- dispatches `buildbox_on_demand.yml`
- moves labels (`needs-validate` -> `validator-running`)
- comments run routing back to the source PR

Use `-SkipIntakeChecks` only for controlled infra recovery.
