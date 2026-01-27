---
name: anviloop-scoreboard
description: Generate and interpret the Anviloop nightly scoreboard and headline reports. Use when summarizing nightly status, validity counts, or top failing questions.
---

# Anviloop Scoreboard

## Generate

- From repo root: `Polish/Goals/scoreboard.py`

## Outputs

- `C:/polish/queue/reports/scoreboard.json`
- `C:/polish/queue/reports/nightly_headline_YYYYMMDD.md`
- `C:/polish/queue/reports/nightly_cycle_*.json`
- `C:/polish/queue/reports/nightly_timeline.log`

## Interpret

- Valid vs invalid counts.
- Top invalid reasons.
- Top failing questions.
- Next actions from headline cards.

## References

- `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/HEADLESS_DOCS_INDEX.md`
- `C:/Dev/unity_clean/headlessrebuildtool/Polish/Docs/MORNING_VIEW.md`
