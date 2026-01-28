# Buildbox Runbook (Laptop Trigger)

1) Push your branch or SHA you want to test.
2) GitHub Actions -> HeadlessRebuildTool -> "Buildbox: on-demand rebuild + headless sim"
3) Inputs: title + ref (+ repeat, wait_for_result, clean_cache if needed)
4) Artifacts:
   - pipeline_log (pipeline_smoke.log)
   - buildbox_diag_<title>_<run_id> (always-on diagnostics bundle)

Diagnostics bundle contents (when available):
- pipeline_smoke.log
- pipeline_smoke_summary_latest.md
- results/<result_zip_name>/meta.json
- results/<result_zip_name>/out/run_summary.json
- results/<result_zip_name>/out/watchdog.json
- results/<result_zip_name>/out/invariants.json
- logs/watchdog_heartbeat.log (tail)
- logs/watch_daemon_<title>.log (tail)
- logs/wsl_runner_<title>.log (tail)
- logs/intel_<title>.log (tail)
- reports/triage_*.json (latest 5)
- diag_summary.txt (zip_count + extraction notes)

Remote triage:
1) gh run list -R MoniVibe/HeadlessRebuildTool --workflow buildbox_on_demand.yml --limit 5
2) gh run download <RUN_ID> -R MoniVibe/HeadlessRebuildTool -n buildbox_diag_<title>_<RUN_ID>
3) Inspect buildbox_diag/results/*/meta.json and out/*.json for failure_signature + exit_reason

Notes:
- The workflow looks for zips in both queue\results (result_*.zip) and queue\artifacts (artifact_*.zip).
- It also parses pipeline_smoke.log for explicit artifact paths to extract diagnostics.
- Raw zips are not uploaded to keep artifacts small; only extracted JSONs are included.
