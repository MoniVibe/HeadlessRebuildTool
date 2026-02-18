---
name: recurring-error-ledger-update
description: Use when a failure signature repeats and you need to append a structured recurring error entry with evidence paths to the ledger; dont use for first-pass triage without a stable signature; outputs appended ERR entry in ANVILOOP_RECURRING_ERRORS.md plus receipt artifacts.
---

# Recurring Error Ledger Update

Capture repeated failures into the ledger with concrete evidence.

## Procedure
1. Confirm signature repeats (same signature at least twice).
2. Append ledger entry with required evidence fields.
```powershell
pwsh -NoProfile -File .agents/skills/recurring-error-ledger-update/scripts/append_recurring_error.ps1 `
  -Stage RUNNER `
  -Symptom "TEST_FAIL space4x_collision_micro seed=7 exit_code=10" `
  -Signature "9af157abb7a115bb..." `
  -RootCause "DigGate default-enabled in non-mining scenario" `
  -Fix "Require SPACE4X_HEADLESS_MINING_PROOF=1 to enable gate" `
  -Prevention "Default-off dig gate in non-mining suites" `
  -Verification "buildbox run 21495328334 SUCCESS" `
  -EvidencePaths "C:\polish\queue\reports\_diag_downloads\21495328334\..."
```
3. Verify entry exists in `Polish/Docs/ANVILOOP_RECURRING_ERRORS.md`.

## Outputs And Success Criteria
- New `ERR-*` block appended with:
  - stage, symptom, signature
  - root cause, fix, prevention
  - verification and evidence paths
- Ledger remains parseable markdown with chronological entries.

## Common Failures - What To Check Next
- Missing stable signature: return to triage and gather second confirming run.
- Ledger path missing: verify repository root and ledger file location.
- Duplicate entry risk: search for signature before appending (`rg <signature>`).

## Negative Examples
- Do not call this skill for one-off failures without repeated evidence.
- Do not call this skill to dispatch or enqueue runs.
- Do not call this skill for queue cleanup or daemon lifecycle tasks.

## Receipt (Required)
Write the standardized receipt after ledger update.
```powershell
pwsh -NoProfile -File .agents/skills/_shared/scripts/write_skill_receipt.ps1 `
  -SkillSlug recurring-error-ledger-update `
  -Status pass `
  -Reason "ledger entry appended" `
  -InputsJson '{"signature":"<failure-signature>"}' `
  -CommandsJson '[".agents/skills/recurring-error-ledger-update/scripts/append_recurring_error.ps1"]' `
  -PathsConsumedJson '["Polish/Docs/ANVILOOP_RECURRING_ERRORS.md"]' `
  -PathsProducedJson '[".agents\\skills\\artifacts\\recurring-error-ledger-update\\latest_manifest.json",".agents\\skills\\artifacts\\recurring-error-ledger-update\\latest_log.md"]'
```

## References
- `references/entry-contract.md`

