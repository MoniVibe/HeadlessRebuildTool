# Headless Tooling (Tri)

## CURRENT: Polish/Anviloop pipeline
The canonical path for nightlies and headless runs is the Polish queue pipeline.
Start here: `Polish/Docs/HEADLESS_DOCS_INDEX.md`.

Key entry points:
- `Polish/run_nightly.ps1`
- `Polish/pipeline_smoke.ps1`
- `Tools/Tools/Headless/headlessctl.py`

## Minimal scripts (legacy fallback)
These WSL-friendly rebuild scripts remain for manual/dev use only.
They target the Windows Unity editor by default to avoid Linux license failures.

### Requirements
- WSL2 with access to your Tri workspace.
- Windows Unity editor installed (default: `6000.3.1f1`).
- A Tri clone with `godgame/`, `space4x/`, and `puredots/` present.

### Quick start
```bash
export TRI_ROOT=/home/oni/Tri
export TRI_STATE_DIR="$TRI_ROOT/.tri/state"
export TRI_WIN='C:\\dev\\Tri'
export UNITY_WIN='C:\\Program Files\\Unity\\Hub\\Editor\\6000.3.1f1\\Editor\\Unity.exe'
./build_godgame_linux_from_wsl.sh
./build_space4x_linux_from_wsl.sh
```

Build output is published to:
- `${TRI_ROOT}/Tools/builds/godgame/Linux_latest`
- `${TRI_ROOT}/Tools/builds/space4x/Linux_latest`

### Environment variables
- `TRI_ROOT`: WSL path to Tri root (required if not in default locations).
- `TRI_STATE_DIR`: Shared ops/state dir (recommended: `/home/<user>/Tri/.tri/state`).
- `TRI_WIN`: Windows path to Tri root (default `C:\\dev\\Tri`).
- `UNITY_WIN`: Windows Unity path (default `6000.3.1f1`).
- `UNITY_LINUX`: Optional Linux Unity path if you choose to use Linux Unity.
- `FORCE_WINDOWS_UNITY`: `1` (default) forces Windows Unity; set to `0` to allow Linux fallback.
- `FORCE_LINUX_UNITY`: `1` forces Linux Unity.
- `PUBLISH_ROOT`: Override publish root for the selected script (default `${TRI_ROOT}/Tools/builds/godgame` or `${TRI_ROOT}/Tools/builds/space4x`).

### Ops bus state dir (shared WSL + Windows)
- WSL: `TRI_STATE_DIR=/home/<user>/Tri/.tri/state` (ext4).
- Windows: `TRI_STATE_DIR=\\wsl$\\<Distro>\\home\\<user>\\Tri\\.tri\\state`.

Requests should be written via `tri_ops.py request_rebuild` and use the current schema fields:
- `desired_build_commit` (optional)
- `notes` (optional)
Avoid older `min_commit` schemas in new requests.

## One canonical config layer (planned)
Add `Polish/polish_config.json` as the single source of truth for queue root, Unity path,
workspace root, WSL distro, `TRI_STATE_DIR`, and similar. All scripts should read it,
with environment variables as overrides.

## Unity version alignment (planned)
On Windows, parse `ProjectSettings/ProjectVersion.txt` and validate that `UNITY_WIN`
matches the required version. If multiple Editors are installed, select the right one.
Fail fast on mismatch.

## Deprecation boundary
`headlessctl` + the Polish pipeline are the standard. Keep `build_*_linux_from_wsl.sh`
as manual/dev fallback only and avoid expanding them with new features.

## Schema + validation for evidence (planned)
Add JSON Schemas for job requests, `meta.json`, `run_summary.json`, and explain/questions
outputs. Add `headlessctl validate_result_zip <zip>` to fail fast when structure is missing.

## Unify task bank (planned)
`Tools/Tools/Headless/headless_tasks.json` is the executable source of truth. Make
`headlesstasks.md` a generated view of that JSON, or ensure both link to each task ID.

## Lean Git hygiene
- One branch per task; delete after merge.
- Prune remotes regularly (`git fetch --prune`).
- Avoid duplicate clones; prefer `git worktree`.
- Never commit logs, zips, or build outputs.
