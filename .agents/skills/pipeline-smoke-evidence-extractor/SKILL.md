---
name: pipeline-smoke-evidence-extractor
description: Use when given artifact or result bundles and you need a mechanical extraction of minimum evidence set, failure signature, and invariant failures; dont use for full diagnosis narrative or workflow dispatch decisions; outputs evidence_summary.json and evidence_report.md under a deterministic artifacts directory.
---

# Pipeline Smoke Evidence Extractor

Extract evidence only. Do not interpret strategy here.

## Procedure
1. Run extractor on a bundle path (zip or extracted directory).
```powershell
pwsh -NoProfile -File .agents/skills/pipeline-smoke-evidence-extractor/scripts/extract_pipeline_smoke_evidence.ps1 `
  -InputPath "<result-or-artifact-path>"
```
2. Read outputs from printed paths:
  - `evidence_summary.json`
  - `evidence_report.md`
3. Hand off to triage skill for interpretation when needed.

## Outputs And Success Criteria
- Extractor prints `evidence_summary=` and `evidence_report=` paths.
- `evidence_summary.json` contains:
  - bundle kind (`result` or `artifact`)
  - exit reason/code (if available)
  - failure signature/raw signature
  - failing invariants list
  - consumed evidence file paths
- `evidence_report.md` mirrors the same facts in markdown.

## Common Failures - What To Check Next
- Unsupported input path: verify zip or directory exists and is readable.
- Missing expected files: bundle may be incomplete; confirm source artifact integrity.
- JSON parse failures: inspect malformed `meta.json` or `run_summary.json` in input bundle.
- Empty signatures: check watchdog and player logs for first error lines.

## Negative Examples
- Do not call this skill to decide fix priority across multiple runs.
- Do not call this skill when the user asks to dispatch or enqueue jobs.
- Do not call this skill to clean queue retention or monitor daemon health.

## Receipt (Required)
Write the standardized receipt after extraction.
```powershell
pwsh -NoProfile -File .agents/skills/_shared/scripts/write_skill_receipt.ps1 `
  -SkillSlug pipeline-smoke-evidence-extractor `
  -Status pass `
  -Reason "evidence extracted" `
  -InputsJson '{"input_path":"<result-or-artifact-path>"}' `
  -CommandsJson '[".agents/skills/pipeline-smoke-evidence-extractor/scripts/extract_pipeline_smoke_evidence.ps1"]' `
  -PathsConsumedJson '["<result-or-artifact-path>"]' `
  -PathsProducedJson '[".agents\\skills\\artifacts\\pipeline-smoke-evidence-extractor\\latest_manifest.json",".agents\\skills\\artifacts\\pipeline-smoke-evidence-extractor\\latest_log.md"]'
```

## References
- `references/evidence-schema.md`

