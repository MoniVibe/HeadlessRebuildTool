---
name: deck-run
description: Run or enqueue Anviloop deck JSONs using HeadlessRebuildTool's run_deck.ps1. Use when the user asks to run a deck/nightly cycle or execute multiple jobs defined in a deck.
---

# Deck Run

## Quick Start

```powershell
pwsh -NoProfile -File C:\Dev\unity_clean\headlessrebuildtool\Polish\run_deck.ps1 -DeckPath C:\polish\queue\reports\nightly_poc.json -UnityExe "C:\Program Files\Unity\Hub\Editor\6000.3.1f1\Editor\Unity.exe" -Mode run
```

## Workflow

1) If needed, create a deck with the `anviloop-deck` skill.
2) Run `run_deck.ps1` in one of three modes:
   - `run`: build + enqueue + wait for results.
   - `enqueue`: only write jobs to queue.
   - `monitor`: only watch queue/results.
3) Review `Polish/Docs/MORNING_VIEW.md` for the nightly checklist if this is a full cycle.

## Parameters (run_deck.ps1)

- `-DeckPath` (required)
- `-UnityExe` (required)
- `-QueueRoot` (optional override)
- `-Mode` (`run|enqueue|monitor`) — default `run`
- `-PollSec`, `-PendingGraceSec`, `-MaxMinutes`
- `-WslDistro` — default `Ubuntu`

## Notes

- Requires the WSL runner to be active for full runs.
- Does not open the Unity UI.
