# How To Generate Demo Report

`demo_report.py` packages headless run artifacts into a single human-readable report.

## Expected input folder

Point `--results_dir` at a folder that contains one or more of:

- result zip files (for example `result_*.zip`)
- extracted run folders containing `meta.json`, `result.json`, `out/run_summary.json`, `out/operator_report.json`, and/or `out/headless_answers.json`

The scanner is recursive, so nested run folders are supported.

## Commands

Windows (PowerShell):

```powershell
python .\Tools\Headless\demo_report.py --results_dir C:\polish\queue\results
```

WSL/Linux:

```bash
python3 ./Tools/Headless/demo_report.py --results_dir /mnt/c/polish/queue/results
```

Generate both markdown and HTML:

```powershell
python .\Tools\Headless\demo_report.py --results_dir C:\polish\queue\results --write_html
```

Custom output paths:

```powershell
python .\Tools\Headless\demo_report.py `
  --results_dir C:\polish\queue\results `
  --out_md C:\polish\reports\demo_report.md `
  --write_html `
  --out_html C:\polish\reports\demo_report.html
```

## Output

By default, files are written under `results_dir`:

- `demo_report.md`
- `demo_report.html` (only when `--write_html` is set)

The report includes:

- each discovered run (timestamp + scenario/task)
- question verdicts from `headless_answers.json` (or `operator_report.json` fallback)
- key metrics summaries:
  - determinism digests
  - profilebias deltas
  - module pipeline quality metrics
- artifact paths for traceability

## Sharing

Share `demo_report.md` directly in PRs, chat, or docs.
If a browser-friendly version is needed, share `demo_report.html` generated with `--write_html`.
