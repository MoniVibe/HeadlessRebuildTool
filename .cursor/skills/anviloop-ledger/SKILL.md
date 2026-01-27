---
name: anviloop-ledger
description: Update the Anviloop recurring error ledger with ERR-* entries based on result zip evidence. Use when a failure repeats, a new signature appears, or the ledger needs an entry.
---

# Anviloop Ledger Updates

## Source of truth

- Ledger path: `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/ANVILOOP_RECURRING_ERRORS.md`

## Data to pull

- `meta.json`: failure_signature, exit_reason, exit_code, scenario_id, seed, build_id, commit
- `out/watchdog.json`: raw_signature_string, stdout_tail, stderr_tail
- `out/run_summary.json`: runtime, telemetry summary/bytes, artifacts presence

## Update rules

1. Search for an existing `Signature:` match; update that entry instead of adding a duplicate.
2. If missing, add a new ERR entry at the top of the ERR section:
   - Prefer `ERR-YYYYMMDD-###` (increment for the day).
   - Use `ERR-YYYYMMDD_HHMMSS` if the ledger already mixes timestamp style.
3. Use `failure_signature` from `meta.json` verbatim; add `RawSignature:` when available.
4. Always include the standard fields below.

## Minimal entry template (use exact labels)

```
ERR-YYYYMMDD-###
- FirstSeen: YYYY-MM-DD
- Symptom: <short failure summary>
- Signature: <failure_signature>
- RawSignature: <raw_signature_string>
- RootCause: TBD|<known>
- Fix: TBD|<action>
- Prevention: TBD|<guard>
- Verification: TBD|<proof>
- Evidence: <result zip path or log>
- Commit: TBD|<sha>
```

## References

- `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/ANVILOOP_RECURRING_ERRORS.md`
