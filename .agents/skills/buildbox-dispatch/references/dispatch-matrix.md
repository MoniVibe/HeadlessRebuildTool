# Dispatch Commands

- Single run dispatch:
  - `scripts/trigger_buildbox.ps1`
- Multi-scenario bug hunt:
  - `Polish/Ops/bug_hunt_suite.ps1`
- Pre-dispatch runner audit:
  - `scripts/buildbox_sync_audit.ps1`

# Common Inputs

- Title: `space4x` or `godgame`
- Ref: remote branch or SHA reachable by workflow
- Optional overrides: `QueueRoot`, `ScenarioRel`, `EnvJson`, `PuredotsRef`, `ToolsRef`, `WorkflowRef`

# Evidence To Keep

- `run_id`
- `run_url`
- full dispatch command line (for reproduction)
