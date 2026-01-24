#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import subprocess
import tempfile
import zipfile
from datetime import datetime, timezone, timedelta


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


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return None


def load_expected_jobs(reports_dir):
    path = os.path.join(reports_dir, "expected_jobs.json")
    data = read_json(path)
    if not data:
        return []
    if isinstance(data, dict):
        data = data.get("jobs", [])
    if not isinstance(data, list):
        return []
    return [item for item in data if isinstance(item, dict)]


def reason_counts(items, key):
    counts = {}
    for item in items:
        reason = item.get(key)
        if not reason:
            continue
        counts[reason] = counts.get(reason, 0) + 1
    return sorted(
        [{"reason": reason, "count": count} for reason, count in counts.items()],
        key=lambda entry: (-entry["count"], entry["reason"]),
    )


def parse_utc(value):
    if not value or not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def next_action(entry):
    validity = entry.get("validity_status")
    reason = entry.get("validity_reason")
    goal_id = entry.get("goal_id") or "unknown_goal"
    score = entry.get("goal_score")
    bank_status = entry.get("bank_status")
    bank_test_id = entry.get("bank_test_id")
    if validity == "PENDING":
        return "NEXT: wait for runner backlog (pending)"
    if validity and validity != "VALID":
        detail = reason or "invalid_evidence"
        return f"NEXT: fix infra/instrumentation ({detail})"
    if bank_status in ("FAIL", "MISSING"):
        suffix = f" ({bank_test_id})" if bank_test_id else ""
        action = "fix bank failure" if bank_status == "FAIL" else "add bank proof"
        return f"NEXT: {action}{suffix}"
    if score:
        return f"NEXT: tune behavior for {goal_id} (score={score})"
    return f"NEXT: tune behavior for {goal_id}"


def main():
    parser = argparse.ArgumentParser(description="Scoreboard for last N runs.")
    parser.add_argument("--results-dir", default=r"C:\polish\queue\results")
    parser.add_argument("--reports-dir", default=r"C:\polish\queue\reports")
    parser.add_argument("--intel-dir", default=r"C:\polish\queue\reports\intel")
    parser.add_argument("--limit", type=int, default=25)
    parser.add_argument("--goal-specs-dir", default=None)
    parser.add_argument("--pending-grace-sec", type=int, default=600)
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
    invalid_reasons = []
    required_fail_counts = {}
    for zip_path in zips:
        meta = load_json_from_zip(zip_path, "meta.json") or {}
        run_summary = load_json_from_zip(zip_path, "out/run_summary.json") or {}
        goal_spec_value = meta.get("goal_spec") or run_summary.get("goal_spec")
        goal_id = meta.get("goal_id") or run_summary.get("goal_id")
        job_id = meta.get("job_id")

        explain = None
        explain_path = None
        explain_missing = False
        if job_id:
            explain_path = os.path.join(args.intel_dir, f"explain_{job_id}.json")
            if os.path.isfile(explain_path):
                explain = read_json(explain_path)
            else:
                explain_missing = True

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

        validity_status = None
        validity_reason = None
        if explain_missing:
            validity_status = "MISSING_EXPLAIN"
            validity_reason = "missing_explain"
        elif isinstance(explain, dict):
            validity = explain.get("validity") if isinstance(explain.get("validity"), dict) else {}
            validity_status = validity.get("status")
            entry_invalid = validity.get("invalid_reasons") if isinstance(validity, dict) else None
            if isinstance(entry_invalid, list) and entry_invalid:
                validity_reason = entry_invalid[0]
            if isinstance(explain.get("primary_evidence_issue"), str):
                validity_reason = explain.get("primary_evidence_issue")

        question_summary = None
        if isinstance(explain, dict) and isinstance(explain.get("questions"), dict):
            question_summary = explain.get("questions")
        bank_status = None
        bank_test_id = None
        if isinstance(explain, dict) and isinstance(explain.get("bank"), dict):
            bank_status = explain.get("bank", {}).get("status")
            bank_test_id = explain.get("bank", {}).get("test_id")
        if question_summary:
            for qid in question_summary.get("failing_required_ids", []) or []:
                required_fail_counts[qid] = required_fail_counts.get(qid, 0) + 1
        if validity_reason:
            invalid_reasons.append({"reason": validity_reason})

        entry = {
            "result_zip": zip_path,
            "job_id": job_id,
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
            "validity_status": validity_status,
            "validity_reason": validity_reason,
            "explain_path": explain_path if explain_path and os.path.isfile(explain_path) else None,
            "question_summary": question_summary,
            "bank_status": bank_status,
            "bank_test_id": bank_test_id,
            "utc": meta.get("end_utc") or meta.get("start_utc"),
        }
        entries.append(entry)

        invalid_evidence = validity_status in ("INVALID", "MISSING_EXPLAIN")
        if status not in ("PASS", "SKIPPED") or invalid_evidence:
            note = ""
            if goal_report and goal_report.get("notes"):
                note = goal_report["notes"][0]
            if invalid_evidence and validity_reason:
                note = validity_reason
            triage.append(
                {
                    "goal_id": goal_id,
                    "status": "INVALID" if invalid_evidence else status,
                    "score": score,
                    "result_zip": zip_path,
                    "note": note or entry.get("exit_reason"),
                }
            )

        if temp_dir:
            shutil.rmtree(temp_dir, ignore_errors=True)

    expected_jobs = load_expected_jobs(args.reports_dir)
    if expected_jobs:
        now = datetime.now(timezone.utc)
        existing_ids = {entry.get("job_id") for entry in entries if entry.get("job_id")}
        existing_prefixes = set()
        for zip_path in zips:
            name = os.path.basename(zip_path)
            if name.startswith("result_") and name.endswith(".zip"):
                existing_prefixes.add(name[:-4])
        for item in expected_jobs:
            job_id = item.get("job_id")
            if not job_id or job_id in existing_ids:
                continue
            expected_prefix = item.get("expected_result_prefix")
            if expected_prefix and expected_prefix in existing_prefixes:
                continue
            created_at = parse_utc(item.get("created_utc"))
            age_ok = False
            if created_at:
                age_ok = (now - created_at) < timedelta(seconds=args.pending_grace_sec)
            validity_status = "PENDING" if age_ok else "INVALID"
            validity_reason = "result_pending" if age_ok else "result_missing"
            entry = {
                "result_zip": None,
                "job_id": job_id,
                "build_id": item.get("build_id"),
                "commit": item.get("commit"),
                "scenario_id": item.get("scenario_id"),
                "seed": item.get("seed"),
                "exit_reason": "RESULT_MISSING",
                "exit_code": None,
                "goal_id": item.get("goal_id"),
                "goal_status": "SKIPPED",
                "goal_score": 0,
                "goal_spec": item.get("goal_spec"),
                "telemetry_event_total": None,
                "validity_status": validity_status,
                "validity_reason": validity_reason,
                "explain_path": None,
                "question_summary": None,
                "bank_status": "PENDING" if age_ok else "MISSING",
                "bank_test_id": None,
                "utc": item.get("created_utc"),
            }
            entries.append(entry)
            if not age_ok:
                invalid_reasons.append({"reason": "result_missing"})
                triage.append(
                    {
                        "goal_id": entry.get("goal_id") or "unknown_goal",
                        "status": "INVALID",
                        "score": 0,
                        "result_zip": "(missing)",
                        "note": "result_missing",
                    }
                )

    top_invalid = reason_counts(invalid_reasons, "reason")[:5]
    top_failed_questions = sorted(
        [{"question_id": key, "count": count} for key, count in required_fail_counts.items()],
        key=lambda item: (-item["count"], item["question_id"]),
    )[:5]
    jobs_total = len(entries)
    jobs_valid = len([e for e in entries if e.get("validity_status") == "VALID"])
    jobs_invalid = len([e for e in entries if e.get("validity_status") == "INVALID"])
    jobs_warn = len([e for e in entries if e.get("validity_status") == "OK_WITH_WARNINGS"])

    scoreboard = {
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "limit": args.limit,
        "summary": {
            "jobs_total": jobs_total,
            "jobs_valid": jobs_valid,
            "jobs_invalid": jobs_invalid,
            "jobs_ok_with_warnings": jobs_warn,
            "top_invalid_reasons": top_invalid,
            "top_failed_questions_required": top_failed_questions,
        },
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

    headline_path = os.path.join(
        args.reports_dir,
        f"nightly_headline_{datetime.now(timezone.utc).strftime('%Y%m%d')}.md",
    )
    with open(headline_path, "w", encoding="utf-8") as handle:
        handle.write(f"# Nightly Headline {datetime.now(timezone.utc).strftime('%Y%m%d')}\n\n")
        handle.write(
            f"- jobs_total={jobs_total} jobs_valid={jobs_valid} jobs_invalid={jobs_invalid} jobs_ok_with_warnings={jobs_warn}\n"
        )
        if top_invalid:
            items = ", ".join([f"{x['reason']}({x['count']})" for x in top_invalid])
            handle.write(f"- top_invalid_reasons: {items}\n")
        if top_failed_questions:
            items = ", ".join([f"{x['question_id']}({x['count']})" for x in top_failed_questions])
            handle.write(f"- top_failed_required_questions: {items}\n")
        handle.write("\n## Jobs\n")
        for entry in entries:
            validity = entry.get("validity_status") or "UNKNOWN"
            reason = entry.get("validity_reason") or ""
            question_summary = entry.get("question_summary") or {}
            req = question_summary.get("required") or {}
            opt = question_summary.get("optional") or {}
            req_line = f"req pass={req.get('pass',0)} fail={req.get('fail',0)} unknown={req.get('unknown',0)}"
            opt_line = f"opt pass={opt.get('pass',0)} fail={opt.get('fail',0)} unknown={opt.get('unknown',0)}"
            bank_status = entry.get("bank_status") or "UNKNOWN"
            bank_test_id = entry.get("bank_test_id")
            bank_line = f"bank={bank_status}"
            if bank_test_id:
                bank_line = f"{bank_line} test_id={bank_test_id}"
            handle.write("\n")
            handle.write(f"### {entry.get('job_id')}\n")
            handle.write(f"- goal={entry.get('goal_id')} scenario={entry.get('scenario_id')} seed={entry.get('seed')}\n")
            handle.write(f"- validity={validity} {reason}\n")
            handle.write(f"- oracle: {req_line}; {opt_line}\n")
            handle.write(f"- {bank_line}\n")
            handle.write(f"- score={entry.get('goal_score')} status={entry.get('goal_status')}\n")
            handle.write(f"- next: {next_action(entry)}\n")
            result_value = entry.get("result_zip") or "(missing)"
            handle.write(f"- result={result_value}\n")
            if entry.get("explain_path"):
                handle.write(f"- explain={entry.get('explain_path')}\n")


if __name__ == "__main__":
    main()
