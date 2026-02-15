# Demo Pack Headless Runbook

## Purpose

Run repeatable demo-pack headless tasks and generate a shareable report bundle (`demo_report.md` / `demo_report.html`).

## Task Source of Truth

Demo-pack overrides are committed in:
- `Tools/Headless/task_overrides.json`

The task loader merges overrides on top of base tasks, so validator can rerun the same task set without editing `headless_tasks.json`.

## Standard Command Flow

1. Contract check:

```powershell
python Tools/Headless/headlessctl.py contract_check
```

2. Run a task:

```powershell
python Tools/Headless/headlessctl.py run_task <taskId>
```

Examples:
- `space4x_capital_20_vs_20_supergreen`
- `space4x_capital_100_vs_100_proper`
- `space4x_battle_slice_01_profilebias`

3. Build demo report from results:

```powershell
python Tools/Headless/demo_report.py --results_dir <results_dir> --write_html
```

## Expected Artifacts

For each run (zip or extracted folder), expect:
- `headless_answers.json`
- `operator_report.json`

For report packaging, expect:
- `demo_report.md`
- `demo_report.html` (when `--write_html` is supplied)

## Common Failure Classes

### `result-timeout`

Meaning:
- Run submission happened, but expected result zip was not observed before timeout.

First checks:
1. Confirm watcher/runner daemons are up and processing queue.
2. Check whether results directory is growing (new zips appearing late).
3. Inspect latest zip timestamps/sizes to distinguish delayed write vs no output.

### `exit=127`

Meaning:
- Runner failed before normal sim completion, usually process launch/env path class issue.

First checks:
1. Confirm `UNITY_EXE` resolves to a valid Unity executable on the runner.
2. Re-check preflight output for path/user/runner environment mismatches.
3. Verify runner service account context (especially WSL visibility if using WSL bridge).

## Operator Notes

- Keep `task_overrides.json` as the reproducible source for demo-pack tasks.
- Prefer rerunning via `run_task` task IDs rather than ad-hoc scenario args, so reports remain comparable.
