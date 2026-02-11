#!/usr/bin/env python3
import argparse
import datetime
import json
import os
from collections import Counter, defaultdict


def load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def find_operator_reports(root):
    if os.path.isfile(root):
        if os.path.basename(root).lower() == "operator_report.json":
            return [root]
        return []
    reports = []
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            if name.lower() == "operator_report.json":
                reports.append(os.path.join(dirpath, name))
    return sorted(reports)


def find_invariant_paths(report_dir):
    snapshots = []
    invariants_path = os.path.join(report_dir, "invariants.json")
    if os.path.isfile(invariants_path):
        snapshots.append(invariants_path)
    try:
        for name in os.listdir(report_dir):
            if "invariant" in name.lower() and name.lower().endswith(".json"):
                full = os.path.join(report_dir, name)
                if full not in snapshots:
                    snapshots.append(full)
    except FileNotFoundError:
        pass
    return snapshots


def summarize_report(path):
    data = load_json(path)
    questions = data.get("questions") or []
    required_counts = Counter()
    unknown_reasons = Counter()
    for entry in questions:
        if not entry or not entry.get("required", False):
            continue
        status = (entry.get("status") or "unknown").lower()
        if status not in ("pass", "fail", "unknown"):
            status = "unknown"
        required_counts[status] += 1
        if status == "unknown":
            reason = entry.get("unknown_reason") or "unknown_reason_missing"
            unknown_reasons[reason] += 1

    blackcats = data.get("blackCats") or []
    blackcat_ids = Counter()
    for entry in blackcats:
        if not entry:
            continue
        cat_id = entry.get("id") or "unknown"
        blackcat_ids[cat_id] += 1

    report_dir = os.path.dirname(path)
    invariants = find_invariant_paths(report_dir)

    return {
        "path": path,
        "required_counts": dict(required_counts),
        "unknown_reasons": dict(unknown_reasons),
        "blackcats": {
            "total": len(blackcats),
            "ids": dict(blackcat_ids)
        },
        "invariant_snapshots": invariants
    }


def build_scoreboard(reports):
    overall_required = Counter()
    overall_unknown = Counter()
    overall_blackcats = Counter()
    invariant_paths = []
    report_entries = []

    for report in reports:
        entry = summarize_report(report)
        report_entries.append(entry)
        overall_required.update(entry["required_counts"])
        overall_unknown.update(entry["unknown_reasons"])
        overall_blackcats.update(entry["blackcats"]["ids"])
        for path in entry["invariant_snapshots"]:
            if path not in invariant_paths:
                invariant_paths.append(path)

    scoreboard = {
        "generated_utc": datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
        "summary": {
            "required_pass": overall_required.get("pass", 0),
            "required_fail": overall_required.get("fail", 0),
            "required_unknown": overall_required.get("unknown", 0),
            "required_total": sum(overall_required.values()),
            "report_count": len(report_entries)
        },
        "unknown_reasons": dict(overall_unknown),
        "blackcats": {
            "total": sum(overall_blackcats.values()),
            "ids": dict(overall_blackcats)
        },
        "invariant_snapshots": invariant_paths,
        "reports": report_entries
    }
    return scoreboard


def main():
    parser = argparse.ArgumentParser(description="Generate a scoreboard from operator_report.json files.")
    parser.add_argument("--root", required=True, help="Root directory (or operator_report.json path).")
    parser.add_argument("--out", default=None, help="Output path for scoreboard.json.")
    args = parser.parse_args()

    reports = find_operator_reports(args.root)
    if not reports:
        raise SystemExit(f"No operator_report.json found under: {args.root}")

    scoreboard = build_scoreboard(reports)
    if args.out:
        out_path = args.out
    else:
        base_dir = os.path.dirname(args.root) if os.path.isfile(args.root) else args.root
        out_path = os.path.join(base_dir, "scoreboard.json")

    with open(out_path, "w", encoding="utf-8") as handle:
        json.dump(scoreboard, handle, indent=2, sort_keys=True)
        handle.write("\n")

    summary = scoreboard["summary"]
    print(
        f"Wrote {out_path} | reports={summary['report_count']} "
        f"required(pass/fail/unknown)={summary['required_pass']}/{summary['required_fail']}/{summary['required_unknown']}"
    )


if __name__ == "__main__":
    main()
