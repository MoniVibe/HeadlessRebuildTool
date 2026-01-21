#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import subprocess
import tempfile
import zipfile
from datetime import datetime, timezone


def load_json_from_zip(zip_path, name):
    try:
        with zipfile.ZipFile(zip_path, "r") as zf:
            try:
                with zf.open(name) as handle:
                    return json.loads(handle.read().decode("utf-8"))
            except KeyError:
                return None
    except Exception:
        return None


def resolve_goal_spec_path(spec_value, goal_id, specs_dir, repo_root):
    if spec_value:
        candidate = spec_value
        if not os.path.isabs(candidate):
            candidate = os.path.join(repo_root, candidate)
        if os.path.isfile(candidate):
            return candidate
    if goal_id:
        candidate = os.path.join(specs_dir, f"{goal_id}.json")
        if os.path.isfile(candidate):
            return candidate
    return None


def run_scorer(score_goal_path, result_root, goal_spec_path):
    try:
        subprocess.run(
            [score_goal_path, "--result_root", result_root, "--goal_spec", goal_spec_path],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return None
    report_path = os.path.join(result_root, "out", "goal_report.json")
    if os.path.isfile(report_path):
        try:
            with open(report_path, "r", encoding="utf-8") as handle:
                return json.load(handle)
        except Exception:
            return None
    return None


def main():
    parser = argparse.ArgumentParser(description="Scoreboard for last N runs.")
    parser.add_argument("--results-dir", default=r"C:\polish\queue\results")
    parser.add_argument("--reports-dir", default=r"C:\polish\queue\reports")
    parser.add_argument("--limit", type=int, default=25)
    parser.add_argument("--goal-specs-dir", default=None)
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.abspath(os.path.join(script_dir, "..", ".."))
    specs_dir = args.goal_specs_dir or os.path.join(script_dir, "specs")
    score_goal_path = os.path.join(script_dir, "score_goal.py")

    os.makedirs(args.reports_dir, exist_ok=True)

    zips = []
    if os.path.isdir(args.results_dir):
        for name in os.listdir(args.results_dir):
            if name.startswith("result_") and name.endswith(".zip"):
                zips.append(os.path.join(args.results_dir, name))
    zips.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    zips = zips[: args.limit]

    entries = []
    triage = []
    for zip_path in zips:
        meta = load_json_from_zip(zip_path, "meta.json") or {}
        run_summary = load_json_from_zip(zip_path, "out/run_summary.json") or {}
        goal_spec_value = meta.get("goal_spec") or run_summary.get("goal_spec")
        goal_id = meta.get("goal_id") or run_summary.get("goal_id")

        goal_spec_path = resolve_goal_spec_path(goal_spec_value, goal_id, specs_dir, repo_root)
        goal_report = None

        temp_dir = None
        if goal_spec_path and os.path.isfile(score_goal_path):
            temp_dir = tempfile.mkdtemp(prefix="tri_goal_")
            with zipfile.ZipFile(zip_path, "r") as zf:
                zf.extractall(temp_dir)
            goal_report = run_scorer(score_goal_path, temp_dir, goal_spec_path)

        status = "SKIPPED"
        score = 0
        if goal_report:
            status = goal_report.get("goal_status") or status
            score = goal_report.get("goal_score") or 0
            goal_id = goal_report.get("goal_id") or goal_id

        entry = {
            "result_zip": zip_path,
            "job_id": meta.get("job_id"),
            "build_id": meta.get("build_id"),
            "commit": meta.get("commit"),
            "scenario_id": meta.get("scenario_id"),
            "seed": meta.get("seed"),
            "exit_reason": meta.get("exit_reason"),
            "exit_code": meta.get("exit_code"),
            "goal_id": goal_id,
            "goal_status": status,
            "goal_score": score,
            "goal_spec": goal_spec_path,
            "telemetry_event_total": (run_summary.get("telemetry_summary") or {}).get("event_total"),
            "utc": meta.get("end_utc") or meta.get("start_utc"),
        }
        entries.append(entry)

        if status not in ("PASS", "SKIPPED"):
            note = ""
            if goal_report and goal_report.get("notes"):
                note = goal_report["notes"][0]
            triage.append(
                {
                    "goal_id": goal_id,
                    "status": status,
                    "score": score,
                    "result_zip": zip_path,
                    "note": note or entry.get("exit_reason"),
                }
            )

        if temp_dir:
            shutil.rmtree(temp_dir, ignore_errors=True)

    scoreboard = {
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "limit": args.limit,
        "entries": entries,
    }

    scoreboard_path = os.path.join(args.reports_dir, "scoreboard.json")
    with open(scoreboard_path, "w", encoding="utf-8") as handle:
        json.dump(scoreboard, handle, indent=2, sort_keys=True)
        handle.write("\n")

    triage = triage[:3]
    triage_path = os.path.join(args.reports_dir, "triage_next.md")
    with open(triage_path, "w", encoding="utf-8") as handle:
        handle.write("# Triage Next\n\n")
        if not triage:
            handle.write("No failing goals in recent runs.\n")
        else:
            for item in triage:
                handle.write(f"- {item['goal_id']} status={item['status']} score={item['score']} note={item['note']}\n")
                handle.write(f"  result={item['result_zip']}\n")


if __name__ == "__main__":
    main()
