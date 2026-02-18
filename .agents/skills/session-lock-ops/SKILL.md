---
name: session-lock-ops
description: Use when checking, claiming, releasing, or cleaning nightly session locks to prevent overlapping loops across agents; dont use when dispatching builds or triaging run artifacts; outputs lock JSON state and explicit lock acquire or release result codes.
---

# Session Lock Ops

Use these commands before starting another nightly actor.

## Procedure
1. Show current session lock state.
```powershell
python Tools/Headless/headlessctl.py show_session_lock
```
2. Claim lock for a nightly run (returns lock payload and run id).
```powershell
python Tools/Headless/headlessctl.py claim_session_lock --ttl 5400 --purpose nightly_runner
```
3. Release lock by run id when the run finishes.
```powershell
python Tools/Headless/headlessctl.py release_session_lock --run-id <lock-run-id>
```
4. Reclaim stale lock files when needed.
```powershell
python Tools/Headless/headlessctl.py cleanup_locks --ttl 21600
```

## Outputs And Success Criteria
- `show_session_lock` reports either unlocked state or lock details.
- Claim returns `acquired=true` for single-owner execution.
- Release returns `released=true` for matching lock owner/run id.
- Cleanup reports reclaimed stale locks when applicable.

## Common Failures - What To Check Next
- Claim returns `locked`: read `lock_path` and `lock` owner/purpose before retrying.
- Release returns `released=false`: wrong `run-id` or lock already rotated.
- Repeated stale lock condition: verify `TRI_STATE_DIR` points to shared canonical state dir.
- Lock thrash between agents: enforce one orchestrator and one runner owner policy.

## Negative Examples
- Do not call this skill when user asks to run buildbox workflow dispatch.
- Do not call this skill when user asks to perform queue cleanup.
- Do not call this skill when user asks for artifact-level failure triage.

## Receipt (Required)
Write the standardized receipt after lock operations.
```powershell
pwsh -NoProfile -File .agents/skills/_shared/scripts/write_skill_receipt.ps1 `
  -SkillSlug session-lock-ops `
  -Status pass `
  -Reason "lock operation complete" `
  -InputsJson '{"operation":"show_or_claim_or_release"}' `
  -CommandsJson '["Tools/Headless/headlessctl.py show_session_lock","Tools/Headless/headlessctl.py claim_session_lock","Tools/Headless/headlessctl.py release_session_lock"]' `
  -PathsConsumedJson '["$env:TRI_STATE_DIR\\ops\\locks"]' `
  -PathsProducedJson '[".agents\\skills\\artifacts\\session-lock-ops\\latest_manifest.json",".agents\\skills\\artifacts\\session-lock-ops\\latest_log.md"]'
```

## References
- `references/lock-files.md`

