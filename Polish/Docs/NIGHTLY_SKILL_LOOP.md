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
1. `anviloop-preflight` to verify runner sync, path sanity, telemetry budget, queue health.
2. `anviloop-nightly` to confirm disk gate, daemons, and chain-of-custody.
3. `anviloop-deck` only when targets or direction need to change.
4. `deck-run` to enqueue work.
5. `queue-health-fast` to confirm jobs are moving.
6. `anviloop-triage` or `anviloop-intel` when results land.
7. Fix issues in code/infra, then `deck-run` again.
8. `anviloop-ledger` when a failure signature repeats.
9. `handoff-sync` when pausing or handing off.

## Decision Guide
- Queue empty or stale: use `anviloop-queue` to requeue stale leases and clear dead jobs, then `deck-run`.
- Infra/path/runner issues: use `runner-path-sanity` and `workflow-guard`, then re-run `anviloop-preflight`.
- Missing evidence or telemetry: `anviloop-diag-summarize` or `anviloop-intel`, fix instrumentation, re-run.
- Compile errors: patch immediately, re-run.

## Autonomy Notes
- No explicit timing rules are enforced here.
- The agent uses the nightly directive and environment constraints to decide how long to push.
- The loop should never “wait and do nothing”; it should always pivot to a next action.

