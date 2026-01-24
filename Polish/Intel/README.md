# Anviloop Intel Sidecar (MVP)

This sidecar watches result zips, extracts compact intel records, updates stable
signatures (Drain3), builds retrieval indices (embeddings + FAISS), and emits a
per-run "explain" JSON. It is non-blocking: if optional deps are missing, it
still produces intel records and explains with empty similarity sections.

Disk policy:
- Long-lived intel data stays on ext4 (default `/home/oni/anviloop_intel/`).
- No full logs or full zips are stored long-term; only compact metadata and
  short excerpts.

Setup (WSL):
```
cd /home/oni/headless/HeadlessRebuildTool
python3 -m venv .venv
source .venv/bin/activate
pip install -r Polish/Intel/requirements-wsl.txt
```

One-shot usage:
```
python3 Polish/Intel/anviloop_intel.py ingest-ledger
python3 Polish/Intel/anviloop_intel.py ingest-result-zip --result-zip /mnt/c/polish/queue/results/result_*.zip
```

Daemon watch mode:
```
python3 Polish/Intel/anviloop_intel.py daemon --results-dir /mnt/c/polish/queue/results --poll-sec 2
```

Explain latest (writes to C: reports):
```
python3 Polish/Intel/anviloop_intel.py ingest-result-zip --result-zip /mnt/c/polish/queue/results/result_*.zip
```

Choose-goal stub + reward logging:
```
python3 Polish/Intel/anviloop_intel.py choose-goal --plan /mnt/c/polish/queue/reports/nightly_plan.json --out /mnt/c/polish/queue/reports/choose_goal.json
python3 Polish/Intel/anviloop_intel.py log-reward --cycle-json /mnt/c/polish/queue/reports/nightly_cycle_*.json
```

Helper (creates venv if missing and runs daemon):
```
bash Polish/WSL/start_intel_daemon.sh
```
