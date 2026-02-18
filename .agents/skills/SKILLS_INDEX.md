# Skills Index

## Environment

- `TRI_ROOT`: Tri workspace root.
- `TRI_STATE_DIR`: shared state root (locks/runs/build pointers).
- `UNITY_EXE` or `UNITY_WIN`: Unity editor path.
- Queue roots should be explicit per run (for example `C:\polish\anviloop\space4x\queue`).

## Receipt Contract

Every skill execution should write:

- `artifacts/<skill-slug>/run_manifest_<timestamp>.json`
- `artifacts/<skill-slug>/run_log_<timestamp>.md`
- `artifacts/<skill-slug>/latest_manifest.json`
- `artifacts/<skill-slug>/latest_log.md`

via:

- `.agents/skills/_shared/scripts/write_skill_receipt.ps1`

## Safety Principles

- Respect disk gate before heavy actions.
- Respect session/build locks before starting loops.
- Do not run destructive cleanup without explicit `-Apply`.
- Keep queue root explicit for queue-touching actions.
- Use read-only monitor/extractor skills when mutation is not requested.

## Skills

- `nightly-preflight-guard`: preflight disk/runner/lock/queue gates.
- `buildbox-dispatch`: dispatch buildbox runs.
- `buildbox-run-monitor`: monitor run status and diagnostics availability (read-only).
- `buildbox-diag-triage`: download diagnostics and summarize evidence.
- `pipeline-enqueue-artifact`: enqueue jobs from existing artifact/build id.
- `queue-health-cleanup`: queue status and retention cleanup.
- `pipeline-watch-daemon-ops`: start/stop/ensure single watch daemon.
- `pipeline-smoke-evidence-extractor`: mechanical evidence extraction from bundles.
- `headlessctl-task-runner`: run and validate `headlessctl` tasks.
- `session-lock-ops`: show/claim/release/cleanup session locks.
- `nightly-runner-orchestrator`: run full `run_nightly.ps1` loop.
- `local-fallback-deck-run`: emergency-only local deck path.
- `recurring-error-ledger-update`: append recurring error entries with evidence.
- `intel-scoreboard-review`: ingest results + refresh scoreboard/headline.
