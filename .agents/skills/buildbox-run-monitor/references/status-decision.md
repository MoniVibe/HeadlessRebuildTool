# Decision Map

- `status in {queued, in_progress}`:
  - stay in monitor lane
- `status=completed` and `buildbox_diag_*` artifact exists:
  - move to `buildbox-diag-triage`
- `status=completed` and no diagnostics artifact:
  - inspect workflow logs first, then decide dispatch retry vs queue health checks

This skill is read-only and must not dispatch jobs.
