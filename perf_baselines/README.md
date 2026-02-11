# Perf baselines

Use `perf_baseline_template.json` as a starter. Populate fields with values from
`run_summary.json.perf` after a known-good run.

Thresholds (compare_perf_baseline.py):
- SAFE: fail on regression if `tick_total_ms.p95` > +20% or `reserved_bytes_peak` > +30%.
- WILD: never fails; emits a regression report with deltas.

Compatibility:
- `analyze_run.py` prefers the new perf schema metrics (`timing.total_ms`,
  `memory.reserved_bytes`, `memory.allocated_bytes`, `structural.change_delta`) and
  falls back to the older dot-delimited names (`timing.total`, `memory.reserved.bytes`,
  `memory.allocated.bytes`, `structural.changeDelta`).
