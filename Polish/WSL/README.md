# WSL Headless Runner (Polish Loop)

Runs headless scenario jobs from a queue, enforces watchdog timeouts, and publishes deterministic result bundles.

## Dependencies
Required:
- bash
- coreutils (date, ps, timeout, sha256sum)
- unzip, zip
- jq

Optional:
- gdb (for hang/crash backtraces)

## Usage
Run one job:
```bash
./wsl_runner.sh --queue /mnt/c/polish/queue --once
```

Run as daemon:
```bash
./wsl_runner.sh --queue /mnt/c/polish/queue --daemon
```

Self-test:
```bash
./wsl_runner.sh --self-test
```

## Inspecting Result Bundles
- Unzip `result_<job_id>.zip` from `results/`.
- Review `meta.json` for exit status and repro command.
- Check `out/` for stdout/stderr, `player.log`, and `watchdog.json`.

## Key Options
- `--queue <path>`: Queue root with `jobs/`, `leases/`, `results/`.
- `--workdir <path>`: Run root (default: `~/polish/runs`). Must be on WSL ext4 (not `/mnt/c`).
- `--once` / `--daemon`: Single-run or poll forever.
- `--heartbeat-interval <sec>`: Updates run heartbeat + lease mtime (default: 2).
- `--diag-timeout <sec>`: Time cap for diagnostics (default: 15).

## Queue Layout
Canonical queue root (Windows <-> WSL):
- Windows: `C:\polish\queue`
- WSL: `/mnt/c/polish/queue`

Expected directories under `<queue>`:
- `jobs/` incoming `*.json` jobs
- `leases/` claimed jobs
- `results/` published `result_<job_id>.zip`
- `artifacts/` optional local artifact storage

## artifact_uri Resolution
Accepted forms:
- Windows drive paths: `C:\polish\queue\artifacts\artifact_<id>.zip` -> `/mnt/c/polish/queue/artifacts/...`
- UNC paths: `\\wsl$\Distro\home\oni\...` or `//wsl$/Distro/home/oni/...`
- Direct WSL paths on ext4

Preferred form for the Windows/WSL spine:
- `/mnt/c/polish/queue/artifacts/artifact_<build_id>.zip`

UNC shares resolve under `${UNC_ROOT:-/mnt/unc}` by default.

## Result Bundle
Each job produces `result_<job_id>.zip` (published atomically). Contents include:
- `meta.json`
- `out/stdout.log`
- `out/stderr.log`
- `out/player.log`
- `out/watchdog.json`
- `out/repro.txt`
- optional diagnostics (`gdb_bt.txt`, `system_snapshot.txt`, `ps_snapshot.txt`, `core_dump_path.txt`)

## Exit Codes
Standardized runner exit codes (also recorded in `meta.json`):
- `0`: SUCCESS
- `10`: TEST_FAIL
- `20`: INFRA_FAIL
- `30`: CRASH
- `40`: HANG_TIMEOUT

## meta.json Fields (required)
- `job_id`, `build_id`, `commit`, `scenario_id`, `seed`
- `start_utc`, `end_utc`, `duration_sec`
- `exit_reason`, `exit_code`
- `repro_command`
- `failure_signature` (sha256 hash of normalized signature string)
- `artifact_paths`
- `runner_host`, `runner_env`

## Notes
- `-logFile <out/player.log>` is forced unless the job args explicitly override it.
- `TRI_PARAM_OVERRIDES` and `TRI_FEATURE_FLAGS` are passed as JSON env vars (sorted keys) for determinism.
