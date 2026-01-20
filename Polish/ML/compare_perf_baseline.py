#!/usr/bin/env python3
import argparse
import json
import sys


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return None


def to_float(value):
    try:
        return float(value)
    except Exception:
        return None


def get_nested(obj, keys):
    current = obj
    for key in keys:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def delta_pct(current, baseline):
    if current is None or baseline is None:
        return None
    if baseline == 0:
        return None
    return (current - baseline) / baseline * 100.0


def build_report(baseline, run_summary, mode):
    baseline_perf = baseline.get("perf") if isinstance(baseline, dict) else {}
    current_perf = run_summary.get("perf") if isinstance(run_summary, dict) else {}

    base_tick_p95 = to_float(get_nested(baseline_perf, ["tick_total_ms", "p95"]))
    curr_tick_p95 = to_float(get_nested(current_perf, ["tick_total_ms", "p95"]))
    base_reserved = to_float(get_nested(baseline_perf, ["reserved_bytes_peak"]))
    curr_reserved = to_float(get_nested(current_perf, ["reserved_bytes_peak"]))
    base_alloc = to_float(get_nested(baseline_perf, ["allocated_bytes_peak"]))
    curr_alloc = to_float(get_nested(current_perf, ["allocated_bytes_peak"]))
    base_struct_p95 = to_float(get_nested(baseline_perf, ["structural_change_delta", "p95"]))
    curr_struct_p95 = to_float(get_nested(current_perf, ["structural_change_delta", "p95"]))

    tick_delta_pct = delta_pct(curr_tick_p95, base_tick_p95)
    reserved_delta_pct = delta_pct(curr_reserved, base_reserved)
    alloc_delta_pct = delta_pct(curr_alloc, base_alloc)
    struct_delta_pct = delta_pct(curr_struct_p95, base_struct_p95)

    regressions = []
    if tick_delta_pct is not None and tick_delta_pct > 20.0:
        regressions.append(
            {
                "metric": "tick_total_ms_p95",
                "baseline": base_tick_p95,
                "current": curr_tick_p95,
                "delta_pct": tick_delta_pct,
                "threshold_pct": 20.0,
            }
        )
    if reserved_delta_pct is not None and reserved_delta_pct > 30.0:
        regressions.append(
            {
                "metric": "reserved_bytes_peak",
                "baseline": base_reserved,
                "current": curr_reserved,
                "delta_pct": reserved_delta_pct,
                "threshold_pct": 30.0,
            }
        )

    status = "OK"
    if regressions:
        status = "REGRESSION"

    report = {
        "schema_version": 1,
        "mode": mode,
        "status": status,
        "thresholds": {"tick_total_ms_p95_pct": 20.0, "reserved_bytes_peak_pct": 30.0},
        "baseline": {
            "tick_total_ms_p95": base_tick_p95,
            "reserved_bytes_peak": base_reserved,
            "allocated_bytes_peak": base_alloc,
            "structural_change_delta_p95": base_struct_p95,
        },
        "current": {
            "tick_total_ms_p95": curr_tick_p95,
            "reserved_bytes_peak": curr_reserved,
            "allocated_bytes_peak": curr_alloc,
            "structural_change_delta_p95": curr_struct_p95,
        },
        "deltas_pct": {
            "tick_total_ms_p95": tick_delta_pct,
            "reserved_bytes_peak": reserved_delta_pct,
            "allocated_bytes_peak": alloc_delta_pct,
            "structural_change_delta_p95": struct_delta_pct,
        },
        "regressions": regressions,
    }
    return report, regressions


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Compare perf baseline against run_summary.json. SAFE fails on regression; "
            "WILD emits a report and never fails."
        )
    )
    parser.add_argument("baseline")
    parser.add_argument("run_summary")
    parser.add_argument("mode", nargs="?", default="safe", choices=["safe", "wild"])
    args = parser.parse_args()

    baseline = load_json(args.baseline) or {}
    run_summary = load_json(args.run_summary) or {}

    report, regressions = build_report(baseline, run_summary, args.mode)
    json.dump(report, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")

    if args.mode == "safe" and regressions:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
