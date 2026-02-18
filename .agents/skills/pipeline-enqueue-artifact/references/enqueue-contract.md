# Enqueue Contract

- Script: `Polish/pipeline_enqueue.ps1`
- Inputs:
  - `Title`
  - `QueueRoot` (explicit)
  - `ArtifactZip` or `BuildId`
  - optional `ScenarioId`, `ScenarioRel`, `GoalId`, `GoalSpec`, `Seed`, `Repeat`
- Behavior:
  - Reads artifact build outcome and rejects non-succeeded builds.
  - Emits `job=` lines and optional wait summaries.

# Related Monitoring

- `Polish/queue_status.ps1`
- `Polish/pipeline_watch_daemon.ps1`
