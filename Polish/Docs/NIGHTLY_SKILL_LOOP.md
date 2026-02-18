# Nightly Skill Loop (Agent-Driven)

This is a lightweight, skill-based loop for long-running nightlies. It avoids rigid timing rules and relies on the nightly directive plus environment constraints.

## Purpose
- Keep agents continuously iterating: edit, run, learn, repeat.
- Allow self-healing when infra, path, or compile issues appear.
- Ensure the night stays productive without heavy orchestration.

## Preconditions
- Queue roots are correct and accessible.
- Watch daemons and runner are available.
- A current nightly directive and targets exist.

## Core Skill Chain (repeat as needed)
1. `nightly-preflight-guard` to verify disk gate, runner/workflow health, locks, and queue status.
2. `session-lock-ops` to claim/review nightly lock before long loops.
3. Choose execution lane:
   - `buildbox-dispatch` for normal remote runs.
   - `nightly-runner-orchestrator` for full end-to-end nightly loop.
4. `buildbox-run-monitor` while run is active (read-only status + next-skill hint).
5. When outputs land:
   - `buildbox-diag-triage` for run-level diagnostics.
   - `pipeline-smoke-evidence-extractor` for mechanical signature/invariant extraction.
6. `queue-health-cleanup` when queue is stale or disk pressure rises.
7. `pipeline-watch-daemon-ops` when daemon lifecycle/single-instance issues appear.
8. `recurring-error-ledger-update` when a stable failure signature repeats.
9. `intel-scoreboard-review` to refresh headline/questions/next actions from result zips.
10. `local-fallback-deck-run` only if buildbox is unavailable and emergency local override is required.

## Decision Guide
- Queue empty or stale: use `queue-health-cleanup` first, then rerun `buildbox-dispatch` or `pipeline-enqueue-artifact`.
- Infra/path/runner issues: run `nightly-preflight-guard` and `pipeline-watch-daemon-ops`, then retry dispatch.
- Missing evidence or telemetry: use `pipeline-smoke-evidence-extractor` or `buildbox-diag-triage`, then fix instrumentation.
- Compile errors: patch immediately, then rerun via `buildbox-dispatch`.
- Completed run with diagnostics artifact: route to `buildbox-diag-triage` (not orchestration).
- Need status only (no mutations): use `buildbox-run-monitor`.

## Autonomy Notes
- No explicit timing rules are enforced here.
- The agent uses the nightly directive and environment constraints to decide how long to push.
- The loop should never “wait and do nothing”; it should always pivot to a next action.
- Canonical skill entry point is `.agents/skills/SKILLS_INDEX.md`.

