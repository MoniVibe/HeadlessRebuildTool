---
name: local-fallback-deck-run
description: Use when buildbox is unavailable and you must run a minimal emergency local deck with explicit override and conservative queue settings; dont use when remote buildbox dispatch is available or when broad/nightly sweeps are requested; outputs local artifact and queue result traces with explicit fallback evidence.
---

# Local Fallback Deck Run

Use only when desktop buildbox path is unavailable.

## Procedure
1. Confirm fallback is necessary.
```powershell
pwsh -NoProfile -File scripts/buildbox_sync_audit.ps1
```
2. Check disk gate and stop if `< 40 GB`.
```powershell
pwsh -NoProfile -Command "'C_free_GB=' + [math]::Round((Get-PSDrive C).Free/1GB,1)"
```
3. Set explicit queue root and Unity path variables.
```powershell
$queueRoot = "C:\polish\queue"
$unityExe = if ($env:UNITY_EXE) { $env:UNITY_EXE } elseif ($env:UNITY_WIN) { $env:UNITY_WIN } else { "<set-unity-exe>" }
```
4. Run a constrained local deck with explicit override.
```powershell
pwsh -NoProfile -File Polish/run_deck.ps1 `
  -DeckPath <deck-path> `
  -UnityExe $unityExe `
  -AllowLocalBuild `
  -QueueRoot $queueRoot `
  -Mode run
```
5. Verify queue and latest result metadata.
```powershell
pwsh -NoProfile -File Polish/queue_status.ps1 -QueueRoot $queueRoot
```
6. Dry-run cleanup first to verify retention impact.
```powershell
pwsh -NoProfile -File Polish/cleanup_queue.ps1 -QueueRoot $queueRoot -RetentionDays 7 -KeepLastPerScenario 3
```
7. Apply cleanup only after reviewing dry-run totals.
```powershell
pwsh -NoProfile -File Polish/cleanup_queue.ps1 -QueueRoot $queueRoot -RetentionDays 7 -KeepLastPerScenario 3 -Apply
```

## Outputs And Success Criteria
- `run_deck.ps1` runs only with `-AllowLocalBuild` and logs dispatch/build progression.
- Local queue receives fresh artifact and result files.
- `queue_status.md` reports latest artifact/result with exit reason.
- Cleanup reclaims space without removing active run evidence.

## Common Failures - What To Check Next
- `Local build execution is disabled by default`: add `-AllowLocalBuild`.
- Unity path tokenization/path not found: quote `-UnityExe` and verify installed editor version.
- Queue root mismatch: ensure fallback uses `C:\polish\queue`, not desktop anviloop roots.
- Run too broad/slow: reduce to one title, one scenario, one repeat.

## Negative Examples
- Do not call this skill when buildbox dispatch is healthy and available.
- Do not call this skill when the user asks to triage an already finished run.
- Do not call this skill when the user asks to run only `headlessctl` task contracts.

## Receipt (Required)
Write the standardized receipt after fallback completion.
```powershell
pwsh -NoProfile -File .agents/skills/_shared/scripts/write_skill_receipt.ps1 `
  -SkillSlug local-fallback-deck-run `
  -Status pass `
  -Reason "fallback deck run executed" `
  -InputsJson '{"queue_root":"C:\\polish\\queue","deck_path":"<deck-path>"}' `
  -CommandsJson '["Polish/run_deck.ps1 -AllowLocalBuild","Polish/queue_status.ps1","Polish/cleanup_queue.ps1"]' `
  -PathsConsumedJson '["C:\\polish\\queue"]' `
  -PathsProducedJson '[".agents\\skills\\artifacts\\local-fallback-deck-run\\latest_manifest.json",".agents\\skills\\artifacts\\local-fallback-deck-run\\latest_log.md"]'
```

## References
- `references/fallback-policy.md`

