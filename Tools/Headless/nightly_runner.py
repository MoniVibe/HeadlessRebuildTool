#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone


def resolve_state_dir():
    state_dir = os.environ.get("TRI_STATE_DIR")
    if state_dir:
        return state_dir
    home = os.environ.get("HOME")
    if home and os.access(home, os.W_OK):
        base = os.environ.get("XDG_STATE_HOME", os.path.join(home, ".local", "state"))
        return os.path.join(base, "tri-headless")
    tri_root = os.environ.get("TRI_ROOT", os.getcwd())
    return os.path.join(tri_root, ".tri", "state")


def resolve_tasks_path():
    return os.path.join(os.path.dirname(__file__), "headless_tasks.json")


def resolve_nightly_lock_path(state_dir):
    return os.path.join(state_dir, "ops", "locks", "nightly.lock")


def should_skip_for_nightly_lock(lock_path, ttl_sec):
    if not os.path.exists(lock_path):
        return False, None
    try:
        age = time.time() - os.path.getmtime(lock_path)
        if age > ttl_sec:
            os.remove(lock_path)
            return False, None
    except Exception as exc:
        return True, f"nightly_lock_unremovable:{exc}"
    return True, "nightly_lock"


def write_nightly_lock(lock_path, tag, tasks):
    os.makedirs(os.path.dirname(lock_path), exist_ok=True)
    payload = {
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "pid": os.getpid(),
        "tag": tag,
        "tasks": tasks
    }
    with open(lock_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)


def clear_nightly_lock(lock_path):
    try:
        if os.path.exists(lock_path):
            os.remove(lock_path)
    except Exception:
        pass


def load_tasks(tasks_path):
    with open(tasks_path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    return data.get("tasks", {})


def parse_task_list(value):
    if not value:
        return []
    return [item.strip() for item in value.split(",") if item.strip()]


def task_sort_key(task_id, task):
    order = task.get("nightly_order")
    if isinstance(order, int):
        return (order, task_id)
    if isinstance(order, float):
        return (int(order), task_id)
    return (1000, task_id)


def is_fast_smoke(task):
    tags = task.get("tags") or []
    return "fast_smoke" in tags


def prioritize_fast_smoke(task_ids, task_data):
    fast = []
    rest = []
    for task_id in task_ids:
        task = task_data.get(task_id, {})
        if is_fast_smoke(task):
            fast.append(task_id)
        else:
            rest.append(task_id)
    return fast + rest


def select_tasks(task_data, tag, task_ids):
    if task_ids:
        missing = [task_id for task_id in task_ids if task_id not in task_data]
        if missing:
            raise ValueError(f"unknown tasks: {', '.join(missing)}")
        return task_ids
    selected = []
    for task_id, task in task_data.items():
        tags = task.get("tags") or []
        if tag in tags:
            selected.append(task_id)
    selected.sort(key=lambda task_id: task_sort_key(task_id, task_data[task_id]))
    return selected


def run_headlessctl(args):
    tool_path = os.path.join(os.path.dirname(__file__), "headlessctl.py")
    proc = subprocess.run(
        [sys.executable, tool_path] + args,
        stdout=subprocess.PIPE,
        stderr=sys.stderr,
        text=True,
        encoding="utf-8",
        errors="replace"
    )
    data = None
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            data = json.loads(line)
        except Exception:
            continue
    if data is None:
        data = {
            "ok": False,
            "error_code": "no_stdout",
            "error": "headlessctl produced no JSON output",
            "run_id": None
        }
    return data, proc.returncode


def find_previous_run(state_dir, task_id, exclude_run_id):
    runs_dir = os.path.join(state_dir, "runs")
    if not os.path.isdir(runs_dir):
        return None
    candidates = []
    for entry in os.listdir(runs_dir):
        result_path = os.path.join(runs_dir, entry, "result.json")
        if not os.path.exists(result_path):
            continue
        try:
            with open(result_path, "r", encoding="utf-8") as handle:
                result = json.load(handle)
        except Exception:
            continue
        if result.get("task_id") != task_id:
            continue
        run_id = result.get("run_id")
        if not run_id or run_id == exclude_run_id:
            continue
        ended_utc = result.get("ended_utc")
        if not ended_utc:
            continue
        candidates.append((ended_utc, result))
    if not candidates:
        return None
    candidates.sort(key=lambda item: item[0])
    return candidates[-1][1]


def compute_top_deltas(prev_metrics, curr_metrics, limit=5):
    deltas = []
    for key, current in curr_metrics.items():
        prev = prev_metrics.get(key)
        if isinstance(current, (int, float)) and isinstance(prev, (int, float)):
            delta = current - prev
            deltas.append({
                "key": key,
                "previous": prev,
                "current": current,
                "delta": delta
            })
    deltas.sort(key=lambda item: abs(item["delta"]), reverse=True)
    return deltas[:limit]


def evaluate_run(run_result, metrics_result):
    failures = []
    if not run_result.get("ok", False):
        failures.append("run_failed")

    for inv in metrics_result.get("invariants", []):
        if inv.get("ok") is False:
            failures.append(f"invariant:{inv.get('name')}")

    metrics_summary = metrics_result.get("metrics_summary", {})
    truncated = metrics_summary.get("telemetry.truncated")
    if not isinstance(truncated, (int, float)):
        failures.append("telemetry.truncated_missing")
    elif truncated != 0:
        failures.append(f"telemetry.truncated:{truncated}")

    bank_required = run_result.get("bank_required")
    bank_status = run_result.get("bank_status") or {}
    if bank_required:
        if bank_status.get("status") != "PASS":
            failures.append("bank_failed")

    return failures


def main():
    parser = argparse.ArgumentParser(description="Run nightly headless tasks.")
    parser.add_argument("--tag", default="nightly", help="Task tag to select.")
    parser.add_argument("--tasks", default="", help="Comma-separated task ids to run.")
    parser.add_argument("--gate", action="store_true", help="Run S2/S3 gate tasks before other work.")
    parser.add_argument("--gate-hours", type=int, default=24, help="Skip gate tasks if last green is newer than hours.")
    args = parser.parse_args()

    state_dir = resolve_state_dir()
    nightly_lock_path = resolve_nightly_lock_path(state_dir)
    nightly_lock_ttl = int(os.environ.get("TRI_NIGHTLY_LOCK_TTL_SEC", "21600"))
    skip_for_lock, lock_reason = should_skip_for_nightly_lock(nightly_lock_path, nightly_lock_ttl)
    if skip_for_lock:
        summary = {
            "ok": True,
            "skipped": True,
            "reason": lock_reason,
            "tag": args.tag,
            "tasks": []
        }
        summary_path = os.path.join(os.getcwd(), "nightly_summary.json")
        with open(summary_path, "w", encoding="utf-8") as handle:
            json.dump(summary, handle, indent=2, sort_keys=True)
        return
    lock_path = os.path.join(state_dir, "ops", "locks", "build.lock")
    if os.path.exists(lock_path):
        summary = {
            "ok": True,
            "skipped": True,
            "reason": "build_lock",
            "tag": args.tag,
            "tasks": []
        }
        summary_path = os.path.join(os.getcwd(), "nightly_summary.json")
        with open(summary_path, "w", encoding="utf-8") as handle:
            json.dump(summary, handle, indent=2, sort_keys=True)
        return

    session_lock = None
    try:
        session_lock, _ = run_headlessctl(["claim_session_lock", "--ttl", "5400", "--purpose", "nightly_runner"])
        if not session_lock.get("acquired"):
            summary = {
                "ok": False,
                "skipped": True,
                "reason": "session_lock",
                "tag": args.tag,
                "tasks": [],
                "lock": session_lock.get("lock"),
                "lock_path": session_lock.get("lock_path")
            }
            summary_path = os.path.join(os.getcwd(), "nightly_summary.json")
            with open(summary_path, "w", encoding="utf-8") as handle:
                json.dump(summary, handle, indent=2, sort_keys=True)
            return

        write_nightly_lock(nightly_lock_path, args.tag, [])

        tasks_path = resolve_tasks_path()
        task_data = load_tasks(tasks_path)
        task_override = parse_task_list(args.tasks)
        try:
            selected_tasks = select_tasks(task_data, args.tag, task_override)
        except ValueError as exc:
            summary = {
                "ok": False,
                "skipped": False,
                "reason": "invalid_tasks",
                "error": str(exc),
                "tag": args.tag,
                "tasks": task_override
            }
            summary_path = os.path.join(os.getcwd(), "nightly_summary.json")
            with open(summary_path, "w", encoding="utf-8") as handle:
                json.dump(summary, handle, indent=2, sort_keys=True)
            sys.exit(1)

        if not task_override:
            selected_tasks = prioritize_fast_smoke(selected_tasks, task_data)

        if not selected_tasks and not args.gate:
            summary = {
                "ok": False,
                "skipped": False,
                "reason": "no_tasks",
                "tag": args.tag,
                "tasks": []
            }
            summary_path = os.path.join(os.getcwd(), "nightly_summary.json")
            with open(summary_path, "w", encoding="utf-8") as handle:
                json.dump(summary, handle, indent=2, sort_keys=True)
            sys.exit(1)

        artifact_dir = os.path.join(os.getcwd(), "nightly_artifacts")
        os.makedirs(artifact_dir, exist_ok=True)

        summary = {
            "ok": True,
            "skipped": False,
            "tag": args.tag,
            "tasks": selected_tasks,
            "runs": [],
            "gate_runs": []
        }
        write_nightly_lock(nightly_lock_path, args.tag, selected_tasks)
        overall_fail = False

        gate_tasks = ["S2.SPACE4X_CREW_SENSORS_CAUSALITY_MICRO", "S3.SPACE4X_CREW_ENTITY_TRANSFER_MICRO"]
        if args.gate:
            selected_tasks = [task_id for task_id in selected_tasks if task_id not in gate_tasks]
            summary["tasks"] = selected_tasks
            gate_fail = False
            for task_id in gate_tasks:
                previous_run = find_previous_run(state_dir, task_id, None)
                skip_gate = False
                if previous_run:
                    ended = previous_run.get("ended_utc")
                    if ended:
                        try:
                            from datetime import datetime, timezone, timedelta
                            if ended.endswith("Z"):
                                ended = ended[:-1] + "+00:00"
                            ended_dt = datetime.fromisoformat(ended)
                            if datetime.now(timezone.utc) - ended_dt < timedelta(hours=args.gate_hours):
                                if previous_run.get("exit_code") == 0:
                                    bank_status = previous_run.get("bank_status") or {}
                                    if bank_status.get("status") == "PASS":
                                        skip_gate = True
                        except Exception:
                            pass
                if skip_gate:
                    summary["gate_runs"].append({
                        "task_id": task_id,
                        "skipped": True,
                        "reason": "recent_green"
                    })
                    continue
                run_result, _ = run_headlessctl(["run_task", task_id])
                summary["gate_runs"].append({
                    "task_id": task_id,
                    "run_id": run_result.get("run_id"),
                    "ok": run_result.get("ok", False),
                    "exit_code": run_result.get("exit_code"),
                    "bank": (run_result.get("bank_status") or {}).get("status")
                })
                if not run_result.get("ok", False):
                    gate_fail = True
            if gate_fail:
                summary["ok"] = False
                summary_path = os.path.join(os.getcwd(), "nightly_summary.json")
                with open(summary_path, "w", encoding="utf-8") as handle:
                    json.dump(summary, handle, indent=2, sort_keys=True)
                sys.exit(1)

        for task_id in selected_tasks:
            run_result, _ = run_headlessctl(["run_task", task_id])
            run_id = run_result.get("run_id")
            seed_run_ids = run_result.get("seed_run_ids") or []
            evaluation_runs = seed_run_ids if seed_run_ids else [run_id]

            failures = []
            metrics_summary = run_result.get("metrics_summary", {})
            for eval_run_id in evaluation_runs:
                metrics_result, _ = run_headlessctl(["get_metrics", eval_run_id])
                failures.extend(evaluate_run(run_result, metrics_result))
                if not metrics_summary:
                    metrics_summary = metrics_result.get("metrics_summary", {})

            unique_run_ids = [run_id] + [rid for rid in seed_run_ids if rid and rid != run_id]
            bundle_paths = []
            for bundle_run_id in unique_run_ids:
                if not bundle_run_id:
                    continue
                bundle_result, _ = run_headlessctl(["bundle_artifacts", bundle_run_id])
                bundle_path = bundle_result.get("bundle_path")
                if bundle_path and os.path.exists(bundle_path):
                    target_path = os.path.join(artifact_dir, os.path.basename(bundle_path))
                    if target_path != bundle_path:
                        try:
                            with open(bundle_path, "rb") as src, open(target_path, "wb") as dst:
                                dst.write(src.read())
                        except Exception:
                            target_path = bundle_path
                    bundle_paths.append(target_path)

            previous_run = find_previous_run(state_dir, task_id, run_id)
            top_deltas = []
            previous_run_id = None
            if previous_run:
                previous_run_id = previous_run.get("run_id")
                top_deltas = compute_top_deltas(previous_run.get("metrics_summary", {}), metrics_summary)

            run_entry = {
                "task_id": task_id,
                "run_id": run_id,
                "seed_run_ids": seed_run_ids,
                "ok": run_result.get("ok", False),
                "error_code": run_result.get("error_code"),
                "error": run_result.get("error"),
                "failures": failures,
                "previous_run_id": previous_run_id,
                "top_metric_deltas": top_deltas,
                "bundle_paths": bundle_paths
            }
            summary["runs"].append(run_entry)

            if failures:
                overall_fail = True

        summary["ok"] = not overall_fail
        summary_path = os.path.join(os.getcwd(), "nightly_summary.json")
        with open(summary_path, "w", encoding="utf-8") as handle:
            json.dump(summary, handle, indent=2, sort_keys=True)

        if overall_fail:
            sys.exit(1)
    finally:
        if session_lock and session_lock.get("acquired"):
            run_headlessctl(["release_session_lock", "--run-id", session_lock.get("run_id") or ""])
        clear_nightly_lock(nightly_lock_path)


if __name__ == "__main__":
    main()
