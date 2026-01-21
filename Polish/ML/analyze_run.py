#!/usr/bin/env python3
import argparse
import glob
import json
import math
import os


def load_json(path):
    if not path or not os.path.exists(path):
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


def to_int(value):
    try:
        return int(value)
    except Exception:
        return None


def to_float(value):
    try:
        return float(value)
    except Exception:
        return None


def pick_value(obj, keys):
    if not isinstance(obj, dict):
        return None
    for key in keys:
        if key in obj and obj[key] is not None:
            return obj[key]
    return None


def pick_int(obj, keys):
    value = pick_value(obj, keys)
    return to_int(value)


def pick_nested_int(obj, keys):
    value = pick_int(obj, keys)
    if value is not None:
        return value
    if isinstance(obj, dict):
        summary = obj.get("summary")
        if isinstance(summary, dict):
            return pick_int(summary, keys)
    return None


def find_last_tick(inv):
    value = pick_int(inv, ["last_tick", "lastTick", "last_frame", "lastFrame"])
    if value is not None:
        return value
    if isinstance(inv, dict):
        progress = inv.get("progress")
        if isinstance(progress, dict):
            return pick_int(progress, ["last_tick", "lastTick", "tick", "frame", "sim_tick"])
    return None


def invariant_failed(item):
    if not isinstance(item, dict):
        return False
    if item.get("ok") is False:
        return True
    status = item.get("status")
    if isinstance(status, str) and status.lower() in ("fail", "failed", "error"):
        return True
    if item.get("passed") is False:
        return True
    return False


def collect_failing_invariants(inv):
    if not isinstance(inv, dict):
        return []
    candidates = None
    for key in (
        "failing_invariants",
        "failed_invariants",
        "invariant_failures",
        "failures",
        "failed",
        "failing",
    ):
        if key in inv:
            candidates = inv.get(key)
            break
    if candidates is None and isinstance(inv.get("invariants"), list):
        candidates = [item for item in inv.get("invariants", []) if invariant_failed(item)]
    if candidates is None:
        return []
    if isinstance(candidates, dict):
        candidates = [candidates]
    if not isinstance(candidates, list):
        return []
    failing = []
    for item in candidates:
        if isinstance(item, str):
            failing.append(item)
            continue
        if isinstance(item, dict):
            for key in ("id", "name", "key", "code"):
                if key in item and item[key] is not None:
                    failing.append(str(item[key]))
                    break
    seen = set()
    unique = []
    for item in failing:
        if item in seen:
            continue
        seen.add(item)
        unique.append(item)
    return unique


def gather_telemetry(out_dir):
    files = []
    ndjson_path = os.path.join(out_dir, "telemetry.ndjson")
    if os.path.isfile(ndjson_path):
        files.append(ndjson_path)
    for path in sorted(glob.glob(os.path.join(out_dir, "telemetry_invariant_*.json"))):
        if os.path.isfile(path):
            files.append(path)
    entries = []
    bytes_total = 0
    for path in files:
        try:
            size = int(os.path.getsize(path))
        except Exception:
            size = 0
        bytes_total += size
        rel = os.path.relpath(path, out_dir)
        entries.append({"path": f"out/{rel}", "bytes": size})
    if os.path.isfile(ndjson_path):
        format_hint = "ndjson"
    elif entries:
        format_hint = "per_event"
    else:
        format_hint = "none"
    return entries, bytes_total, format_hint


def compute_telemetry_summary(out_dir, top_limit=5):
    summary = {"event_total": 0, "top_event_types": []}
    path = os.path.join(out_dir, "telemetry.ndjson")
    if not os.path.isfile(path):
        summary["source"] = "missing"
        return summary

    counts = {}
    total = 0
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
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
            counts[str(event_type)] = counts.get(str(event_type), 0) + 1

    top = sorted(counts.items(), key=lambda item: item[1], reverse=True)[:top_limit]
    summary["event_total"] = total
    summary["top_event_types"] = [{"type": key, "count": value} for key, value in top]
    summary["source"] = "out/telemetry.ndjson"
    return summary


def percentile(values, p):
    if not values:
        return None
    values = sorted(values)
    if len(values) == 1:
        return float(values[0])
    position = (len(values) - 1) * p
    lower = int(math.floor(position))
    upper = int(math.ceil(position))
    if lower == upper:
        return float(values[lower])
    weight = position - lower
    return float(values[lower] * (1.0 - weight) + values[upper] * weight)


def parse_perf_telemetry(out_dir):
    perf = {
        "available": False,
        "tick_total_ms": {"p50": None, "p95": None},
        "reserved_bytes_peak": None,
        "allocated_bytes_peak": None,
        "structural_change_delta": {"p95": None},
        "source": "out/perf_telemetry.ndjson",
        "samples": {"tick_total_ms": 0, "structural_change_delta": 0},
    }
    path = os.path.join(out_dir, "perf_telemetry.ndjson")
    if not os.path.isfile(path):
        return perf

    tick_total_new = []
    tick_total_old = []
    structural_delta_new = []
    structural_delta_old = []
    reserved_peak_new = None
    reserved_peak_old = None
    allocated_peak_new = None
    allocated_peak_old = None

    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if not isinstance(obj, dict) or obj.get("type") != "metric":
                continue
            metric = obj.get("metric")
            value = to_float(obj.get("value"))
            if value is None:
                continue
            if metric == "timing.total_ms":
                tick_total_new.append(value)
            elif metric == "timing.total":
                tick_total_old.append(value)
            elif metric == "memory.reserved_bytes":
                reserved_peak_new = value if reserved_peak_new is None else max(reserved_peak_new, value)
            elif metric == "memory.reserved.bytes":
                reserved_peak_old = value if reserved_peak_old is None else max(reserved_peak_old, value)
            elif metric == "memory.allocated_bytes":
                allocated_peak_new = value if allocated_peak_new is None else max(allocated_peak_new, value)
            elif metric == "memory.allocated.bytes":
                allocated_peak_old = value if allocated_peak_old is None else max(allocated_peak_old, value)
            elif metric == "structural.change_delta":
                structural_delta_new.append(value)
            elif metric == "structural.changeDelta":
                structural_delta_old.append(value)

    perf["available"] = True
    tick_total = tick_total_new if tick_total_new else tick_total_old
    structural_delta = structural_delta_new if structural_delta_new else structural_delta_old
    perf["tick_total_ms"]["p50"] = percentile(tick_total, 0.50)
    perf["tick_total_ms"]["p95"] = percentile(tick_total, 0.95)
    perf["reserved_bytes_peak"] = reserved_peak_new if reserved_peak_new is not None else reserved_peak_old
    perf["allocated_bytes_peak"] = allocated_peak_new if allocated_peak_new is not None else allocated_peak_old
    perf["structural_change_delta"]["p95"] = percentile(structural_delta, 0.95)
    perf["samples"]["tick_total_ms"] = len(tick_total)
    perf["samples"]["structural_change_delta"] = len(structural_delta)
    return perf


def compute_score(exit_reason, runtime_sec, runtime_budget_sec, telemetry_bytes, telemetry_budget_bytes):
    breakdown = []
    total_loss = 0.0
    grade = "OK"
    reason = (exit_reason or "").upper()

    base_penalty = 0.0
    if reason == "SUCCESS":
        base_penalty = 0.0
    elif reason == "TEST_FAIL":
        base_penalty = 200.0
        grade = "FAIL"
    elif reason in ("INFRA_FAIL", "CRASH", "HANG_TIMEOUT"):
        base_penalty = 1000.0
        grade = "FAIL"
    else:
        base_penalty = 1000.0
        grade = "FAIL"

    if base_penalty > 0:
        breakdown.append(
            {
                "component": "base_exit_reason",
                "penalty": base_penalty,
                "reason": f"exit_reason={reason or 'UNKNOWN'}",
            }
        )
        total_loss += base_penalty

    runtime_over = max(0.0, runtime_sec - runtime_budget_sec)
    if runtime_over > 0:
        breakdown.append(
            {
                "component": "runtime_over_budget",
                "penalty": runtime_over,
                "reason": f"runtime_sec={runtime_sec} budget={runtime_budget_sec}",
            }
        )
        total_loss += runtime_over

    telemetry_over = max(0.0, telemetry_bytes - telemetry_budget_bytes) / 1e6
    if telemetry_over > 0:
        breakdown.append(
            {
                "component": "telemetry_over_budget",
                "penalty": telemetry_over,
                "reason": f"telemetry_bytes={telemetry_bytes} budget={telemetry_budget_bytes}",
            }
        )
        total_loss += telemetry_over

    if reason == "SUCCESS" and (runtime_over > 0 or telemetry_over > 0):
        grade = "WARN"

    return total_loss, breakdown, grade


def main():
    parser = argparse.ArgumentParser(description="Generate ML-friendly run summary and score.")
    parser.add_argument("--meta", required=True)
    parser.add_argument("--outdir", required=True)
    parser.add_argument("--runtime-budget-sec", type=int, default=120)
    parser.add_argument("--telemetry-budget-bytes", type=int, default=500 * 1024 * 1024)
    args = parser.parse_args()

    meta = load_json(args.meta) or {}
    out_dir = args.outdir
    os.makedirs(out_dir, exist_ok=True)

    inv_path = os.path.join(out_dir, "invariants.json")
    inv = load_json(inv_path)

    determinism_hash = None
    expected_sim_ticks = None
    sim_ticks_observed = None
    last_tick = None
    failing_invariants = []
    if isinstance(inv, dict):
        determinism_hash = pick_value(inv, ["determinism_hash", "determinismHash", "hash"])
        if determinism_hash is None:
            summary = inv.get("summary") if isinstance(inv.get("summary"), dict) else {}
            determinism_hash = pick_value(summary, ["determinism_hash", "determinismHash", "hash"])
        expected_sim_ticks = pick_nested_int(inv, ["expected_sim_ticks", "expectedSimTicks", "expected_ticks", "expectedTicks"])
        sim_ticks_observed = pick_nested_int(inv, ["sim_ticks", "simTicks", "ticks", "sim_tick", "simTick"])
        last_tick = find_last_tick(inv)
        failing_invariants = collect_failing_invariants(inv)

    telemetry_files, telemetry_bytes, telemetry_format = gather_telemetry(out_dir)
    telemetry_summary = compute_telemetry_summary(out_dir)
    perf_summary = parse_perf_telemetry(out_dir)

    artifact_paths = meta.get("artifact_paths")
    artifacts_present = []
    if isinstance(artifact_paths, dict):
        artifacts_present = sorted([str(key) for key in artifact_paths.keys()])

    runtime_sec = to_float(meta.get("duration_sec")) or 0.0

    run_summary = {
        "schema_version": 1,
        "job_id": meta.get("job_id"),
        "build_id": meta.get("build_id"),
        "commit": meta.get("commit"),
        "runner_host": meta.get("runner_host"),
        "runner_env": meta.get("runner_env"),
        "exit_reason": meta.get("exit_reason"),
        "exit_code": to_int(meta.get("exit_code")),
        "scenario_id": meta.get("scenario_id"),
        "seed": to_int(meta.get("seed")),
        "determinism_hash": determinism_hash,
        "expected_sim_ticks": expected_sim_ticks,
        "sim_ticks_observed": sim_ticks_observed,
        "last_tick": last_tick,
        "failing_invariants": failing_invariants,
        "runtime_sec": runtime_sec,
        "telemetry": {
            "files": telemetry_files,
            "bytes_total": int(telemetry_bytes),
            "format_hint": telemetry_format,
        },
        "telemetry_summary": telemetry_summary,
        "perf": perf_summary,
        "artifacts_present": artifacts_present,
    }

    total_loss, breakdown, grade = compute_score(
        meta.get("exit_reason"),
        runtime_sec,
        float(args.runtime_budget_sec),
        telemetry_bytes,
        float(args.telemetry_budget_bytes),
    )

    polish_score = {
        "schema_version": 1,
        "job_id": meta.get("job_id"),
        "build_id": meta.get("build_id"),
        "commit": meta.get("commit"),
        "total_loss": total_loss,
        "breakdown": breakdown,
        "thresholds": {
            "runtime_budget_sec": int(args.runtime_budget_sec),
            "telemetry_budget_bytes": int(args.telemetry_budget_bytes),
        },
        "grade": grade,
    }

    write_json(os.path.join(out_dir, "run_summary.json"), run_summary)
    write_json(os.path.join(out_dir, "polish_score_v0.json"), polish_score)


if __name__ == "__main__":
    main()
