# How To Generate Demo Report

`demo_report.py` packages headless run artifacts into a single human-readable report.

## Inputs It Expects

- A results directory that contains either:
- `.zip` run artifacts
- Extracted run folders (for example folders containing `result.json`, `headless_answers.json`, `operator_report.json`)

The scanner is recursive, so it can handle mixed layouts in one root folder.

## Windows Example

```powershell
python .\Tools\Headless\demo_report.py --results_dir C:\polish\queue\results
```

Optional HTML output:

```powershell
python .\Tools\Headless\demo_report.py --results_dir C:\polish\queue\results --html
```

Custom output paths:

```powershell
python .\Tools\Headless\demo_report.py `
  --results_dir C:\polish\queue\results `
  --output_md C:\polish\reports\demo_report.md `
  --html `
  --output_html C:\polish\reports\demo_report.html
```

## WSL Example

```bash
python3 ./Tools/Headless/demo_report.py --results_dir /mnt/c/polish/queue/results
```

Optional HTML output:

```bash
python3 ./Tools/Headless/demo_report.py --results_dir /mnt/c/polish/queue/results --html
```

## Output Files

- `demo_report.md` (default in `--results_dir`)
- `demo_report.html` (only when `--html` is set)

The report includes:

- run index (timestamp, task/scenario, required question status)
- per-run question outcomes (`PASS`/`FAIL`/`UNKNOWN`)
- `unknown_reason` when present
- key metrics such as determinism digests, profilebias deltas, and module quality/provenance values
- artifact paths (`zip`, `headless_answers.json`, `result.json`, `operator_report.json`)

## How To Share

- Share `demo_report.md` directly in PR comments, chat, or handoff notes.
- If recipients prefer rendered format, also share `demo_report.html`.
- Include the exact `--results_dir` used so others can reproduce the same report.
