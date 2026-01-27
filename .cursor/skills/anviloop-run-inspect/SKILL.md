---
name: anviloop-run-inspect
description: Unpack and inspect Anviloop result zips for meta, watchdog, run_summary, and proof logs. Use when extracting failure details or verifying proof.
---

# Anviloop Result Inspection

## Extract

- Unzip the newest `result_<job_id>.zip` to a temp folder.

## Read in order

1. `meta.json` (exit_reason, exit_code, failure_signature, scenario_id, seed, build_id, commit)
2. `out/watchdog.json` (raw_signature_string, stdout_tail, stderr_tail)
3. `out/run_summary.json` (runtime, telemetry summary/bytes, artifacts presence)
4. Optional proof: `out/player.log`, `out/polish_score_v0.json`

## Output (concise)

Use this shape:

```
Headline: <short failure headline>
Signature: <failure_signature or raw_signature_string>
Evidence: <files reviewed>
Proof: <marker or missing>
```

## References

- `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/ANVILOOP_RECURRING_ERRORS.md`
- `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/MORNING_VIEW.md`
