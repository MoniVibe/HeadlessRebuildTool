# Fallback Policy

- Preferred path is remote buildbox workflow dispatch.
- Local fallback is emergency-only and must be explicit with `-AllowLocalBuild`.
- Use conservative queue root: `C:\polish\queue`.
- Keep scope minimal: one title, one scenario, one repeat.

# Related Files

- `Polish/run_deck.ps1`
- `Polish/pipeline_smoke.ps1`
- `Polish/Docs/NIGHTLY_PROTOCOL.md`
- `Polish/Docs/HEADLESS_DOCS_INDEX.md`
