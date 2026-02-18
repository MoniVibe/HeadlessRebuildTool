# Evidence Schema Targets

Extractor writes:

- `evidence_summary.json`
- `evidence_report.md`

Expected summary keys:

- `schema_version`
- `generated_utc`
- `input_path`
- `bundle_kind`
- `exit_reason`
- `exit_code`
- `failure_signature`
- `raw_signature`
- `failing_invariants`
- `evidence_files`

This skill is mechanical extraction only. Interpretation belongs in triage workflow.
