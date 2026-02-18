# Session Lock Files

- Session lock path:
  - `$TRI_STATE_DIR/ops/locks/nightly_session.lock`
- Legacy lock paths may exist under queue reports and can be reclaimed by cleanup.

# Commands

- Show lock: `headlessctl.py show_session_lock`
- Claim lock: `headlessctl.py claim_session_lock --ttl <sec> --purpose <label>`
- Release lock: `headlessctl.py release_session_lock --run-id <id>`
- Cleanup stale lock files: `headlessctl.py cleanup_locks --ttl <sec>`

# Policy

- Never run overlapping nightly orchestrators.
- Release lock at end of run.
