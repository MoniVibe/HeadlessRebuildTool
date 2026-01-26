# Headless + Anviloop Docs Index

This is the entry point for running and triaging nightlies in Tri. Use this
before diving into deeper runbooks.

## Quick start (canonical path)
1) Windows: build + enqueue nightly packs
```
pwsh -File Tools/Polish/run_nightly.ps1 -Title space4x -Tier tier0 -UnityExe "C:\Program Files\Unity\Hub\Editor\6000.3.1f1\Editor\Unity.exe"
```
2) WSL: run the queue worker (per-title queue)
```
./Tools/Polish/WSL/wsl_runner.sh --queue /mnt/c/polish/anviloop/space4x/queue --daemon --print-summary --requeue-stale-leases --ttl-sec 600
```
3) Inspect results
- `/mnt/c/polish/anviloop/<title>/queue/results/result_<job_id>.zip`

## When to use headlessctl
Use `headlessctl` for single-task debug runs or when you want a deterministic
bundle outside the queue.
```
python Tools/Tools/Headless/headlessctl.py run_task S0.SPACE4X_SMOKE --seed 42 --pack nightly-default
```
Outputs go to `${TRI_STATE_DIR:-~/.local/state/tri-headless}/runs/<run_id>`.

## Queue roots (current)
- Space4X: `C:\polish\anviloop\space4x\queue` (WSL: `/mnt/c/polish/anviloop/space4x/queue`)
- Godgame: `C:\polish\anviloop\godgame\queue` (WSL: `/mnt/c/polish/anviloop/godgame/queue`)

Per-queue layout:
- `artifacts/`, `jobs/`, `leases/`, `results/`

## Bank + task sources
- Bank definition: `Tools/nightlylist.md`
- Bank -> task mapping: `Tools/nightlytasks.md`
- Runnable tasks: `Tools/Tools/Headless/headless_tasks.json`
- Env packs: `Tools/Tools/Headless/headless_packs.json`
- Canonical run rules: `puredots/Docs/Headless/headless_runbook.md`

## Result bundle (result_<job_id>.zip)
- `meta.json`
- `out/stdout.log`, `out/stderr.log`, `out/player.log`
- `out/telemetry.ndjson`, `out/invariants.json`, `out/progress.json` (when produced)

## Operational rules (summary)
- Do not edit `Assets/` or `.meta` from WSL; log blockers in `Tools/headless_asset_queue.md`.
- Respect `build.lock` when rebuilds are active (see `puredots/Docs/Headless/headless_runbook.md`).
- Tier-0 must be two-green before Tier-1/Tier-2 runs.

## Related docs
- `Tools/Polish/README.md`: pipeline and queue details.
- `Tools/Polish/WSL/README.md`: runner flags + result bundle layout.
- `Tools/Tools/Headless/README.md`: headlessctl and task registry.
