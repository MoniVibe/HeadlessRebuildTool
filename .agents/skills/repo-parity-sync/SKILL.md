---
name: repo-parity-sync
description: Use when an iterator or validator needs to push and then hard-sync desktop/laptop validation checkouts to one upstream ref; dont use for build dispatch or diagnostics triage; outputs parity head refs and any auto-stash refs used to unblock sync.
---

# Repo Parity Sync

Keep both machines on the same git point after push.

## Procedure
1. Choose mode:
- Iterator push parity: branch ref parity.
- Validator post-green parity: main parity.
2. Run iterator parity sync from `space4x` repo.
```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File Tools/PushValidationAndSyncParity.ps1 `
  -RepoPath C:\dev\Tri\space4x `
  -Mode iterator `
  -PushBranch <branch-name> `
  -LocalParityBranch validator/ultimate-checkout `
  -LocalParityUpstreamRef origin/<branch-name> `
  -LaptopRepoPath C:\dev\unity_clean_fleetcrawl `
  -LaptopParityBranch validator/ultimate-checkout `
  -LaptopParityUpstreamRef origin/<branch-name>
```
3. Run validator post-green parity sync.
```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File Tools/PushValidationAndSyncParity.ps1 `
  -RepoPath C:\dev\Tri\space4x `
  -Mode validator `
  -PushBranch main `
  -LocalParityBranch validator/ultimate-checkout `
  -LaptopRepoPath C:\dev\unity_clean_fleetcrawl `
  -LaptopParityBranch validator/ultimate-checkout
```
4. If the repo is intentionally dirty (last resort), allow only scoped patterns and stash them:
```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File Tools/PushValidationAndSyncParity.ps1 `
  -RepoPath C:\dev\Tri\space4x `
  -Mode iterator `
  -PushBranch <branch-name> `
  -DirtyPolicy stash-allowed `
  -AllowedDirtyRegex '^console\.md$' `
  -AllowMetaDirty
```

## Outputs And Success Criteria
- Reports `local_parity=<branch> <= <upstream-ref>`.
- Reports `laptop_parity=<branch> <= <upstream-ref>`.
- Optional `local_stash=` / `laptop_stash=` only when dirty policy stashes.
- No force-push or reset actions are performed.

## Common Failures - What To Check Next
- Laptop key missing: use `desktop_to_laptop_ed25519` or pass `-LaptopKeyPath`.
- Dirty tree blocked: commit/stash manually or rerun with constrained `stash-allowed` criteria.
- FF-only merge failure: parity branch has local commits; re-anchor branch manually and rerun.
- Upstream ref missing: ensure branch is pushed to remote first.

## Negative Examples
- Do not use for Buildbox dispatch or run triage.
- Do not use to bypass unresolved merge conflicts.
- Do not blanket-ignore all dirty files.

## Receipt (Required)
Write the standardized receipt after parity sync.
```powershell
pwsh -NoProfile -File .agents/skills/_shared/scripts/write_skill_receipt.ps1 `
  -SkillSlug repo-parity-sync `
  -Status pass `
  -Reason "desktop+laptop parity synced" `
  -InputsJson '{"mode":"iterator_or_validator","branch":"<branch>"}' `
  -CommandsJson '["Tools/PushValidationAndSyncParity.ps1"]' `
  -PathsConsumedJson '["C:\\dev\\Tri\\space4x\\Tools\\PushValidationAndSyncParity.ps1"]' `
  -PathsProducedJson '[".agents\\skills\\artifacts\\repo-parity-sync\\latest_manifest.json",".agents\\skills\\artifacts\\repo-parity-sync\\latest_log.md"]'
```
