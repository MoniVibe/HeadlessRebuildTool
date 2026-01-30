# Missing Scripts Triage (Space4x)

## Symptom
Buildbox/pipeline_smoke fails with:
- `Missing scripts detected. See ...Space4X_HeadlessMissingScripts.log for asset paths.`
- or PPtr cast errors during BuildPlayer (Texture2D -> MonoScript)

## Evidence locations (buildbox diag)
- `build/Space4X_HeadlessMissingScripts.log` (authoritative list)
- `build/Space4X_HeadlessBuildFailure*.log` (build failure context)
- `build/Space4X_HeadlessEditor.log` (editor snapshot)

## Fast path (preferred)
1) Download the buildbox diag artifact.
2) Open `Space4X_HeadlessMissingScripts.log` and list the asset paths.
3) Fix each asset by either:
   - Removing the missing component, or
   - Replacing it with the correct script type.
4) Re-run buildbox.

## Local safety net (optional)
Use the editor tool:
`Space4X/Tools/Missing Scripts/Scan and Strip Prefabs`
- This will remove missing scripts from prefabs and produce:
  `Space4X_MissingScripts_Report.txt` in repo root.
- Commit the fixes if the report is clean.

## Notes
- Missing scripts often originate from deleted MonoBehaviours or renamed classes.
- PPtr cast failures are consistent with missing MonoScript references.

## Verification
- Buildbox run succeeds.
- No missing scripts log is produced.
- `build_result: Succeeded` in pipeline summary.
