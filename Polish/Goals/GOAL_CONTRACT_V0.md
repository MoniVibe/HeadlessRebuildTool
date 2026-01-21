# Anviloop Goal Contract v0

This contract defines a compact, portable goal report generated from a single
run's unzipped result bundle. The report is JSON and validated by
`goal_report_v0.schema.json`.

## Core Fields

- goal_id (string): Unique identifier for the goal (e.g., space4x_ftl_01).
- goal_version (string): Contract/spec version (v0).
- goal_status (PASS | FAIL | UNKNOWN | SKIPPED):
  - PASS: Required proof conditions are met.
  - FAIL: Run completed but required proof conditions are not met.
  - UNKNOWN: Run did not complete or required telemetry is missing.
  - SKIPPED: No goal_spec provided for this run.
- goal_score (0-5): 5-point score per v0 rubric.
- proof (array): Evidence entries (telemetry/log/operator hints).
- notes (array): Human-readable short notes about scoring decisions.
- run_refs (object): References to the run (build_id, job_id, paths).

## Scoring v0 (0-5)

1. Run completed + telemetry_summary exists.
2. telemetry_summary.event_total > 0.
3. Any proof signal exists (goal-prefixed telemetry OR log markers OR
   operator_report hints).
4. Required proof conditions in goal_spec are met.
5. Delta proof met (optional, e.g., elite > rookie).

## Output Location

The scorer writes:

```
<result_root>/out/goal_report.json
```

`result_root` is the directory containing `meta.json` and `out/`.

## Goal Spec Discovery

Goal specs are JSON documents placed under:

```
Polish/Goals/specs/
```

The runner/analyzer will attempt to locate a spec via:

- meta.json `goal_spec` (preferred; explicit path)
- meta.json `goal_id` (mapped to `specs/<goal_id>.json`)

If no spec is found, the run is marked SKIPPED by the scorer.
