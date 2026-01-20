# Green Pipeline Handoff (UTC)
Date: 2026-01-07 03:10:24 UTC

Tools:
- Branch: green-pipeline-smoke
- HEAD: 25c5fc3ae584e3ea9ee22a82e4d1a2f3c9c0e47e

Space4x:
- Branch: main
- HEAD: 1bcf70603020c72d0731af130c9b59cce91d4f59

Queue:
- Windows: C:\polish\queue
- WSL: /mnt/c/polish/queue

Commands:
- Start WSL daemon (from ext4 Tools clone):
  ./Polish/WSL/wsl_runner.sh --queue /mnt/c/polish/queue --daemon --print-summary --requeue-stale-leases --ttl-sec 600
- Run smoke (Windows PS):
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File Tools/Polish/pipeline_smoke.ps1 -Title Space4x -Repeat 10

Note:
- determinism divergence currently only differs by sim_ticks (1800 vs 1801).
