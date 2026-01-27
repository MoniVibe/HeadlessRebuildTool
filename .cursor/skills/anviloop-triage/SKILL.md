---
name: anviloop-triage
description: Inspect Anviloop result zips, extract failure signatures, classify validity, and propose next actions. Use when triaging failures, INVALID runs, or when the user asks about result zips.
---

# Anviloop Triage

## Inputs

- Result zip path (newest): `C:/polish/queue/results/result_<job_id>.zip` or `/mnt/c/polish/queue/results/result_<job_id>.zip`

## Inspect result zip

1. `meta.json`: exit_reason, exit_code, failure_signature, scenario_id, seed, build_id, commit
2. `out/watchdog.json`: raw_signature_string, stdout_tail, stderr_tail
3. `out/run_summary.json`: runtime, telemetry bytes/summary, artifacts presence
4. Optional proofs: `out/player.log`, `out/polish_score_v0.json`

## Validity rules

- INVALID if telemetry missing/truncated, invariants missing, or required oracle keys missing.
- VALID only with proof markers or passing oracle thresholds.
- If the same failure signature repeats twice, consult the ledger before changing code.

## Triage output (concise)

Use this shape:

```
Headline: <short failure headline>
Signature: <failure_signature or raw_signature_string>
Validity: VALID|INVALID (+ reason)
Next: <fix, ledger update, or rerun>
```

## References

- `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/ANVILOOP_RECURRING_ERRORS.md`
- `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/NIGHTLY_PROTOCOL.md`
