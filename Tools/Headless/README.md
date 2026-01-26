# Headless ACI Tooling

This folder is the canonical, versioned home for `headlessctl` and the task/pack registries.
Start here: `Tools/Polish/Docs/HEADLESS_DOCS_INDEX.md`.

## Tri convenience shim

Keep a thin wrapper or symlink at:

`<tri-root>/Tools/Headless/headlessctl`

The wrapper should exec this tool and set `TRI_ROOT` to the Tri repo root so scenarios and builds resolve correctly.

Optional override: set `HEADLESS_REBUILD_TOOL_ROOT` to point at this repo.

## Quick usage
Run a single task with deterministic artifacts:
```
python Tools/Tools/Headless/headlessctl.py run_task S0.SPACE4X_SMOKE --seed 42 --pack nightly-default
```
