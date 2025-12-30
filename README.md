# Headless Rebuild Tool (Godgame)

This repo contains a minimal WSL-friendly rebuild script for the Godgame headless Linux player.
It targets the Windows Unity editor by default to avoid Linux license failures.

## Requirements
- WSL2 with access to your Tri workspace.
- Windows Unity editor installed (default: `6000.3.1f1`).
- A Tri clone with `godgame/` and `puredots/` present.

## Quick start

```bash
export TRI_ROOT=/home/oni/Tri
export TRI_WIN='C:\\dev\\Tri'
export UNITY_WIN='C:\\Program Files\\Unity\\Hub\\Editor\\6000.3.1f1\\Editor\\Unity.exe'
./build_godgame_linux_from_wsl.sh
```

Build output is published to:
- `${TRI_ROOT}/Tools/builds/godgame/Linux_latest`

## Environment variables
- `TRI_ROOT`: WSL path to Tri root (required if not in default locations).
- `TRI_WIN`: Windows path to Tri root (default `C:\\dev\\Tri`).
- `UNITY_WIN`: Windows Unity path (default `6000.3.1f1`).
- `UNITY_LINUX`: Optional Linux Unity path if you choose to use Linux Unity.
- `FORCE_WINDOWS_UNITY`: `1` (default) forces Windows Unity; set to `0` to allow Linux fallback.
- `FORCE_LINUX_UNITY`: `1` forces Linux Unity.
- `PUBLISH_ROOT`: Override publish root (default `${TRI_ROOT}/Tools/builds/godgame`).

## Notes
- This repo includes snapshots of `headlessprompt.md`, `headless_runbook.md`, and `headlesstasks.md` for reference.
- These docs are copied from Tri and may need manual sync if the main repo changes.
