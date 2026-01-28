---
name: buildbox-iterate
description: Trigger the Buildbox on-demand GitHub Actions workflow to rebuild and run headless sims on the desktop rig. Use when you need to test a branch/SHA remotely, iterate on a fix, or get diagnostics without desktop access.
---

# Buildbox Iterate

## Quick Start

Run the helper script in `scripts/trigger_buildbox.ps1`:

```powershell
pwsh -NoProfile -File scripts/trigger_buildbox.ps1 -Title space4x -Ref mybranch -Repeat 1 -WaitForResult
```

## Workflow

1) Ensure your code change is pushed to GitHub.
2) Trigger Buildbox for the target `title` + `ref`.
3) Wait for completion (optional).
4) Download diagnostics using `buildbox-download-diag` skill if needed.

## Parameters (helper script)

- `-Title` (`space4x|godgame`) – required.
- `-Ref` (branch/SHA) – required.
- `-Repeat` (int) – default 1.
- `-WaitForResult` (switch) – wait for run completion.
- `-CleanCache` (switch) – clears Bee/lock caches on desktop.
- `-QueueRoot` (string) – optional override.
- `-Repo` (string) – default `MoniVibe/HeadlessRebuildTool`.
- `-Workflow` (string) – default `buildbox_on_demand.yml`.

## Output

Prints:

- `run_id=<id>`
- `run_url=<url>`
- `status=<conclusion>` when waiting.

## Resources

### scripts/
- `trigger_buildbox.ps1`

## Notes

- Requires GitHub CLI (`gh`) with `gh auth login` completed.
