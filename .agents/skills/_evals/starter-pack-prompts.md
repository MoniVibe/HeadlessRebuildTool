# Starter Pack Eval Prompts

Use these prompts to evaluate routing quality and expected outputs.

Global assertion for all positive prompts: receipt files must exist at
`.agents/skills/artifacts/<skill-slug>/latest_manifest.json` and `.agents/skills/artifacts/<skill-slug>/latest_log.md`,
plus at least one per-run receipt file matching `run_manifest_*.json` and `run_log_*.md`.

| id | prompt | expected skill | should trigger | expected output check |
|---|---|---|---|---|
| P01 | "Before tonight, run disk gate and lock checks so we do not start a bad loop." | `nightly-preflight-guard` | yes | reports `C_free_GB`, preflight guard status, lock state |
| P03 | "Trigger buildbox for space4x on branch fix/playmode-structural-change and wait for result." | `buildbox-dispatch` | yes | `run_id` and `run_url` shown |
| P05 | "Download run 21545283685 diagnostics and summarize the latest result evidence." | `buildbox-diag-triage` | yes | `diag_root`, `result_dir`, `summary_path` printed |
| P07 | "Check queue health on C:\\polish\\anviloop\\space4x\\queue and show latest result status." | `queue-health-cleanup` | yes | `queue_status_written` and status markdown |
| P09 | "Run S0.SPACE4X_SMOKE with headlessctl seed 77 and show run_id artifacts." | `headlessctl-task-runner` | yes | JSON result with `run_id` and artifacts under `TRI_STATE_DIR/runs` |
| P10 | "I only need buildbox run status + next step for run 21545283685; do not dispatch anything." | `buildbox-run-monitor` | yes | monitor status/report paths with `next_skill` |
| P11 | "Buildbox is offline, run a minimal local deck with explicit override." | `local-fallback-deck-run` | yes | `run_deck.ps1` called with `-AllowLocalBuild` and local queue root |
| P13 | "Enqueue jobs from artifact_20260131_132858_259_b6c656ba.zip to the space4x queue and wait for result." | `pipeline-enqueue-artifact` | yes | `job=` lines plus wait summary exit reason |
| P15 | "Run the full nightly orchestrator for both titles with explicit queue roots and report nightly summary path." | `nightly-runner-orchestrator` | yes | outputs `Wrote nightly summary:` path |
| P16 | "Claim a nightly session lock for 90 minutes and then release it by run id." | `session-lock-ops` | yes | claim shows `acquired=true`, release shows `released=true` |
| P17 | "Ensure exactly one watch daemon instance is running for space4x queue root C:\\polish\\anviloop\\space4x\\queue." | `pipeline-watch-daemon-ops` | yes | status/ensure output with running count and pid |
| P18 | "Extract mechanical evidence from this result zip and output only signature and failing invariants." | `pipeline-smoke-evidence-extractor` | yes | prints `evidence_summary` and `evidence_report` paths |
| C01 | "Nightly failed and queue looks stuck; start with queue health before any run-level diagnosis." | `queue-health-cleanup` | yes | queue status + cleanup plan, no immediate diag triage |
| C02 | "Queue is healthy and runs are complete; refresh intel and scoreboard only." | `intel-scoreboard-review` | yes | scoreboard/headline paths updated, no dispatch/enqueue |
| N01 | "Implement a new Space4X combat ECS system." | none | no | do not use starter ops skills |
| N02 | "Rewrite this markdown summary for my standup." | none | no | do not run queue/build commands |
| P19 | "This failure signature repeated twice; append a ledger entry with evidence paths." | `recurring-error-ledger-update` | yes | new `ERR-*` entry appended in recurring errors ledger |
| N04 | "Explain why Unity DOTS jobs should avoid allocations." | none | no | no ops skill trigger |
| N05 | "Summarize this completed run failure in one sentence only." | none (or dedicated summarize flow) | no | do not dispatch/enqueue/cleanup |
| N06 | "Clean up my disk in general." | none | no | do not auto-run run-level triage or dispatch |
