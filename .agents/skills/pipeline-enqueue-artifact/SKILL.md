---
name: pipeline-enqueue-artifact
description: Use when you have a built artifact zip or build id and need to enqueue one or more queue jobs via pipeline_enqueue with optional wait-for-result; dont use when you need to build or dispatch buildbox workflows; outputs enqueued job ids and optional result summary lines tied to a specific queue root.
---

# Pipeline Enqueue Artifact

Enqueue jobs from an existing artifact only.

## Procedure
1. Set queue root explicitly.
```powershell
$queueRoot = "C:\polish\anviloop\space4x\queue"
```
2. Enqueue from a known artifact zip.
```powershell
pwsh -NoProfile -File Polish/pipeline_enqueue.ps1 `
  -Title space4x `
  -ArtifactZip "<artifact-zip-path>" `
  -QueueRoot $queueRoot `
  -Repeat 1
```
3. Or enqueue from build id (artifact inferred from queue artifacts folder).
```powershell
pwsh -NoProfile -File Polish/pipeline_enqueue.ps1 `
  -Title space4x `
  -BuildId "<build-id>" `
  -QueueRoot $queueRoot `
  -Repeat 1
```
4. Optional: wait for result and capture exit reason.
```powershell
pwsh -NoProfile -File Polish/pipeline_enqueue.ps1 `
  -Title space4x `
  -ArtifactZip "<artifact-zip-path>" `
  -QueueRoot $queueRoot `
  -WaitForResult `
  -WaitTimeoutSec 1800
```

## Outputs And Success Criteria
- `job=<...>.json` lines are printed.
- `enqueued=<count>` is non-zero.
- With wait enabled: summary includes run index and `exit_reason`.
- Jobs are written under `<queueRoot>\jobs` and progress to results.

## Common Failures - What To Check Next
- Artifact not found: verify `artifact_*.zip` exists in `<queueRoot>\artifacts`.
- Build outcome not succeeded: inspect `logs/build_outcome.json` inside artifact zip.
- Scenario mismatch: pass explicit `-ScenarioRel`/`-ScenarioId` if defaults do not match intent.
- No results while waiting: confirm WSL runner/daemon is active for that queue root.

## Negative Examples
- Do not call this skill when the user asks to run Unity build generation.
- Do not call this skill when the user asks to trigger GitHub buildbox workflow.
- Do not call this skill when the user asks to summarize a completed diag artifact.

## Receipt (Required)
Write the standardized receipt after enqueue operations.
```powershell
pwsh -NoProfile -File .agents/skills/_shared/scripts/write_skill_receipt.ps1 `
  -SkillSlug pipeline-enqueue-artifact `
  -Status pass `
  -Reason "artifact enqueued" `
  -InputsJson '{"title":"space4x","queue_root":"C:\\polish\\anviloop\\space4x\\queue"}' `
  -CommandsJson '["Polish/pipeline_enqueue.ps1"]' `
  -PathsConsumedJson '["C:\\polish\\anviloop\\space4x\\queue\\artifacts"]' `
  -PathsProducedJson '[".agents\\skills\\artifacts\\pipeline-enqueue-artifact\\latest_manifest.json",".agents\\skills\\artifacts\\pipeline-enqueue-artifact\\latest_log.md"]'
```

## References
- `references/enqueue-contract.md`

