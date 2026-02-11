#!/usr/bin/env python3
import argparse
import json
import sys
import zipfile
from collections import Counter
from pathlib import Path


DEFAULT_REPORTS_DIR = Path("/mnt/c/polish/queue/reports")
REPORT_PATHS = ("out/operator_report.json", "operator_report.json")


def read_json_entry(zf, name):
    try:
        raw = zf.read(name)
    except KeyError:
        return None
    try:
        return json.loads(raw.decode("utf-8", errors="replace"))
    except json.JSONDecodeError:
        return None


def derive_job_id(zip_path, meta):
    if isinstance(meta, dict):
        job_id = meta.get("job_id")
        if isinstance(job_id, str) and job_id:
            return job_id
    name = zip_path.name
    if name.startswith("result_") and name.endswith(".zip"):
        return name[len("result_") : -len(".zip")]
    return name


def resolve_report(zf):
    for path in REPORT_PATHS:
        report = read_json_entry(zf, path)
        if report is not None:
            return report, path
    return None, None


def normalize_questions(report):
    if not isinstance(report, dict):
        return []
    questions = report.get("questions")
    if not isinstance(questions, list):
        return []
    return [q for q in questions if isinstance(q, dict)]


def summarize_questions(questions):
    summary = {
        "required": {"pass": 0, "fail": 0, "unknown": 0},
        "optional": {"pass": 0, "fail": 0, "unknown": 0},
        "required_total": 0,
        "optional_total": 0,
    }
    unknown_reasons = Counter()
    failures = []

    for q in questions:
        status = (q.get("status") or "").lower()
        if status not in ("pass", "fail", "unknown"):
            status = "unknown"
        required = bool(q.get("required"))

        bucket = "required" if required else "optional"
        summary[bucket][status] += 1
        summary[f"{bucket}_total"] += 1

        if required and status == "unknown":
            reason = q.get("unknown_reason") or "unknown"
            unknown_reasons[reason] += 1

        if status == "fail":
            failures.append(
                {
                    "id": q.get("id") or "",
                    "answer": q.get("answer") or "",
                    "required": required,
                }
            )

    summary["unknown_reasons_required"] = dict(unknown_reasons.most_common(5))
    summary["failed_questions"] = failures
    return summary


def main():
    parser = argparse.ArgumentParser(description="Summarize question results for a result zip.")
    parser.add_argument("--result-zip", dest="result_zip", help="Path to result_<job>.zip")
    parser.add_argument("--outdir", default=str(DEFAULT_REPORTS_DIR), help="Directory for scoreboard output JSON.")
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
        report, report_path = resolve_report(zf)
        job_id = derive_job_id(zip_path, meta)
        questions = normalize_questions(report)
        summary = summarize_questions(questions)

        output = {
            "job_id": job_id,
            "scenario_id": report.get("scenarioId") if isinstance(report, dict) else None,
            "report_path": report_path,
            "required": summary["required"],
            "optional": summary["optional"],
            "required_total": summary["required_total"],
            "optional_total": summary["optional_total"],
            "unknown_reasons_required": summary["unknown_reasons_required"],
            "failed_questions": summary["failed_questions"],
        }

    out_dir = Path(args.outdir)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"questions_{job_id}.json"
    out_path.write_text(json.dumps(output, indent=2, ensure_ascii=True), encoding="utf-8")
    print(f"Wrote question scoreboard: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
