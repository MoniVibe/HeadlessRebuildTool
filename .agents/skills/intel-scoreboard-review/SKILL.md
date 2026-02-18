---
name: intel-scoreboard-review
description: Use when you need a read-only intel ingest and scoreboard/headline refresh from existing result zips to produce next-action summaries; dont use for dispatching or enqueueing runs; outputs scoreboard.json, triage_next.md, nightly headline, and a review summary path.
---

# Intel Scoreboard Review

Run intel + scoreboard on existing results only.

## Procedure
1. Set queue root explicitly.
```powershell
$queueRoot = "C:\polish\anviloop\space4x\queue"
```
2. Run review script.
```powershell
pwsh -NoProfile -File .agents/skills/intel-scoreboard-review/scripts/run_intel_scoreboard_review.ps1 `
  -QueueRoot $queueRoot `
  -Title space4x `
  -Limit 25
```
3. Read generated outputs:
  - `<queueRoot>\reports\scoreboard.json`
  - `<queueRoot>\reports\triage_next.md`
  - `<queueRoot>\reports\nightly_headline_YYYYMMDD.md`
  - summary markdown path printed by script

## Outputs And Success Criteria
- Intel ingest runs for recent result zips without mutating queue jobs.
- Scoreboard files are regenerated in queue reports directory.
- Review summary points to headline + top triage entries.

## Common Failures - What To Check Next
- WSL command failure: verify distro and python availability in WSL.
- Missing results: ensure `<queueRoot>\results\result_*.zip` exists.
- Missing intel outputs: inspect `anviloop_intel.py` ingest stderr in script output.
- Scoreboard failure: check path mapping (`/mnt/c/...`) and script args.

## Negative Examples
- Do not call this skill when user asks to trigger buildbox workflow.
- Do not call this skill when user asks to enqueue artifact jobs.
- Do not call this skill when user asks for queue retention cleanup.

## Receipt (Required)
Write the standardized receipt after review.
```powershell
pwsh -NoProfile -File .agents/skills/_shared/scripts/write_skill_receipt.ps1 `
  -SkillSlug intel-scoreboard-review `
  -Status pass `
  -Reason "intel and scoreboard refreshed" `
  -InputsJson '{"queue_root":"C:\\polish\\anviloop\\space4x\\queue","title":"space4x"}' `
  -CommandsJson '[".agents/skills/intel-scoreboard-review/scripts/run_intel_scoreboard_review.ps1"]' `
  -PathsConsumedJson '["<queueRoot>\\results\\result_*.zip"]' `
  -PathsProducedJson '[".agents\\skills\\artifacts\\intel-scoreboard-review\\latest_manifest.json",".agents\\skills\\artifacts\\intel-scoreboard-review\\latest_log.md"]'
```

## References
- `references/review-outputs.md`

