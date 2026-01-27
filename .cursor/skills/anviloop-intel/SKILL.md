---
name: anviloop-intel
description: Run and interpret the Anviloop intel sidecar outputs (explain/questions) to summarize validity and fixes. Use when analyzing result zips, intel reports, or nightly failures.
---

# Anviloop Intel

## Run

- From repo root: `Polish/Intel/anviloop_intel.py`

## Outputs to read

- `C:/polish/queue/reports/intel/explain_<job_id>.json`
- `C:/polish/queue/reports/intel/questions_<job_id>.json`
- `out/polish_score_v0.json` inside result zip (if present)

## Summary focus

- Validity block and top invalid reason.
- Top failing questions and suggested fix/prevention.
- If failure signature repeats, update the ledger.

## References

- `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/HEADLESS_DOCS_INDEX.md`
- `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/ANVILOOP_RECURRING_ERRORS.md`
