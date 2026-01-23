# Decks

This folder holds JSON decks consumed by `Polish/run_deck.ps1`.

## How to add jobs
- Prefer `scenario_rel` under `Assets/Scenarios/` for portability and comparability.
- Use fixed seeds and conservative `timeout_sec` values.
- Keep `args` to non-scenario flags only.
- Set `base_ref` when a nightly base is known and pinned.

## SAFE vs EXTENDED
- SAFE decks should be small, reliable, and known to emit required questions.
- EXTENDED decks can include longer or flakier scenarios for later expansion.

## Why scenario_rel
`scenario_rel` makes jobs comparable across machines and avoids absolute path drift.
