# WSL Headless Runner (Polish Loop)

Runs headless scenario jobs from a queue, enforces watchdog timeouts, and publishes deterministic result bundles.
Start here: `Tools/Polish/Docs/HEADLESS_DOCS_INDEX.md`.

## Dependencies
Required:
- bash
- coreutils (date, ps, timeout, sha256sum)
- python3 (or python)

Optional:
- jq (JSON parsing; python fallback if missing)
- unzip/zip (archive handling; python zipfile fallback if missing)
- gdb (for hang/crash backtraces)

## Usage
Run one job (anviloop queue):
```bash
./wsl_runner.sh --queue /mnt/c/polish/anviloop/space4x/queue --once
```

Run as daemon (anviloop queue):
```bash
./wsl_runner.sh --queue /mnt/c/polish/anviloop/space4x/queue --daemon --reports-dir /mnt/c/polish/anviloop/space4x/queue/reports
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
- `--reports-dir <path>`: Where to write triage reports (default is `<queue>/reports`).
- `--once` / `--daemon`: Single-run or poll forever.
- `--heartbeat-interval <sec>`: Updates run heartbeat + lease mtime (default: 2).
- `--diag-timeout <sec>`: Time cap for diagnostics (default: 15).
- `--print-summary`: Print summary line after publishing each result bundle.
- `--requeue-stale-leases --ttl-sec <sec>`: Requeue leases past TTL.

## Queue Layout
Expected directories under `<queue>`:
- `jobs/` incoming `*.json` jobs
- `leases/` claimed jobs
- `results/` published `result_<job_id>.zip`
- `artifacts/` optional local artifact storage

Notes:
- For the Polish pipeline, queues live under `/mnt/c/polish/anviloop/<title>/queue`.
- For local debug runs, headlessctl uses `${TRI_STATE_DIR:-~/.local/state/tri-headless}` and does not need a queue.

## artifact_uri Resolution
Accepted forms:
- Windows drive paths: `C:\polish\anviloop\<title>\queue\artifacts\artifact_<id>.zip` -> `/mnt/c/polish/anviloop/<title>/queue/artifacts/...`
- UNC paths: `\\wsl$\Distro\home\oni\...` or `//wsl$/Distro/home/oni/...`
- Direct WSL paths on ext4

UNC shares resolve under `${UNC_ROOT:-/mnt/unc}` by default.

## Result Bundle
Each job produces `result_<job_id>.zip` (published atomically). Contents include:
- `meta.json`
- `out/stdout.log`
- `out/stderr.log`
- `out/player.log`
- `out/watchdog.json`
- `out/repro.txt`
- `out/progress.json`, `out/invariants.json`, `out/telemetry.ndjson` (when produced)
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
- `--outDir <out>` + Phase 0 diagnostics paths are always injected into the command line.
- `TRI_PARAM_OVERRIDES` and `TRI_FEATURE_FLAGS` are passed as JSON env vars (sorted keys) for determinism.
- Optional job field `env` supplies extra environment variables (string values) for a run.
- `invariants.json` includes `diagnostics_version: 1`; `determinism_hash` excludes build metadata and uses stable sim outputs only.
