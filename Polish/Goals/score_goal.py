#!/usr/bin/env python3
import argparse
import json
import os
import re
import sys


def load_json(path):
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return None


def write_json(path, payload):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def read_tail(path, max_bytes=5 * 1024 * 1024):
    if not path or not os.path.isfile(path):
        return ""
    try:
        size = os.path.getsize(path)
    except Exception:
        size = 0
    try:
        with open(path, "rb") as handle:
            if size > max_bytes:
                handle.seek(-max_bytes, os.SEEK_END)
            data = handle.read()
        return data.decode("utf-8", errors="replace")
    except Exception:
        return ""


def to_float(value):
    try:
        return float(value)
    except Exception:
        return None


def collect_telemetry_signals(telemetry_path):
    counts = {}
    metric_last = {}
    metric_samples = {}
    total = 0
    if not telemetry_path or not os.path.isfile(telemetry_path):
        return total, counts, metric_last, metric_samples
    try:
        with open(telemetry_path, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                total += 1
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if isinstance(obj, dict):
                    event_type = obj.get("type") or obj.get("event") or obj.get("name") or obj.get("event_type")
                else:
                    event_type = None
                if event_type is None:
                    event_type = "unknown"
                event_type = str(event_type)
                counts[event_type] = counts.get(event_type, 0) + 1
                if isinstance(obj, dict) and event_type.lower() == "metric":
                    metric_name = obj.get("metric") or obj.get("name")
                    if metric_name and "value" in obj:
                        metric_key = str(metric_name)
                        metric_last[metric_key] = obj.get("value")
                        metric_samples.setdefault(metric_key, []).append(obj.get("value"))
    except Exception:
        return total, counts, metric_last, metric_samples
    return total, counts, metric_last, metric_samples


def match_prefixes(counts, prefixes):
    matches = []
    if not prefixes:
        return matches
    lowered = [(p or "").lower() for p in prefixes if p]
    for event_type, count in counts.items():
        key = event_type.lower()
        for prefix in lowered:
            if key.startswith(prefix):
                matches.append({"event_type": event_type, "prefix": prefix, "count": count})
                break
    return matches


def match_metric_prefixes(metric_last, prefixes):
    matches = []
    if not prefixes:
        return matches
    lowered = [(p or "").lower() for p in prefixes if p]
    for metric_name, value in metric_last.items():
        key = metric_name.lower()
        for prefix in lowered:
            if key.startswith(prefix):
                matches.append({"metric": metric_name, "prefix": prefix, "value": value})
                break
    return matches


def scan_logs_for_regex(log_paths, regexes):
    matches = []
    if not regexes:
        return matches
    compiled = []
    for pattern in regexes:
        if not pattern:
            continue
        try:
            compiled.append(re.compile(pattern, re.IGNORECASE))
        except re.error:
            continue
    if not compiled:
        return matches
    for path in log_paths:
        text = read_tail(path)
        if not text:
            continue
        for regex in compiled:
            if regex.search(text):
                matches.append({"regex": regex.pattern, "file": path})
    return matches


def operator_hints(operator_report, keywords, question_ids):
    matches = []
    if not isinstance(operator_report, dict):
        return matches
    if keywords:
        blob = json.dumps(operator_report, sort_keys=True).lower()
        for token in keywords:
            if token and token.lower() in blob:
                matches.append({"keyword": token})
    if question_ids and isinstance(operator_report.get("questions"), list):
        for item in operator_report.get("questions", []):
            if not isinstance(item, dict):
                continue
            qid = item.get("id")
            if qid and qid in question_ids:
                matches.append({"question_id": qid})
    return matches


def resolve_goal_spec(path):
    if not path:
        return None, None
    if os.path.isfile(path):
        return path, load_json(path)
    return None, None


def build_goal_report(result_root, goal_spec_path, goal_spec, run_summary, meta):
    out_dir = os.path.join(result_root, "out")
    goal_id = (goal_spec or {}).get("goal_id") or "unknown_goal"
    goal_version = (goal_spec or {}).get("goal_version") or "v0"

    proof = []
    notes = []
    score = 0
    status = "UNKNOWN"

    run_completed = False
    if isinstance(meta, dict) and meta.get("exit_reason"):
        run_completed = True
    if isinstance(run_summary, dict) and run_summary.get("exit_reason"):
        run_completed = True

    telemetry_summary = None
    if isinstance(run_summary, dict):
        telemetry_summary = run_summary.get("telemetry_summary")

    if goal_spec is None:
        status = "SKIPPED"
        notes.append("goal_spec missing; scorer skipped")
        return {
            "goal_id": goal_id,
            "goal_version": goal_version,
            "goal_status": status,
            "goal_score": score,
            "proof": proof,
            "notes": notes,
            "run_refs": {
                "result_root": result_root,
                "goal_spec": goal_spec_path,
            },
        }

    if run_completed and telemetry_summary is not None:
        score = 1
    else:
        notes.append("run incomplete or telemetry_summary missing")

    event_total = 0
    if isinstance(telemetry_summary, dict):
        event_total = telemetry_summary.get("event_total") or 0
    if score >= 1 and event_total > 0:
        score = 2
    elif score >= 1:
        notes.append("telemetry_summary.event_total missing or zero")

    proof_spec = goal_spec.get("proof") if isinstance(goal_spec, dict) else {}
    telemetry_prefixes = proof_spec.get("telemetry_event_prefixes") if isinstance(proof_spec, dict) else None
    log_regex = proof_spec.get("log_regex") if isinstance(proof_spec, dict) else None
    operator_contains = proof_spec.get("operator_contains") if isinstance(proof_spec, dict) else None
    operator_question_ids = proof_spec.get("operator_question_ids") if isinstance(proof_spec, dict) else None

    telemetry_path = os.path.join(out_dir, "telemetry.ndjson")
    _, telemetry_counts, metric_last, metric_samples = collect_telemetry_signals(telemetry_path)
    telemetry_matches = match_prefixes(telemetry_counts, telemetry_prefixes)
    for match in telemetry_matches:
        proof.append({"type": "telemetry", **match})

    metric_keys = proof_spec.get("metric_keys") if isinstance(proof_spec, dict) else None
    metric_prefixes = proof_spec.get("metric_prefixes") if isinstance(proof_spec, dict) else None
    metric_matches = []
    seen_metrics = set()
    if metric_keys:
        for metric_name in metric_keys:
            if metric_name in metric_last:
                metric_matches.append({"metric": metric_name, "value": metric_last.get(metric_name)})
                seen_metrics.add(metric_name)
    for match in match_metric_prefixes(metric_last, metric_prefixes):
        metric_name = match.get("metric")
        if metric_name and metric_name not in seen_metrics:
            metric_matches.append({"metric": metric_name, "value": match.get("value"), "prefix": match.get("prefix")})
            seen_metrics.add(metric_name)
    for match in metric_matches:
        proof.append({"type": "metric", "metric": match.get("metric"), "value": match.get("value"), "ok": True})

    log_paths = [
        os.path.join(out_dir, "player.log"),
        os.path.join(out_dir, "stdout.log"),
        os.path.join(out_dir, "stderr.log"),
    ]
    log_matches = scan_logs_for_regex(log_paths, log_regex)
    for match in log_matches:
        proof.append({"type": "log", **match})

    operator_report = load_json(os.path.join(out_dir, "operator_report.json")) or {}
    operator_matches = operator_hints(operator_report, operator_contains, operator_question_ids)
    for match in operator_matches:
        proof.append({"type": "operator", **match})

    has_proof_signal = bool(telemetry_matches or log_matches or operator_matches or metric_matches)
    if score >= 2 and has_proof_signal:
        score = 3
    elif score >= 2:
        notes.append("no proof signals detected")

    required_spec = goal_spec.get("required") if isinstance(goal_spec, dict) else {}
    proof_flags = {
        "telemetry": bool(telemetry_matches),
        "log": bool(log_matches),
        "operator": bool(operator_matches),
        "metric": bool(metric_matches),
    }

    thresholds_spec = goal_spec.get("thresholds") if isinstance(goal_spec, dict) else {}
    thresholds_ok = True
    if isinstance(thresholds_spec, dict):
        metric_max = thresholds_spec.get("metric_max")
        metric_min = thresholds_spec.get("metric_min")
        if isinstance(metric_max, dict):
            for metric_name, limit in metric_max.items():
                value = metric_last.get(metric_name)
                value_num = to_float(value)
                limit_num = to_float(limit)
                ok = value_num is not None and limit_num is not None and value_num <= limit_num
                thresholds_ok = thresholds_ok and ok
                proof.append(
                    {
                        "type": "metric",
                        "metric": metric_name,
                        "value": value,
                        "max": limit,
                        "ok": ok,
                    }
                )
        if isinstance(metric_min, dict):
            for metric_name, limit in metric_min.items():
                value = metric_last.get(metric_name)
                value_num = to_float(value)
                limit_num = to_float(limit)
                ok = value_num is not None and limit_num is not None and value_num >= limit_num
                thresholds_ok = thresholds_ok and ok
                proof.append(
                    {
                        "type": "metric",
                        "metric": metric_name,
                        "value": value,
                        "min": limit,
                        "ok": ok,
                    }
                )

    required_met = False
    if isinstance(required_spec, dict) and required_spec.get("all_of"):
        required_met = all(proof_flags.get(item, False) for item in required_spec.get("all_of", []))
    elif isinstance(required_spec, dict) and required_spec.get("any_of"):
        required_met = any(proof_flags.get(item, False) for item in required_spec.get("any_of", []))
    else:
        required_met = has_proof_signal

    if required_met and not thresholds_ok:
        notes.append("thresholds not met")

    required_met = required_met and thresholds_ok

    if score >= 3 and required_met:
        score = 4
    elif score >= 3:
        notes.append("required proof conditions not met")

    delta_spec = goal_spec.get("delta") if isinstance(goal_spec, dict) else None
    delta_met = False
    if isinstance(delta_spec, dict):
        prefix = delta_spec.get("telemetry_event_prefix")
        min_count = delta_spec.get("min_count")
        if prefix and isinstance(min_count, int):
            matches = match_prefixes(telemetry_counts, [prefix])
            count = sum(match["count"] for match in matches)
            if count >= min_count:
                delta_met = True
            proof.append(
                {
                    "type": "delta",
                    "telemetry_event_prefix": prefix,
                    "count": count,
                    "min_count": min_count,
                }
            )

    if score >= 4 and delta_met:
        score = 5

    if score >= 4:
        status = "PASS"
    elif run_completed:
        status = "FAIL"
    else:
        status = "UNKNOWN"

    run_refs = {
        "job_id": (meta or {}).get("job_id"),
        "build_id": (meta or {}).get("build_id"),
        "commit": (meta or {}).get("commit"),
        "scenario_id": (meta or {}).get("scenario_id"),
        "seed": (meta or {}).get("seed"),
        "result_root": result_root,
        "run_summary_path": os.path.join(out_dir, "run_summary.json"),
        "meta_path": os.path.join(result_root, "meta.json"),
        "goal_spec": goal_spec_path,
    }

    return {
        "goal_id": goal_id,
        "goal_version": goal_version,
        "goal_status": status,
        "goal_score": score,
        "proof": proof,
        "notes": notes,
        "run_refs": run_refs,
    }


def main():
    parser = argparse.ArgumentParser(description="Score a goal from a result bundle.")
    parser.add_argument("--result_root", required=True)
    parser.add_argument("--goal_spec", required=True)
    args = parser.parse_args()

    result_root = os.path.abspath(args.result_root)
    out_dir = os.path.join(result_root, "out")
    meta = load_json(os.path.join(result_root, "meta.json")) or {}
    run_summary = load_json(os.path.join(out_dir, "run_summary.json")) or {}

    goal_spec_path, goal_spec = resolve_goal_spec(args.goal_spec)
    report = build_goal_report(result_root, goal_spec_path, goal_spec, run_summary, meta)

    report_path = os.path.join(out_dir, "goal_report.json")
    write_json(report_path, report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
