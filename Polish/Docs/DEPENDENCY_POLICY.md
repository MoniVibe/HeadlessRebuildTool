# Dependency/Manifest Policy (Headless)

This policy defines how headless manifests and lockfiles are treated for evidence validity.

## Rules
- `Packages/manifest*.json` and `Packages/packages-lock*.json` are part of the runtime contract.
- Any drift during a run invalidates evidence. Drift must be committed intentionally.
- Nightly bases are pinned; implicit dependency changes are not comparable.

## What counts as drift
- File hash changes after a headless swap/restore cycle.
- Any unexpected `git status` in `Packages/` for manifest or lock files.

## Required actions on drift
- Classify run as INVALID (infra).
- Capture a compact diff snippet in explain JSON for quick diagnosis.
- Either revert drift or make an explicit dependency bump commit/PR.

## What not to do
- Do not leave drift uncommitted or assume it is harmless.
- Do not tune gameplay based on runs with manifest drift.
