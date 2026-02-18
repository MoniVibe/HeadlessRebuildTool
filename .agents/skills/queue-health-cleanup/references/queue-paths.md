# Queue Paths

- Desktop queues:
  - `C:\polish\anviloop\space4x\queue`
  - `C:\polish\anviloop\godgame\queue`
- Legacy local fallback queue:
  - `C:\polish\queue`
- WSL consumer path:
  - `/mnt/c/polish/anviloop/<title>/queue`

# Commands

- Status snapshot: `Polish/queue_status.ps1`
- Retention cleanup: `Polish/cleanup_queue.ps1`

# Policy

- Always run dry-run first.
- Keep enough recent artifacts/results for active triage.
- Respect disk gate from `Polish/Docs/NIGHTLY_PROTOCOL.md`.
