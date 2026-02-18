# Task Registries

- Tasks: `Tools/Headless/headless_tasks.json`
- Pack defaults: `Tools/Headless/headless_packs.json`
- Overrides: `Tools/Headless/task_overrides.json`

# Core Commands

- Run task: `python Tools/Headless/headlessctl.py run_task <task_id> --seed <n> --pack <pack>`
- Validate: `python Tools/Headless/headlessctl.py validate`
- Metrics: `get_metrics`, `diff_metrics`, `bundle_artifacts`
- Locks: `show_session_lock`, `claim_session_lock`, `release_session_lock`

# Artifact Root

- `$TRI_STATE_DIR/runs/<run_id>/`
