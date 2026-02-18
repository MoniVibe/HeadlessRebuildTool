---
name: buildbox-diag-triage
description: Use when you already have a buildbox run_id or run_url and need diagnostic artifacts downloaded, unpacked, and summarized in evidence order; dont use when dispatching new runs or cleaning queues; outputs extracted buildbox_diag folder, latest result folder, and diag summary markdown path.
---

# Buildbox Diag Triage

Download the run diagnostics artifact and produce a concise summary from the latest result.

## Procedure
1. Download and expand `buildbox_diag_*`, then auto-summarize latest result.
```powershell
pwsh -NoProfile -File .agents/skills/buildbox-diag-triage/scripts/download_and_summarize_diag.ps1 `
  -RunId <github-run-id> `
  -Title <space4x-or-godgame>
```
2. Open `summary_path` printed by the script and read:
  - exit reason and code
  - failure signature
  - first evidence lines
  - invariant failures
3. If needed, inspect raw files in order:
  - `meta.json`
  - `out/run_summary.json`
  - `out/watchdog.json`
  - `out/player.log`

## Outputs And Success Criteria
- `zip_path=<...buildbox_diag...zip>`
- `diag_root=<...buildbox_diag_...>`
- `result_dir=<...results\result_...>`
- `summary_path=<...diag_*.md>`
- Summary includes enough evidence to choose next fix, rerun, or ledger update.

## Common Failures - What To Check Next
- Artifact not found: verify run id and title (`space4x`/`godgame`) match actual workflow output.
- `gh` auth failure: run `gh auth login` and retry.
- No result directories inside diag artifact: inspect workflow run logs; build may have failed before queue execution.
- Summary script missing: verify `Polish/Ops/diag_summarize.ps1` exists in current repo.

## Negative Examples
- Do not call this skill when the user asks to trigger a new buildbox run.
- Do not call this skill when the user asks to clean disk/queue retention only.
- Do not call this skill when the user asks to run `headlessctl` tasks directly.

## Receipt (Required)
Write the standardized receipt after the run.
```powershell
pwsh -NoProfile -File .agents/skills/_shared/scripts/write_skill_receipt.ps1 `
  -SkillSlug buildbox-diag-triage `
  -Status pass `
  -Reason "diag summary generated" `
  -InputsJson '{"run_id":"<github-run-id>","title":"<space4x-or-godgame>"}' `
  -CommandsJson '[".agents/skills/buildbox-diag-triage/scripts/download_and_summarize_diag.ps1"]' `
  -PathsConsumedJson '["C:\\polish\\queue\\reports\\_diag_downloads"]' `
  -PathsProducedJson '[".agents\\skills\\artifacts\\buildbox-diag-triage\\latest_manifest.json",".agents\\skills\\artifacts\\buildbox-diag-triage\\latest_log.md"]'
```

## References
- `references/evidence-order.md`

