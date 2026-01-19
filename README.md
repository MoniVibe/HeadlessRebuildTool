# Headless Rebuild Tool (Godgame + Space4X)

This repo contains minimal WSL-friendly rebuild scripts for the Godgame and Space4X headless Linux players.
It targets the Windows Unity editor by default to avoid Linux license failures.

## Requirements
- WSL2 with access to your Tri workspace.
- Windows Unity editor installed (default: `6000.3.1f1`).
- A Tri clone with `godgame/`, `space4x/`, and `puredots/` present.

## Quick start

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

## Environment variables
- `TRI_ROOT`: WSL path to Tri root (required if not in default locations).
- `TRI_STATE_DIR`: Shared ops/state dir (recommended: `/home/<user>/Tri/.tri/state`).
- `TRI_WIN`: Windows path to Tri root (default `C:\\dev\\Tri`).
- `UNITY_WIN`: Windows Unity path (default `6000.3.1f1`).
- `UNITY_LINUX`: Optional Linux Unity path if you choose to use Linux Unity.
- `FORCE_WINDOWS_UNITY`: `1` (default) forces Windows Unity; set to `0` to allow Linux fallback.
- `FORCE_LINUX_UNITY`: `1` forces Linux Unity.
- `PUBLISH_ROOT`: Override publish root for the selected script (default `${TRI_ROOT}/Tools/builds/godgame` or `${TRI_ROOT}/Tools/builds/space4x`).

## Ops bus state dir (shared WSL + Windows)
- WSL: `TRI_STATE_DIR=/home/<user>/Tri/.tri/state` (ext4).
- Windows: `TRI_STATE_DIR=\\wsl$\\<Distro>\\home\\<user>\\Tri\\.tri\\state`.

Requests should be written via `tri_ops.py request_rebuild` and use the current schema fields:
- `desired_build_commit` (optional)
- `notes` (optional)
Avoid older `min_commit` schemas in new requests.

## Notes
- This repo includes snapshots of `headlessprompt.md`, `headless_runbook.md`, and `headlesstasks.md` for reference.
- These docs are copied from Tri and may need manual sync if the main repo changes.
- Space4X Tier 2 behavior loops are currently failing in nightly (missing loops); rebuild tooling is stable but the pipeline is not fully green.

## Lean Git hygiene
- One branch per task; delete after merge.
- Prune remotes regularly (`git fetch --prune`).
- Avoid duplicate clones; prefer `git worktree`.
- Never commit logs, zips, or build outputs.
