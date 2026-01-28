# Morning View (Anviloop)

Use this order to decide next actions quickly.

1) Buildbox diagnostics (primary)
   - `C:\polish\queue\reports\_diag_downloads\<run_id>\buildbox_diag_*`
   - Summaries (if generated): `diag_*.md` in the same folder.

2) Pipeline logs
   - `pipeline_smoke.log` artifact from the GitHub Actions run.

3) Queue results (desktop)
   - `C:\polish\anviloop\<title>\queue\results\result_*.zip`
   - Inspect: `out/run_summary.json`, `out/watchdog.json`, `out/player.log`

3b) Queue results (fallback/local)
   - `C:\polish\queue\results\result_*.zip`
   - Keep local runs minimal; verify artifacts match local commit SHA.

4) Intel summaries (if enabled)
   - `C:\polish\queue\reports\intel\explain_<job_id>.json`
   - `C:\polish\queue\reports\intel\questions_<job_id>.json`

5) Recurring error ledger
   - `C:\Dev\unity_clean\headlessrebuildtool\Polish\Docs\ANVILOOP_RECURRING_ERRORS.md`
   - If failure signature repeats, apply the documented fix first.
