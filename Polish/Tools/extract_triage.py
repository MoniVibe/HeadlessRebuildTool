#!/usr/bin/env python3
import argparse
import json
import sys
import zipfile
from collections import deque
from pathlib import Path


DEFAULT_REPORTS_DIR = Path("/mnt/c/polish/queue/reports")


def read_json_entry(zf, name):
    try:
        raw = zf.read(name)
    except KeyError:
        return None
    try:
        return json.loads(raw.decode("utf-8", errors="replace"))
    except json.JSONDecodeError:
        return None


def last_progress_marker(progress):
    if progress is None:
        return None
    if isinstance(progress, list):
        if not progress:
            return None
        entry = progress[-1]
    elif isinstance(progress, dict):
        entry = progress
    else:
        return None
    if not isinstance(entry, dict):
        return None
    return {
        "phase": entry.get("phase"),
        "checkpoint": entry.get("checkpoint"),
        "tick": entry.get("tick"),
    }


def telemetry_last_tick(zf):
    try:
        handle = zf.open("out/telemetry.ndjson")
    except KeyError:
        return None

    lines = deque(maxlen=200)
    with handle:
        for raw in handle:
            line = raw.decode("utf-8", errors="replace").strip()
            if line:
                lines.append(line)

    for line in reversed(lines):
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict):
            continue
        for key in ("tick", "simulation_tick", "world_tick", "frame", "frame_index"):
            if key in obj:
                return obj.get(key)
    return None


def watchdog_summary(watchdog):
    if not isinstance(watchdog, dict):
        return {}
    process_state = {
        "exit_code": watchdog.get("process_exit_code"),
        "exit_status": watchdog.get("process_exit_status", watchdog.get("raw_exit_status", watchdog.get("exit_status"))),
        "signal": watchdog.get("process_signal", watchdog.get("signal")),
    }
    return {
        "diag_reason": watchdog.get("diag_reason"),
        "process_state": process_state,
    }


def derive_job_id(zip_path, meta):
    if isinstance(meta, dict):
        job_id = meta.get("job_id")
        if isinstance(job_id, str) and job_id:
            return job_id
    name = zip_path.name
    if name.startswith("result_") and name.endswith(".zip"):
        return name[len("result_") : -len(".zip")]
    return name


def main():
    parser = argparse.ArgumentParser(description="Write triage summary for a result zip.")
    parser.add_argument("--result-zip", dest="result_zip", help="Path to result_<job>.zip")
    parser.add_argument("--outdir", default=str(DEFAULT_REPORTS_DIR), help="Directory for triage output JSON.")
    parser.add_argument("result_zip_pos", nargs="?", help="Path to result_<job>.zip (positional).")
    args = parser.parse_args()

    result_zip = args.result_zip or args.result_zip_pos
    if not result_zip:
        print("Missing --result-zip", file=sys.stderr)
        return 2

    zip_path = Path(result_zip)
    if not zip_path.exists():
        print(f"Result zip not found: {zip_path}", file=sys.stderr)
        return 2

    try:
        zf = zipfile.ZipFile(zip_path, "r")
    except zipfile.BadZipFile:
        print(f"Invalid zip file: {zip_path}", file=sys.stderr)
        return 2

    with zf:
        meta = read_json_entry(zf, "meta.json") or {}
        progress = read_json_entry(zf, "out/progress.json")
        watchdog = read_json_entry(zf, "out/watchdog.json")

        job_id = derive_job_id(zip_path, meta)
        summary = {
            "job_id": job_id,
            "exit_reason": meta.get("exit_reason"),
            "exit_code": meta.get("exit_code"),
            "failure_signature": meta.get("failure_signature"),
            "progress": last_progress_marker(progress),
            "telemetry_last_tick": telemetry_last_tick(zf),
            "invariants_present": "out/invariants.json" in zf.namelist(),
            "watchdog": watchdog_summary(watchdog),
        }

    out_dir = Path(args.outdir)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"triage_{job_id}.json"
    out_path.write_text(json.dumps(summary, indent=2, ensure_ascii=True), encoding="utf-8")
    print(f"Wrote triage summary: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
