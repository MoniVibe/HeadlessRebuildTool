# Buildbox Runbook (Laptop Trigger)

1) Push your branch or SHA you want to test.
2) GitHub Actions -> HeadlessRebuildTool -> "Buildbox: on-demand rebuild + headless sim"
3) Inputs: title + ref (+ repeat, wait_for_result, clean_cache if needed)
4) Artifacts: pipeline_log
