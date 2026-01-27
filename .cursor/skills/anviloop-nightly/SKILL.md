---
name: anviloop-nightly
description: Run the Anviloop nightly protocol: disk gate, cleanup, required daemons, validity checks, chain-of-custody, and stop rules. Use when planning or executing nightly cycles.
---

# Anviloop Nightly Protocol

## Gates and cleanup (do first)

- Disk gate: `pwsh -NoProfile -Command "'C_free_GB=' + [math]::Round((Get-PSDrive C).Free/1GB,1)"`
  - Stop builds if < 40 GB.
- Queue cleanup: `pwsh -NoProfile -File Polish/cleanup_queue.ps1 -QueueRoot "C:/polish/queue" -RetentionDays 7 -KeepLastPerScenario 3 -Apply`

## Required daemons

- WSL runner: `./Polish/WSL/wsl_runner.sh --queue /mnt/c/polish/queue --daemon --print-summary --status-interval 60`
- Intel ingest: `Polish/Intel/anviloop_intel.py`
- Scoreboard/headline: `Polish/Goals/scoreboard.py`

## Nightly structure

- Cycle 0 sentinel once (FTL); proof in `out/player.log` contains `[Anviloop][FTL] FTL_JUMP` with `tick >= 30`.
- Exactly one concept goal per night.
- Do not change scenario and code in the same cycle (code-only first).

## Validity + chain-of-custody

- INVALID if telemetry missing/truncated, invariants missing, or oracle keys missing.
- Keep commits only with headless proof.
- Commit in artifact manifest must match result `meta.json`.

## Stop/switch rules

- If the same failure signature repeats twice, consult the ledger first.
- If disk drops below gate, stop builds and switch to analysis/doc.

## References

- `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/NIGHTLY_PROTOCOL.md`
- `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/MORNING_VIEW.md`
- `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/ANVILOOP_RECURRING_ERRORS.md`
