# Daemon Lifecycle Scope

- Script managed: `Polish/pipeline_watch_daemon.ps1`
- Scope:
  - status
  - start
  - stop
  - ensure single instance

# Not In Scope

- manual enqueue from artifact zip
- run-level evidence extraction or diagnostics
- buildbox workflow dispatch

# Logs

- `.agents/skills/artifacts/pipeline-watch-daemon-ops/watch_<title>_*_stdout.log`
- `.agents/skills/artifacts/pipeline-watch-daemon-ops/watch_<title>_*_stderr.log`
