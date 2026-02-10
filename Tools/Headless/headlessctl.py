#!/usr/bin/env python3
import datetime
import gzip
import json
import math
import os
import re
import selectors
import shutil
import socket
import subprocess
import sys
import tarfile
import time
import uuid

TOOL_VERSION = "0.1.0"
SCHEMA_VERSION = 1
DEFAULT_TIMEOUT_S = 600
DEFAULT_SESSION_LOCK_TTL_SEC = 90 * 60


def eprint(msg):
    sys.stderr.write(str(msg) + "\n")
    sys.stderr.flush()


def emit_result(result, exit_code):
    result.setdefault("tool_version", TOOL_VERSION)
    result.setdefault("schema_version", SCHEMA_VERSION)
    if "ok" not in result:
        result["ok"] = exit_code == 0
    if "error_code" not in result:
        result["error_code"] = "none" if result["ok"] else "error"
    if "error" not in result:
        result["error"] = None if result["ok"] else "error"
    if "run_id" not in result:
        result["run_id"] = None
    sys.stdout.write(json.dumps(result, sort_keys=True) + "\n")
    sys.stdout.flush()
    raise SystemExit(exit_code)


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def resolve_tool_root():
    env_root = os.environ.get("HEADLESS_REBUILD_TOOL_ROOT") or os.environ.get("HEADLESS_TOOL_ROOT")
    if env_root:
        return env_root
    script_dir = os.path.dirname(os.path.realpath(__file__))
    return os.path.abspath(os.path.join(script_dir, "..", ".."))


def is_tri_root(path):
    if not path:
        return False
    required = ("godgame", "space4x", "puredots", "Tools")
    return all(os.path.isdir(os.path.join(path, name)) for name in required)


def resolve_tri_root():
    env_root = os.environ.get("TRI_ROOT")
    if env_root and is_tri_root(env_root):
        return env_root
    env_root = os.environ.get("GITHUB_WORKSPACE")
    if env_root and is_tri_root(env_root):
        return env_root

    cwd = os.getcwd()
    if is_tri_root(cwd):
        return cwd
    parent = os.path.dirname(cwd)
    if is_tri_root(parent):
        return parent

    tool_root = resolve_tool_root()
    sibling = os.path.join(os.path.dirname(tool_root), "Tri")
    if is_tri_root(sibling):
        return sibling

    try:
        out = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], stderr=subprocess.DEVNULL)
        root = out.decode("utf-8", errors="replace").strip()
        if root and is_tri_root(root):
            return root
    except Exception:
        pass
    return os.getcwd()


def resolve_state_dir(tri_root):
    state_dir = os.environ.get("TRI_STATE_DIR")
    if state_dir:
        return state_dir
    home = os.environ.get("HOME")
    if home and os.access(home, os.W_OK):
        base = os.environ.get("XDG_STATE_HOME", os.path.join(home, ".local", "state"))
        return os.path.join(base, "tri-headless")
    return os.path.join(tri_root, ".tri", "state")


def get_build_lock_path(state_dir):
    return os.path.join(state_dir, "ops", "locks", "build.lock")


def get_build_state_path(state_dir):
    return os.path.join(state_dir, "ops", "locks", "build.state.json")


def get_session_lock_path(state_dir):
    return os.path.join(state_dir, "ops", "locks", "nightly_session.lock")


def get_legacy_session_lock_paths():
    paths = []
    queue_root = os.environ.get("POLISH_QUEUE_ROOT") or os.environ.get("POLISH_QUEUE")
    if queue_root:
        paths.append(os.path.join(queue_root, "reports", "nightly_session.lock"))
    if os.name == "nt":
        paths.append(r"C:\polish\queue\reports\nightly_session.lock")
    else:
        paths.append("/mnt/c/polish/queue/reports/nightly_session.lock")
    return [path for path in dict.fromkeys(paths) if path]


def check_build_lock(state_dir):
    if os.environ.get("HEADLESSCTL_IGNORE_LOCK") == "1":
        return None
    state_path = get_build_state_path(state_dir)
    if os.path.exists(state_path):
        try:
            data = load_json(state_path)
        except Exception:
            return state_path
        state = data.get("state")
        if state == "locked":
            return state_path
        if state == "unlocked":
            return None
        return state_path
    lock_path = get_build_lock_path(state_dir)
    if os.path.exists(lock_path):
        return lock_path
    return None


def load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def parse_utc(value):
    if not value:
        return None
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        return datetime.datetime.fromisoformat(value)
    except Exception:
        return None


def is_session_lock_stale(lock_path, data, ttl_sec):
    now = datetime.datetime.now(datetime.timezone.utc)
    started = parse_utc(data.get("started_utc") if data else None)
    if started:
        if (now - started).total_seconds() > ttl_sec:
            return True
    try:
        mtime = os.path.getmtime(lock_path)
        mtime_dt = datetime.datetime.fromtimestamp(mtime, datetime.timezone.utc)
        if (now - mtime_dt).total_seconds() > ttl_sec:
            return True
    except Exception:
        pass
    return False


def read_session_lock(lock_path):
    try:
        return load_json(lock_path)
    except Exception:
        return None


def reclaim_legacy_lock(path, ttl_sec):
    if not os.path.exists(path):
        return {"found": False}
    data = read_session_lock(path)
    if not is_session_lock_stale(path, data or {}, ttl_sec):
        return {"found": True, "stale": False, "path": path, "lock": data}
    stamp = utc_now().replace(":", "").replace("Z", "")
    stale_path = f"{path}.stale.{stamp}"
    try:
        os.replace(path, stale_path)
    except Exception:
        try:
            os.remove(path)
        except Exception:
            pass
    return {"found": True, "stale": True, "path": path, "stale_path": stale_path, "lock": data}


def check_legacy_locks(ttl_sec):
    for path in get_legacy_session_lock_paths():
        outcome = reclaim_legacy_lock(path, ttl_sec)
        if not outcome.get("found"):
            continue
        if outcome.get("stale"):
            return {"reclaimed": True, "path": path, "stale_path": outcome.get("stale_path")}
        return {"locked": True, "path": path, "lock": outcome.get("lock")}
    return {"reclaimed": False}


def claim_session_lock(state_dir, ttl_sec, purpose):
    lock_path = get_session_lock_path(state_dir)
    ensure_dir(os.path.dirname(lock_path))
    now = utc_now()
    host = socket.gethostname()
    run_id = str(uuid.uuid4())
    payload = {
        "run_id": run_id,
        "pid": os.getpid(),
        "host": host,
        "started_utc": now,
        "purpose": purpose
    }

    legacy = check_legacy_locks(ttl_sec)
    if legacy.get("locked"):
        return {
            "acquired": False,
            "lock_path": legacy.get("path"),
            "lock": legacy.get("lock"),
            "warning": "legacy_session_lock_present"
        }

    while True:
        if os.path.exists(lock_path):
            data = read_session_lock(lock_path)
            if is_session_lock_stale(lock_path, data or {}, ttl_sec):
                stale_suffix = now.replace(":", "").replace("Z", "")
                stale_path = f"{lock_path}.stale.{stale_suffix}"
                try:
                    os.replace(lock_path, stale_path)
                except Exception:
                    pass
                continue
            return {
                "acquired": False,
                "lock_path": lock_path,
                "lock": data
            }
        try:
            fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            continue
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
        return {
            "acquired": True,
            "lock_path": lock_path,
            "lock": payload
        }


def release_session_lock(state_dir, run_id=None):
    lock_path = get_session_lock_path(state_dir)
    if not os.path.exists(lock_path):
        return {"released": False, "lock_path": lock_path, "lock": None}
    data = read_session_lock(lock_path)
    if run_id and data and data.get("run_id") and data.get("run_id") != run_id:
        return {"released": False, "lock_path": lock_path, "lock": data}
    try:
        os.remove(lock_path)
        return {"released": True, "lock_path": lock_path, "lock": data}
    except Exception:
        return {"released": False, "lock_path": lock_path, "lock": data}


def show_session_lock(state_dir):
    lock_path = get_session_lock_path(state_dir)
    data = read_session_lock(lock_path) if os.path.exists(lock_path) else None
    return {"lock_path": lock_path, "lock": data}


def cleanup_session_locks(state_dir, ttl_sec):
    reclaimed = []
    legacy = check_legacy_locks(ttl_sec)
    if legacy.get("reclaimed"):
        reclaimed.append(legacy.get("path"))

    lock_path = get_session_lock_path(state_dir)
    if os.path.exists(lock_path):
        data = read_session_lock(lock_path)
        if is_session_lock_stale(lock_path, data or {}, ttl_sec):
            stamp = utc_now().replace(":", "").replace("Z", "")
            stale_path = f"{lock_path}.stale.{stamp}"
            try:
                os.replace(lock_path, stale_path)
                reclaimed.append(lock_path)
            except Exception:
                try:
                    os.remove(lock_path)
                    reclaimed.append(lock_path)
                except Exception:
                    pass
    return reclaimed


def ensure_dir(path):
    os.makedirs(path, exist_ok=True)


def ensure_executable(binary_path):
    try:
        if not os.access(binary_path, os.X_OK):
            mode = os.stat(binary_path).st_mode
            os.chmod(binary_path, mode | 0o111)
            eprint(f"HEADLESSCTL: chmod +x applied to {binary_path}")
    except Exception as exc:
        eprint(f"HEADLESSCTL: chmod +x failed for {binary_path}: {exc}")


def resolve_pointer_binary(state_dir, project):
    if not state_dir or project not in ("godgame", "space4x"):
        return None
    pointer_path = os.path.join(state_dir, "builds", f"current_{project}.json")
    if not os.path.isfile(pointer_path):
        return None
    try:
        data = load_json(pointer_path)
    except Exception as exc:
        eprint(f"HEADLESSCTL: failed to read build pointer for {project}: {pointer_path} ({exc})")
        return None
    executable = data.get("executable")
    if executable and os.path.exists(executable):
        eprint(f"HEADLESSCTL: using current build pointer for {project}: {executable}")
        return executable
    return None


def parse_session_lock_args(args):
    ttl = DEFAULT_SESSION_LOCK_TTL_SEC
    purpose = "nightly"
    run_id = None
    idx = 0
    while idx < len(args):
        token = args[idx]
        if token == "--ttl" and idx + 1 < len(args):
            try:
                ttl = int(args[idx + 1])
            except Exception:
                pass
            idx += 2
            continue
        if token == "--purpose" and idx + 1 < len(args):
            purpose = args[idx + 1]
            idx += 2
            continue
        if token == "--run-id" and idx + 1 < len(args):
            run_id = args[idx + 1]
            idx += 2
            continue
        idx += 1
    return ttl, purpose, run_id


def parse_cleanup_runs_args(args):
    days = None
    keep_per_task = None
    max_bytes = None
    idx = 0
    while idx < len(args):
        token = args[idx]
        if token == "--days" and idx + 1 < len(args):
            try:
                days = int(args[idx + 1])
            except Exception:
                pass
            idx += 2
            continue
        if token == "--keep-per-task" and idx + 1 < len(args):
            try:
                keep_per_task = int(args[idx + 1])
            except Exception:
                pass
            idx += 2
            continue
        if token == "--max-bytes" and idx + 1 < len(args):
            try:
                max_bytes = int(args[idx + 1])
            except Exception:
                pass
            idx += 2
            continue
        idx += 1
    return days, keep_per_task, max_bytes


def iter_runs(state_dir):
    runs_dir = os.path.join(state_dir, "runs")
    if not os.path.isdir(runs_dir):
        return []
    entries = []
    for name in os.listdir(runs_dir):
        run_path = os.path.join(runs_dir, name)
        if not os.path.isdir(run_path):
            continue
        result_path = os.path.join(run_path, "result.json")
        result = None
        ended_utc = None
        task_id = None
        if os.path.exists(result_path):
            try:
                result = load_json(result_path)
                ended_utc = result.get("ended_utc") or result.get("started_utc")
                task_id = result.get("task_id")
            except Exception:
                result = None
        entries.append({
            "run_id": name,
            "path": run_path,
            "result": result,
            "ended_utc": ended_utc,
            "task_id": task_id
        })
    return entries


def run_dir_size(path):
    total = 0
    for root, _, files in os.walk(path):
        for fname in files:
            try:
                total += os.path.getsize(os.path.join(root, fname))
            except Exception:
                pass
    return total


def cleanup_runs(state_dir, days, keep_per_task, max_bytes):
    entries = iter_runs(state_dir)
    now = datetime.datetime.now(datetime.timezone.utc)
    removed = []

    if days is not None:
        cutoff = now - datetime.timedelta(days=days)
        kept = []
        for entry in entries:
            ended = parse_utc(entry.get("ended_utc"))
            if ended and ended < cutoff:
                removed.append(entry["run_id"])
                shutil.rmtree(entry["path"], ignore_errors=True)
            else:
                kept.append(entry)
        entries = kept

    if keep_per_task is not None:
        by_task = {}
        for entry in entries:
            task_id = entry.get("task_id") or "unknown"
            by_task.setdefault(task_id, []).append(entry)
        kept = []
        for task_id, runs in by_task.items():
            runs.sort(key=lambda item: parse_utc(item.get("ended_utc")) or now, reverse=True)
            kept.extend(runs[:keep_per_task])
            for entry in runs[keep_per_task:]:
                removed.append(entry["run_id"])
                shutil.rmtree(entry["path"], ignore_errors=True)
        entries = kept

    if max_bytes is not None:
        entries.sort(key=lambda item: parse_utc(item.get("ended_utc")) or now, reverse=True)
        total_bytes = 0
        kept = []
        sizes = {}
        for entry in entries:
            size = run_dir_size(entry["path"])
            sizes[entry["run_id"]] = size
            total_bytes += size
            kept.append(entry)
        if total_bytes > max_bytes:
            for entry in reversed(kept):
                if total_bytes <= max_bytes:
                    break
                run_id = entry["run_id"]
                size = sizes.get(run_id, 0)
                removed.append(run_id)
                total_bytes -= size
                shutil.rmtree(entry["path"], ignore_errors=True)

    return removed


def find_binary(tri_root, state_dir, project):
    pointer_binary = resolve_pointer_binary(state_dir, project)
    if pointer_binary:
        return pointer_binary
    if project == "godgame":
        return os.path.join(tri_root, "Tools", "builds", "godgame", "Linux_latest", "Godgame_Headless.x86_64")
    if project == "space4x":
        return os.path.join(tri_root, "Tools", "builds", "space4x", "Linux_latest", "Space4X_Headless.x86_64")
    return None


def parse_args(argv):
    if not argv:
        return None, []
    return argv[0], argv[1:]


def parse_run_task_args(args):
    if not args:
        return None, None, None, None, "missing_task_id"
    task_id = args[0]
    seed = None
    seeds = None
    pack = None
    idx = 1
    while idx < len(args):
        token = args[idx]
        if token == "--seed" and idx + 1 < len(args):
            raw_seed = args[idx + 1]
            if not str(raw_seed).isdigit():
                return task_id, None, None, None, "invalid_seed"
            seed = int(raw_seed)
            idx += 2
            continue
        if token == "--seeds" and idx + 1 < len(args):
            seeds, err = parse_seed_list(args[idx + 1])
            if err:
                return task_id, None, None, None, err
            idx += 2
            continue
        if token == "--pack" and idx + 1 < len(args):
            pack = args[idx + 1]
            idx += 2
            continue
        return task_id, seed, seeds, pack, "invalid_arg"
    if seed is not None and seeds is not None:
        return task_id, seed, seeds, pack, "conflicting_seed_args"
    return task_id, seed, seeds, pack, None


def parse_seed_list(raw_value):
    raw = str(raw_value) if raw_value is not None else ""
    parts = [part.strip() for part in raw.split(",") if part.strip()]
    if not parts:
        return None, "invalid_seeds"
    seeds = []
    for part in parts:
        if not part.isdigit():
            return None, "invalid_seeds"
        seeds.append(int(part))
    return seeds, None


def parse_simple_args(args, expected):
    if len(args) < expected:
        return None, "missing_args"
    return args, None


def resolve_seed_list(task, seed, seeds):
    if seeds is not None:
        return list(seeds)
    if seed is not None:
        return [seed]
    default_seeds = task.get("default_seeds") or []
    if default_seeds:
        return [int(default_seeds[0])]
    return []


def check_seed_policy(task, seeds):
    policy = task.get("seed_policy")
    if policy != "ai_polish":
        return True, None, None
    if len(seeds) < 3:
        return False, "seed_policy_violation", "ai_polish policy requires at least 3 runs"
    counts = {}
    for seed in seeds:
        counts[seed] = counts.get(seed, 0) + 1
    if len(counts) < 2 or max(counts.values()) < 2:
        return False, "seed_policy_violation", "ai_polish policy requires two runs on the same seed and one run on a different seed"
    return True, None, None


def compute_percentile(values, percentile):
    if not values:
        return None
    sorted_values = sorted(values)
    if len(sorted_values) == 1:
        return sorted_values[0]
    if percentile <= 0:
        return sorted_values[0]
    if percentile >= 100:
        return sorted_values[-1]
    rank = (len(sorted_values) - 1) * (percentile / 100.0)
    lower = int(math.floor(rank))
    upper = int(math.ceil(rank))
    if lower == upper:
        return sorted_values[lower]
    weight = rank - lower
    return sorted_values[lower] * (1.0 - weight) + sorted_values[upper] * weight


def compute_seed_stats(values):
    if not values:
        return None
    count = len(values)
    mean = sum(values) / count
    variance = sum((value - mean) ** 2 for value in values) / count
    stdev = math.sqrt(variance) if variance >= 0.0 else None
    return {
        "count": count,
        "min": min(values),
        "max": max(values),
        "mean": mean,
        "stdev": stdev,
        "p95": compute_percentile(values, 95)
    }


def collect_seed_metrics(seed_results, metric_keys, variance_band):
    values_by_key = {key: [] for key in metric_keys}
    seed_runs = []

    for run in seed_results:
        summary = run.get("metrics_summary", {})
        selected = {}
        for key in metric_keys:
            value = summary.get(key)
            if isinstance(value, (int, float)):
                selected[key] = value
                values_by_key[key].append(float(value))
        seed_runs.append({
            "run_id": run.get("run_id"),
            "seed_requested": run.get("seed_requested"),
            "seed_used": run.get("seed_used"),
            "seed_effective": run.get("seed_effective"),
            "ok": run.get("ok"),
            "error_code": run.get("error_code"),
            "error": run.get("error"),
            "metrics_summary": selected,
            "artifacts": run.get("artifacts", {})
        })

    aggregate_summary = {}
    aggregate_stats = {}
    variance_grades = {}
    variance_pass = True
    variance_failed_count = 0

    for key, values in values_by_key.items():
        stats = compute_seed_stats(values)
        if stats:
            aggregate_summary[key] = stats.get("mean")
            aggregate_stats[key] = stats
        band = variance_band.get(key)
        if isinstance(band, (int, float)) and stats:
            spread = stats["max"] - stats["min"]
            within = spread <= band
            variance_grades[key] = {
                "band": band,
                "spread": spread,
                "count": stats["count"],
                "pass": within
            }
            if not within:
                variance_pass = False
                variance_failed_count += 1

    return seed_runs, aggregate_summary, aggregate_stats, variance_grades, variance_pass, variance_failed_count


def resolve_scenario_path(tri_root, scenario_path):
    if os.path.isabs(scenario_path):
        return scenario_path
    return os.path.join(tri_root, scenario_path)

def copy_scenario_templates(src_path, run_dir):
    if not src_path:
        return
    scenario_dir = os.path.dirname(src_path)
    if not scenario_dir:
        return
    templates_dir = os.path.join(scenario_dir, "Templates")
    if not os.path.isdir(templates_dir):
        return
    dest_dir = os.path.join(run_dir, "Templates")
    os.makedirs(dest_dir, exist_ok=True)
    for name in os.listdir(templates_dir):
        if not name.lower().endswith(".json"):
            continue
        src_file = os.path.join(templates_dir, name)
        dest_file = os.path.join(dest_dir, name)
        try:
            shutil.copy2(src_file, dest_file)
        except Exception as exc:
            eprint(f"HEADLESSCTL: failed to copy template {src_file} -> {dest_file}: {exc}")


def override_seed_if_supported(src_path, run_dir, seed_value, runner_kind):
    if seed_value is None:
        return src_path, None
    if not src_path:
        return src_path, None
    if runner_kind not in ("scenario_runner", "space4x_loader"):
        return src_path, None
    try:
        with open(src_path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception:
        return src_path, None
    data["seed"] = seed_value
    dest_path = os.path.join(run_dir, "scenario_seed_override.json")
    with open(dest_path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
    copy_scenario_templates(src_path, run_dir)
    return dest_path, seed_value


def parse_bank_line(line):
    if not line.startswith("BANK:"):
        return None
    payload = line[len("BANK:"):].strip()
    parts = payload.split(":", 2)
    if len(parts) < 2:
        return None
    test_id = parts[0]
    status = parts[1].split()[0] if parts[1] else ""
    rest = parts[2] if len(parts) > 2 else ""
    reason = None
    match = re.search(r"reason=([^\s]+)", rest)
    if match:
        reason = match.group(1)
    return {"id": test_id, "status": status, "reason": reason, "raw": line.strip()}


def scan_telemetry(telemetry_path, run_dir, pack_caps):
    metrics_path = os.path.join(run_dir, "metrics.jsonl")
    events_path = os.path.join(run_dir, "events.jsonl")
    metrics_handle = open(metrics_path, "w", encoding="utf-8")
    events_handle = open(events_path, "w", encoding="utf-8")

    stats = {}
    first_tick = None
    last_tick = None
    monotonic_ok = True
    parse_errors = 0
    nan_inf_found = 0
    negative_counts = 0
    negative_resources = 0
    seed_used = None
    scenario_id = None

    def update_stats(key, value, tick):
        entry = stats.get(key)
        if entry is None:
            entry = {"count": 0, "sum": 0.0, "sum_sq": 0.0, "min": None, "max": None, "last": None, "last_tick": None}
            stats[key] = entry
        entry["count"] += 1
        entry["sum"] += float(value)
        entry["sum_sq"] += float(value) * float(value)
        entry["min"] = value if entry["min"] is None else min(entry["min"], value)
        entry["max"] = value if entry["max"] is None else max(entry["max"], value)
        entry["last"] = value
        entry["last_tick"] = tick

    def looks_like_resource_key(key):
        low = key.lower()
        if "delta" in low or "change" in low or "diff" in low:
            return False
        tokens = ["resource", "inventory", "storehouse", "buffer", "stock", "pile"]
        return any(token in low for token in tokens)

    def contains_non_finite(value):
        if isinstance(value, float):
            return not math.isfinite(value)
        if isinstance(value, (int, str, type(None))):
            return False
        if isinstance(value, dict):
            return any(contains_non_finite(v) for v in value.values())
        if isinstance(value, list):
            return any(contains_non_finite(v) for v in value)
        return False

    with open(telemetry_path, "r", encoding="utf-8-sig", errors="replace") as handle:
        for raw in handle:
            raw_line = raw.rstrip("\n")
            if not raw_line:
                continue
            try:
                record = json.loads(raw_line)
            except Exception:
                parse_errors += 1
                continue
            if contains_non_finite(record):
                nan_inf_found += 1
            tick = record.get("tick")
            if isinstance(tick, int):
                if first_tick is None:
                    first_tick = tick
                if last_tick is not None and tick < last_tick:
                    monotonic_ok = False
                last_tick = tick
            record_type = record.get("type")
            if seed_used is None and isinstance(record.get("seed"), int):
                seed_used = record.get("seed")
            if scenario_id is None and record.get("scenario"):
                scenario_id = record.get("scenario")
            if record_type == "metric":
                key = record.get("key")
                value = record.get("value")
                unit = record.get("unit")
                loop = record.get("loop")
                metrics_handle.write(json.dumps({
                    "tick": tick,
                    "key": key,
                    "value": value,
                    "unit": unit,
                    "loop": loop
                }, sort_keys=True) + "\n")
                if isinstance(value, (int, float)):
                    update_stats(key, value, tick)
                    if unit == "count" and value < 0:
                        negative_counts += 1
                    if key and looks_like_resource_key(key) and value < 0:
                        negative_resources += 1
            else:
                events_handle.write(json.dumps(record, sort_keys=True) + "\n")

    metrics_handle.close()
    events_handle.close()

    metrics_summary = {}
    metrics_stats = {}
    for key, entry in stats.items():
        count = entry["count"]
        mean = entry["sum"] / count if count > 0 else None
        variance = None
        stdev = None
        if count > 0 and mean is not None:
            variance = max(0.0, (entry["sum_sq"] / count) - (mean * mean))
            stdev = math.sqrt(variance) if variance >= 0.0 else None
        metrics_stats[key] = {
            "count": count,
            "min": entry["min"],
            "max": entry["max"],
            "mean": mean,
            "stdev": stdev,
            "last": entry["last"],
            "last_tick": entry["last_tick"]
        }
        metrics_summary[key] = entry["last"]

    size_bytes = os.path.getsize(telemetry_path) if os.path.exists(telemetry_path) else 0
    cap_bytes = pack_caps.get("max_bytes") if pack_caps else None
    under_cap = True
    if isinstance(cap_bytes, int) and cap_bytes > 0:
        under_cap = size_bytes <= cap_bytes

    telemetry_truncated = 0 if under_cap else 1
    last_tick_value = last_tick if isinstance(last_tick, int) else None
    metrics_summary["telemetry.bytes_written"] = size_bytes
    metrics_summary["telemetry.truncated"] = telemetry_truncated
    metrics_stats["telemetry.bytes_written"] = {
        "count": 1,
        "min": size_bytes,
        "max": size_bytes,
        "mean": float(size_bytes),
        "stdev": 0.0,
        "last": size_bytes,
        "last_tick": last_tick_value
    }
    metrics_stats["telemetry.truncated"] = {
        "count": 1,
        "min": telemetry_truncated,
        "max": telemetry_truncated,
        "mean": float(telemetry_truncated),
        "stdev": 0.0,
        "last": telemetry_truncated,
        "last_tick": last_tick_value
    }

    invariants = [
        {"name": "telemetry.parse_errors", "ok": parse_errors == 0, "value": parse_errors},
        {"name": "telemetry.monotonic_tick", "ok": monotonic_ok, "first_tick": first_tick, "last_tick": last_tick},
        {"name": "telemetry.no_nan_inf", "ok": nan_inf_found == 0, "value": nan_inf_found},
        {"name": "telemetry.no_negative_counts", "ok": negative_counts == 0, "value": negative_counts},
        {"name": "telemetry.no_negative_resources", "ok": negative_resources == 0, "value": negative_resources},
        {"name": "telemetry.output_under_cap", "ok": under_cap, "size_bytes": size_bytes, "cap_bytes": cap_bytes}
    ]

    invariants_path = os.path.join(run_dir, "invariants.jsonl")
    with open(invariants_path, "w", encoding="utf-8") as handle:
        for inv in invariants:
            handle.write(json.dumps(inv, sort_keys=True) + "\n")

    return {
        "metrics_path": metrics_path,
        "events_path": events_path,
        "invariants_path": invariants_path,
        "metrics_summary": metrics_summary,
        "metrics_stats": metrics_stats,
        "invariants": invariants,
        "first_tick": first_tick,
        "last_tick": last_tick,
        "telemetry_size_bytes": size_bytes,
        "seed_used": seed_used,
        "scenario_id": scenario_id
    }


def maybe_compress(path, compress):
    if not compress:
        return path
    gz_path = path + ".gz"
    with open(path, "rb") as src, gzip.open(gz_path, "wb") as dst:
        shutil.copyfileobj(src, dst)
    os.remove(path)
    return gz_path


def build_error_result(error_code, error, run_id=None):
    return {
        "ok": False,
        "error_code": error_code,
        "error": error,
        "run_id": run_id
    }


def run_task_internal(task_id, seed, pack_name):
    tool_root = resolve_tool_root()
    tri_root = resolve_tri_root()
    if not is_tri_root(tri_root):
        return build_error_result("tri_root_invalid", f"TRI_ROOT invalid: {tri_root}"), 2
    state_dir = resolve_state_dir(tri_root)
    tasks_path = os.path.join(tool_root, "Tools", "Headless", "headless_tasks.json")
    packs_path = os.path.join(tool_root, "Tools", "Headless", "headless_packs.json")

    if not os.path.exists(tasks_path):
        return build_error_result("tasks_missing", f"tasks registry not found: {tasks_path}"), 2

    if not os.path.exists(packs_path):
        return build_error_result("packs_missing", f"packs registry not found: {packs_path}"), 2

    tasks = load_json(tasks_path).get("tasks", {})
    packs = load_json(packs_path).get("packs", {})

    if task_id not in tasks:
        return build_error_result("task_not_found", f"task not found: {task_id}"), 2

    task = tasks[task_id]
    if pack_name is None:
        pack_name = task.get("default_pack") or "nightly-default"

    if pack_name not in packs:
        return build_error_result("pack_not_found", f"pack not found: {pack_name}"), 2

    pack = packs[pack_name]

    project = task.get("project")
    runner = task.get("runner")
    scenario_path = task.get("scenario_path")
    required_bank = task.get("required_bank")
    allow_exit_codes = task.get("allow_exit_codes")
    if allow_exit_codes is None:
        allow_exit_codes = [0]
    elif isinstance(allow_exit_codes, (int, float)):
        allow_exit_codes = [int(allow_exit_codes)]
    else:
        allow_exit_codes = [int(code) for code in allow_exit_codes]
    if 0 not in allow_exit_codes:
        allow_exit_codes.append(0)
    timeout_s = task.get("timeout_s")
    if not isinstance(timeout_s, (int, float)) or timeout_s <= 0:
        timeout_s = DEFAULT_TIMEOUT_S
    timeout_s = int(timeout_s)

    binary = find_binary(tri_root, state_dir, project)
    if not binary or not os.path.exists(binary):
        return build_error_result("binary_missing", f"binary not found for project {project}: {binary}"), 2
    ensure_executable(binary)

    run_id = uuid.uuid4().hex
    runs_dir = os.path.join(state_dir, "runs")
    run_dir = os.path.join(runs_dir, run_id)
    ensure_dir(run_dir)

    scenario_abs = resolve_scenario_path(tri_root, scenario_path) if scenario_path else None
    if scenario_abs and not os.path.exists(scenario_abs):
        return build_error_result("scenario_missing", f"scenario not found: {scenario_abs}", run_id), 2

    seed_requested = seed if seed is not None else None
    if seed_requested is None:
        default_seeds = task.get("default_seeds") or []
        if default_seeds:
            seed_requested = int(default_seeds[0])
    scenario_used, seed_effective = override_seed_if_supported(scenario_abs, run_dir, seed_requested, runner)

    telemetry_path = os.path.join(run_dir, "telemetry.ndjson")
    stdout_path = os.path.join(run_dir, "stdout.log")

    env = os.environ.copy()
    for key, value in pack.get("env", {}).items():
        env[str(key)] = str(value)
    for key, value in task.get("env", {}).items():
        env[str(key)] = str(value)
    env["PUREDOTS_TELEMETRY_PATH"] = telemetry_path
    if project == "space4x":
        if scenario_abs:
            env["SPACE4X_SCENARIO_SOURCE_PATH"] = scenario_abs
            env["SPACE4X_SCENARIO_PATH"] = scenario_abs
        elif scenario_used:
            env["SPACE4X_SCENARIO_PATH"] = scenario_used

    cmd = [binary, "-batchmode", "-nographics", "-logFile", "-", "--scenario", scenario_used]

    started_utc = utc_now()
    eprint(f"HEADLESSCTL: run_task start task={task_id} run_id={run_id} pack={pack_name}")

    bank_results = []
    telemetry_out = None
    exit_code = None
    timed_out = False

    with open(stdout_path, "w", encoding="utf-8") as log_handle:
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, text=True, encoding="utf-8", errors="replace")
            selector = selectors.DefaultSelector()
            selector.register(proc.stdout, selectors.EVENT_READ)
            start_time = time.monotonic()

            def handle_line(line):
                nonlocal telemetry_out
                log_handle.write(line)
                log_handle.flush()
                stripped = line.strip()
                bank = parse_bank_line(stripped)
                if bank:
                    bank_results.append(bank)
                if stripped.startswith("TELEMETRY_OUT:"):
                    telemetry_out = stripped.split(":", 1)[1].strip()

            while True:
                if timeout_s and time.monotonic() - start_time > timeout_s:
                    timed_out = True
                    log_handle.write(f"HEADLESSCTL: timeout after {timeout_s}s\n")
                    log_handle.flush()
                    proc.kill()
                    break

                if proc.poll() is not None:
                    while True:
                        line = proc.stdout.readline()
                        if not line:
                            break
                        handle_line(line)
                    break

                events = selector.select(timeout=0.2)
                if not events:
                    continue
                for key, _ in events:
                    line = key.fileobj.readline()
                    if not line:
                        continue
                    handle_line(line)
            try:
                exit_code = proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                exit_code = 124
        except Exception as exc:
            exit_code = 1
            log_handle.write(f"HEADLESSCTL: run failed {exc}\n")

    eprint(f"HEADLESSCTL: run_task finished run_id={run_id} exit_code={exit_code}")

    if telemetry_out and telemetry_out != telemetry_path:
        if os.path.exists(telemetry_out) and not os.path.exists(telemetry_path):
            shutil.copy2(telemetry_out, telemetry_path)

    telemetry_ok = os.path.exists(telemetry_path)
    telemetry_scan = None
    if telemetry_ok:
        telemetry_scan = scan_telemetry(telemetry_path, run_dir, pack.get("caps"))

    compress_jsonl = bool(pack.get("compress_jsonl"))
    metrics_path = telemetry_scan["metrics_path"] if telemetry_scan else None
    events_path = telemetry_scan["events_path"] if telemetry_scan else None
    invariants_path = telemetry_scan["invariants_path"] if telemetry_scan else None

    if metrics_path and os.path.exists(metrics_path):
        metrics_path = maybe_compress(metrics_path, compress_jsonl)
    if events_path and os.path.exists(events_path):
        events_path = maybe_compress(events_path, compress_jsonl)
    if invariants_path and os.path.exists(invariants_path):
        invariants_path = maybe_compress(invariants_path, compress_jsonl)

    metrics_summary = telemetry_scan["metrics_summary"] if telemetry_scan else {}
    metrics_stats = telemetry_scan["metrics_stats"] if telemetry_scan else {}
    invariants = telemetry_scan["invariants"] if telemetry_scan else []
    seed_used = telemetry_scan["seed_used"] if telemetry_scan else None
    scenario_id = telemetry_scan["scenario_id"] if telemetry_scan else None

    invariant_fail = any(inv.get("ok") is False for inv in invariants)
    bank_required = bool(required_bank)
    bank_strict = task.get("bank_strict", True)
    bank_status = None
    if bank_required:
        for bank in bank_results:
            if bank.get("id") == required_bank:
                bank_status = bank
                break

    bank_ok = True
    if bank_required:
        bank_ok = bank_status is not None and bank_status.get("status") == "PASS"

    ok = True
    error_code = "none"
    error = None
    warnings = []

    if timed_out:
        ok = False
        error_code = "timeout"
        error = f"timeout_s={timeout_s}"
    elif exit_code is not None and exit_code not in allow_exit_codes:
        ok = False
        error_code = "run_failed"
        error = f"exit_code={exit_code}"
    if not telemetry_ok:
        ok = False
        error_code = "telemetry_missing"
        error = "telemetry output missing"
    if bank_required and not bank_ok:
        if bank_strict:
            ok = False
            error_code = "bank_failed"
            error = f"required bank {required_bank} not PASS"
        else:
            warnings.append(f"required bank {required_bank} not PASS")
    if invariant_fail:
        ok = False
        error_code = "invariant_failed"
        error = "invariant check failed"

    artifacts_all = {
        "stdout": stdout_path,
        "telemetry": telemetry_path if telemetry_ok else None,
        "metrics": metrics_path,
        "events": events_path,
        "invariants": invariants_path
    }
    include = pack.get("artifacts_include", list(artifacts_all.keys()))
    exclude = set(pack.get("artifacts_exclude", []))
    artifacts = {}
    for name in include:
        if name in exclude:
            continue
        path = artifacts_all.get(name)
        if path:
            artifacts[name] = path

    result = {
        "ok": ok,
        "error_code": error_code,
        "error": error,
        "run_id": run_id,
        "task_id": task_id,
        "project": project,
        "runner": runner,
        "scenario_path": scenario_path,
        "scenario_used": scenario_used,
        "scenario_id": scenario_id,
        "tick_budget": task.get("tick_budget"),
        "seed_requested": seed_requested,
        "seed_used": seed_used,
        "seed_effective": seed_effective,
        "pack": pack_name,
        "started_utc": started_utc,
        "ended_utc": utc_now(),
        "exit_code": exit_code,
        "timeout_s": timeout_s,
        "timed_out": timed_out,
        "bank_required": required_bank,
        "bank_results": bank_results,
        "bank_status": bank_status,
        "warnings": warnings,
        "telemetry_path": telemetry_path if telemetry_ok else None,
        "metrics_summary": metrics_summary,
        "metrics_stats": metrics_stats,
        "invariants": invariants,
        "artifacts": artifacts
    }

    result_path = os.path.join(run_dir, "result.json")
    with open(result_path, "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)

    eprint(f"HEADLESSCTL: run_task summary run_id={run_id} ok={ok} bank={bank_status.get('status') if bank_status else 'none'}")

    return result, 0 if ok else 3


def run_task_multi(task_id, seeds, pack_name, task):
    tri_root = resolve_tri_root()
    state_dir = resolve_state_dir(tri_root)
    run_id = uuid.uuid4().hex
    run_dir = os.path.join(state_dir, "runs", run_id)
    ensure_dir(run_dir)

    pack_used = pack_name or task.get("default_pack") or "nightly-default"
    metric_keys = task.get("metric_keys") or []
    variance_band = task.get("variance_band") or {}

    started_utc = utc_now()
    seed_results = []
    for seed in seeds:
        result, exit_code = run_task_internal(task_id, seed, pack_name)
        seed_results.append(result)
        if exit_code == 2:
            return result, 2

    seed_runs, aggregate_summary, aggregate_stats, variance_grades, variance_pass, variance_failed_count = collect_seed_metrics(
        seed_results,
        metric_keys,
        variance_band
    )

    aggregate_summary["eval.variance_failed_count"] = variance_failed_count

    seed_ok = all(run.get("ok") for run in seed_results)
    ok = seed_ok and variance_pass
    error_code = "none"
    error = None
    if not seed_ok:
        error_code = "seed_run_failed"
        error = "one or more seed runs failed"
    elif not variance_pass:
        error_code = "variance_failed"
        error = "variance band exceeded"

    scenario_used = seed_results[0].get("scenario_used") if seed_results else None
    scenario_id = seed_results[0].get("scenario_id") if seed_results else None

    result = {
        "ok": ok,
        "error_code": error_code,
        "error": error,
        "run_id": run_id,
        "task_id": task_id,
        "project": task.get("project"),
        "runner": task.get("runner"),
        "scenario_path": task.get("scenario_path"),
        "scenario_used": scenario_used,
        "scenario_id": scenario_id,
        "tick_budget": task.get("tick_budget"),
        "seeds_requested": seeds,
        "pack": pack_used,
        "started_utc": started_utc,
        "ended_utc": utc_now(),
        "exit_code": 0 if ok else 3,
        "metrics_summary": aggregate_summary,
        "metrics_stats": aggregate_stats,
        "variance_grades": variance_grades,
        "variance_pass": variance_pass,
        "eval_metrics": {
            "variance_failed_count": variance_failed_count
        },
        "seed_runs": seed_runs,
        "seed_run_ids": [run.get("run_id") for run in seed_runs],
        "artifacts": {}
    }

    result_path = os.path.join(run_dir, "result.json")
    with open(result_path, "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)

    eprint(f"HEADLESSCTL: run_task summary run_id={run_id} ok={ok} seeds={','.join(str(seed) for seed in seeds)}")

    return result, 0 if ok else 3


def run_task(task_id, seed, seeds, pack_name):
    tool_root = resolve_tool_root()
    tri_root = resolve_tri_root()
    state_dir = resolve_state_dir(tri_root)
    lock_path = check_build_lock(state_dir)
    if lock_path:
        result = build_error_result("build_locked", f"build.lock present: {lock_path}")
        result["lock_path"] = lock_path
        emit_result(result, 2)
    tasks_path = os.path.join(tool_root, "Tools", "Headless", "headless_tasks.json")
    if not os.path.exists(tasks_path):
        emit_result(build_error_result("tasks_missing", f"tasks registry not found: {tasks_path}"), 2)

    tasks = load_json(tasks_path).get("tasks", {})
    if task_id not in tasks:
        emit_result(build_error_result("task_not_found", f"task not found: {task_id}"), 2)
    task = tasks[task_id]
    seed_policy = task.get("seed_policy")
    default_seeds = task.get("default_seeds") or []
    auto_multi = False
    if seeds is None and seed is None and seed_policy == "ai_polish" and len(default_seeds) >= 3:
        seed_list = [int(value) for value in default_seeds]
        auto_multi = True
    else:
        seed_list = resolve_seed_list(task, seed, seeds)

    policy_ok, policy_code, policy_error = check_seed_policy(task, seed_list)
    if not policy_ok:
        emit_result(build_error_result(policy_code, policy_error), 2)

    if (seeds is not None or auto_multi) and len(seed_list) > 1:
        result, exit_code = run_task_multi(task_id, seed_list, pack_name, task)
        emit_result(result, exit_code)

    seed_value = seed_list[0] if seed_list else seed
    result, exit_code = run_task_internal(task_id, seed_value, pack_name)
    emit_result(result, exit_code)


def get_metrics(run_id):
    tri_root = resolve_tri_root()
    state_dir = resolve_state_dir(tri_root)
    run_dir = os.path.join(state_dir, "runs", run_id)
    result_path = os.path.join(run_dir, "result.json")
    if not os.path.exists(result_path):
        emit_result({
            "ok": False,
            "error_code": "run_not_found",
            "error": f"run not found: {run_id}",
            "run_id": run_id
        }, 2)
    result = load_json(result_path)
    out = {
        "ok": True,
        "error_code": "none",
        "error": None,
        "run_id": run_id,
        "task_id": result.get("task_id"),
        "metrics_summary": result.get("metrics_summary", {}),
        "metrics_stats": result.get("metrics_stats", {}),
        "invariants": result.get("invariants", []),
        "artifacts": result.get("artifacts", {})
    }
    if "seed_runs" in result:
        out["seed_runs"] = result.get("seed_runs", [])
        out["seed_run_ids"] = result.get("seed_run_ids", [])
        out["variance_grades"] = result.get("variance_grades", {})
        out["variance_pass"] = result.get("variance_pass", True)
    emit_result(out, 0)


def diff_metrics_internal(run_id_a, run_id_b):
    tool_root = resolve_tool_root()
    tri_root = resolve_tri_root()
    state_dir = resolve_state_dir(tri_root)
    tasks_path = os.path.join(tool_root, "Tools", "Headless", "headless_tasks.json")
    tasks = load_json(tasks_path).get("tasks", {}) if os.path.exists(tasks_path) else {}

    def load_run(run_id):
        run_dir = os.path.join(state_dir, "runs", run_id)
        result_path = os.path.join(run_dir, "result.json")
        if not os.path.exists(result_path):
            return None
        return load_json(result_path)

    run_a = load_run(run_id_a)
    run_b = load_run(run_id_b)
    if run_a is None or run_b is None:
        return build_error_result("run_not_found", "one or more runs not found", run_id_a), 2

    task_id = run_b.get("task_id") or run_a.get("task_id")
    task = tasks.get(task_id, {})
    metric_keys = task.get("metric_keys", [])
    thresholds = task.get("thresholds", {})
    variance_band = task.get("variance_band", {})

    summary_a = run_a.get("metrics_summary", {})
    summary_b = run_b.get("metrics_summary", {})
    stats_a = run_a.get("metrics_stats", {})
    stats_b = run_b.get("metrics_stats", {})

    diffs = {}
    grades = {}
    for key in metric_keys:
        value_a = summary_a.get(key)
        value_b = summary_b.get(key)
        delta = None
        if isinstance(value_a, (int, float)) and isinstance(value_b, (int, float)):
            delta = value_b - value_a
        stat_a = stats_a.get(key, {})
        stat_b = stats_b.get(key, {})
        mean_a = stat_a.get("mean")
        mean_b = stat_b.get("mean")
        stdev_a = stat_a.get("stdev")
        stdev_b = stat_b.get("stdev")
        delta_mean = None
        if isinstance(mean_a, (int, float)) and isinstance(mean_b, (int, float)):
            delta_mean = mean_b - mean_a
        diffs[key] = {
            "a": value_a,
            "b": value_b,
            "delta": delta,
            "mean_a": mean_a,
            "mean_b": mean_b,
            "delta_mean": delta_mean,
            "stdev_a": stdev_a,
            "stdev_b": stdev_b
        }
        threshold = thresholds.get(key, {})
        min_val = threshold.get("min") if isinstance(threshold, dict) else None
        max_val = threshold.get("max") if isinstance(threshold, dict) else None
        pass_threshold = True
        if min_val is not None and isinstance(value_b, (int, float)):
            pass_threshold = pass_threshold and value_b >= min_val
        if max_val is not None and isinstance(value_b, (int, float)):
            pass_threshold = pass_threshold and value_b <= max_val
        band = variance_band.get(key)
        within_band = True
        if band is not None and delta is not None:
            within_band = abs(delta) <= band
        grades[key] = {
            "pass_threshold": pass_threshold,
            "within_band": within_band,
            "threshold": threshold,
            "variance_band": band
        }

    all_pass = all(item.get("pass_threshold") and item.get("within_band") for item in grades.values()) if grades else True

    out = {
        "ok": True,
        "error_code": "none",
        "error": None,
        "run_id": run_id_a,
        "run_id_b": run_id_b,
        "task_id": task_id,
        "diffs": diffs,
        "grades": grades,
        "pass": all_pass
    }

    return out, 0


def diff_metrics(run_id_a, run_id_b):
    result, exit_code = diff_metrics_internal(run_id_a, run_id_b)
    emit_result(result, exit_code)


def contract_check():
    tool_root = resolve_tool_root()
    tasks_path = os.path.join(tool_root, "Tools", "Headless", "headless_tasks.json")
    packs_path = os.path.join(tool_root, "Tools", "Headless", "headless_packs.json")

    if not os.path.exists(tasks_path):
        emit_result(build_error_result("tasks_missing", f"tasks registry not found: {tasks_path}"), 2)
    if not os.path.exists(packs_path):
        emit_result(build_error_result("packs_missing", f"packs registry not found: {packs_path}"), 2)

    tasks_doc = load_json(tasks_path)
    packs_doc = load_json(packs_path)
    tasks = tasks_doc.get("tasks", {})
    packs = packs_doc.get("packs", {})

    errors = []
    warnings = []

    if not isinstance(tasks, dict) or not tasks:
        errors.append({"id": "tasks_empty", "message": "tasks registry is empty"})
    if not isinstance(packs, dict) or not packs:
        errors.append({"id": "packs_empty", "message": "packs registry is empty"})

    allowed_projects = {"godgame", "space4x", "puredots"}
    allowed_runners = {"scenario_runner", "godgame_loader", "space4x_loader"}

    for pack_name, pack in packs.items():
        if not isinstance(pack, dict):
            errors.append({"id": "pack_invalid", "pack": pack_name, "message": "pack must be an object"})
            continue
        env = pack.get("env")
        if not isinstance(env, dict):
            errors.append({"id": "pack_env_missing", "pack": pack_name, "message": "pack.env must be an object"})
        caps = pack.get("caps")
        if caps is None:
            warnings.append({"id": "pack_caps_missing", "pack": pack_name, "message": "pack.caps missing"})
        elif not isinstance(caps, dict):
            errors.append({"id": "pack_caps_invalid", "pack": pack_name, "message": "pack.caps must be an object"})

    for task_id, task in tasks.items():
        if not isinstance(task, dict):
            errors.append({"id": "task_invalid", "task_id": task_id, "message": "task must be an object"})
            continue

        project = task.get("project")
        runner = task.get("runner")
        scenario_path = task.get("scenario_path")
        tick_budget = task.get("tick_budget")
        default_pack = task.get("default_pack")
        metric_keys = task.get("metric_keys")

        missing = []
        if not project:
            missing.append("project")
        if not runner:
            missing.append("runner")
        if not scenario_path:
            missing.append("scenario_path")
        if tick_budget is None:
            missing.append("tick_budget")
        if not default_pack:
            missing.append("default_pack")
        if metric_keys is None:
            missing.append("metric_keys")

        if missing:
            errors.append({"id": "task_missing_fields", "task_id": task_id, "fields": missing})

        if project and project not in allowed_projects:
            errors.append({"id": "task_project_invalid", "task_id": task_id, "value": project})
        if runner and runner not in allowed_runners:
            errors.append({"id": "task_runner_invalid", "task_id": task_id, "value": runner})
        if default_pack and default_pack not in packs:
            errors.append({"id": "task_pack_missing", "task_id": task_id, "pack": default_pack})

        if metric_keys is not None and not isinstance(metric_keys, list):
            errors.append({"id": "task_metric_keys_invalid", "task_id": task_id, "message": "metric_keys must be a list"})
            metric_keys = []

        if isinstance(metric_keys, list):
            if len(metric_keys) < 2:
                errors.append({"id": "task_metric_keys_too_few", "task_id": task_id})
            if "telemetry.truncated" not in metric_keys:
                errors.append({"id": "task_missing_telemetry_truncated", "task_id": task_id})

        thresholds = task.get("thresholds") or {}
        if not isinstance(thresholds, dict):
            errors.append({"id": "task_thresholds_invalid", "task_id": task_id})
            thresholds = {}
        for key in thresholds.keys():
            if key not in metric_keys:
                errors.append({"id": "task_thresholds_extra", "task_id": task_id, "key": key})
        telemetry_threshold = thresholds.get("telemetry.truncated")
        if "telemetry.truncated" in metric_keys:
            if not isinstance(telemetry_threshold, dict):
                errors.append({"id": "task_telemetry_truncated_threshold_missing", "task_id": task_id})
            else:
                max_val = telemetry_threshold.get("max")
                if max_val != 0:
                    errors.append({"id": "task_telemetry_truncated_threshold_invalid", "task_id": task_id, "value": max_val})

        variance_band = task.get("variance_band") or {}
        if not isinstance(variance_band, dict):
            errors.append({"id": "task_variance_band_invalid", "task_id": task_id})
        else:
            for key in variance_band.keys():
                if key not in metric_keys:
                    errors.append({"id": "task_variance_band_extra", "task_id": task_id, "key": key})

        default_seeds = task.get("default_seeds")
        if default_seeds is not None:
            if not isinstance(default_seeds, list) or not default_seeds:
                errors.append({"id": "task_default_seeds_invalid", "task_id": task_id})
            else:
                bad_seed = next((seed for seed in default_seeds if not isinstance(seed, int)), None)
                if bad_seed is not None:
                    errors.append({"id": "task_default_seeds_invalid", "task_id": task_id})

        seed_policy = task.get("seed_policy")
        if seed_policy is not None and seed_policy not in ("ai_polish", "none"):
            errors.append({"id": "task_seed_policy_invalid", "task_id": task_id, "value": seed_policy})
        if seed_policy == "ai_polish":
            if runner not in ("scenario_runner", "space4x_loader"):
                errors.append({"id": "task_seed_policy_runner_invalid", "task_id": task_id, "runner": runner})
            if not isinstance(default_seeds, list) or len(default_seeds) < 3:
                errors.append({"id": "task_seed_policy_seeds_missing", "task_id": task_id})
            else:
                counts = {}
                for seed_value in default_seeds:
                    if not isinstance(seed_value, int):
                        counts = None
                        break
                    counts[seed_value] = counts.get(seed_value, 0) + 1
                if counts is None:
                    errors.append({"id": "task_seed_policy_seeds_invalid", "task_id": task_id})
                else:
                    if len(counts) < 2 or max(counts.values()) < 2:
                        errors.append({"id": "task_seed_policy_seeds_pattern_invalid", "task_id": task_id})

    ok = len(errors) == 0
    out = {
        "ok": ok,
        "error_code": "none" if ok else "contract_failed",
        "error": None if ok else "contract check failed",
        "run_id": None,
        "errors": errors,
        "warnings": warnings
    }
    emit_result(out, 0 if ok else 3)


def bundle_artifacts(run_id):
    tri_root = resolve_tri_root()
    state_dir = resolve_state_dir(tri_root)
    run_dir = os.path.join(state_dir, "runs", run_id)
    if not os.path.exists(run_dir):
        emit_result({
            "ok": False,
            "error_code": "run_not_found",
            "error": f"run not found: {run_id}",
            "run_id": run_id
        }, 2)
    bundle_name = f"bundle_{run_id}.tar.gz"
    bundle_path = os.path.join(run_dir, bundle_name)
    def tar_filter(tarinfo):
        if tarinfo.name.endswith(bundle_name):
            return None
        return tarinfo
    with tarfile.open(bundle_path, "w:gz") as tar:
        tar.add(run_dir, arcname=f"run_{run_id}", filter=tar_filter)
    out = {
        "ok": True,
        "error_code": "none",
        "error": None,
        "run_id": run_id,
        "bundle_path": bundle_path
    }
    emit_result(out, 0)


def validate():
    tool_root = resolve_tool_root()
    tri_root = resolve_tri_root()
    state_dir = resolve_state_dir(tri_root)
    lock_path = check_build_lock(state_dir)
    if lock_path:
        result = build_error_result("build_locked", f"build.lock present: {lock_path}")
        result["lock_path"] = lock_path
        emit_result(result, 2)
    tasks_path = os.path.join(tool_root, "Tools", "Headless", "headless_tasks.json")
    if not os.path.exists(tasks_path):
        emit_result(build_error_result("tasks_missing", f"tasks registry not found: {tasks_path}"), 2)

    tasks = load_json(tasks_path).get("tasks", {})
    validate_tasks = [
        ("scenario_runner", "P0.TIME_REWIND_MICRO"),
        ("godgame_loader", "G0.GODGAME_SMOKE"),
        ("space4x_loader", "S0.SPACE4X_SMOKE")
    ]
    results = {}
    errors = []
    ok = True

    script_path = os.path.abspath(__file__)

    for runner, task_id in validate_tasks:
        task = tasks.get(task_id)
        if not task:
            ok = False
            errors.append({"runner": runner, "task_id": task_id, "error": "task_not_found"})
            continue
        if task.get("runner") != runner:
            ok = False
            errors.append({"runner": runner, "task_id": task_id, "error": "task_runner_mismatch"})
            continue

        cmd = [sys.executable, script_path, "run_task", task_id]
        eprint(f"HEADLESSCTL: validate start runner={runner} task={task_id}")
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
        stdout, stderr = proc.communicate()
        if stderr:
            eprint(stderr.rstrip())

        stdout_lines = [line for line in stdout.splitlines() if line.strip()]
        stdout_ok = len(stdout_lines) == 1
        run_result = None
        stdout_error = None
        if stdout_ok:
            try:
                run_result = json.loads(stdout_lines[0])
            except Exception as exc:
                stdout_ok = False
                stdout_error = f"stdout_json_parse_failed: {exc}"
        else:
            stdout_error = "stdout_line_count_invalid"

        required_keys = ["ok", "error_code", "error", "run_id", "tool_version", "schema_version"]
        missing_keys = []
        if run_result:
            for key in required_keys:
                if key not in run_result:
                    missing_keys.append(key)

        run_id = run_result.get("run_id") if run_result else None
        run_dir = os.path.join(state_dir, "runs", run_id) if run_id else None

        checks = []
        allow_fail = bool(task.get("allow_fail"))
        allow_error_codes = set(task.get("validate_allow_error_codes") or [])
        allow_invariant_failures = set(task.get("validate_allow_invariant_failures") or [])
        run_ok = run_result is not None and (run_result.get("ok") is True or allow_fail)
        if run_result is not None and run_result.get("ok") is False:
            error_code = run_result.get("error_code")
            if error_code in allow_error_codes:
                run_ok = True
            elif allow_invariant_failures and error_code == "invariant_failed":
                failed_invariants = [
                    inv.get("name")
                    for inv in run_result.get("invariants", [])
                    if inv.get("ok") is False
                ]
                if failed_invariants and all(name in allow_invariant_failures for name in failed_invariants):
                    run_ok = True
        checks.append({
            "name": "run_result.ok",
            "ok": run_ok,
            "value": run_result.get("ok") if run_result else None,
            "allow_fail": allow_fail
        })
        if run_dir:
            result_path = os.path.join(run_dir, "result.json")
            checks.append({
                "name": "result.json",
                "ok": os.path.exists(result_path) and os.path.getsize(result_path) > 0,
                "path": result_path
            })

        artifact_runs = []
        if run_result and run_result.get("seed_runs"):
            artifact_runs = run_result.get("seed_runs", [])
        elif run_result:
            artifact_runs = [run_result]

        for artifact_run in artifact_runs:
            artifacts = artifact_run.get("artifacts", {}) if artifact_run else {}
            metrics_path = artifacts.get("metrics")
            invariants_path = artifacts.get("invariants")
            label = artifact_run.get("run_id") or "single"
            checks.append({
                "name": f"metrics.jsonl:{label}",
                "ok": bool(metrics_path) and metrics_path.endswith(".jsonl") and os.path.exists(metrics_path) and os.path.getsize(metrics_path) > 0,
                "path": metrics_path
            })
            checks.append({
                "name": f"invariants.jsonl:{label}",
                "ok": bool(invariants_path) and invariants_path.endswith(".jsonl") and os.path.exists(invariants_path) and os.path.getsize(invariants_path) > 0,
                "path": invariants_path
            })

        diff_result = None
        diff_ok = False
        diff_exit = None
        if run_id:
            diff_result, diff_exit = diff_metrics_internal(run_id, run_id)
            diff_ok = diff_exit == 0 and diff_result.get("grades") and len(diff_result.get("grades", {})) > 0
            if not diff_ok:
                checks.append({"name": "diff_metrics.grades", "ok": False})
            else:
                checks.append({"name": "diff_metrics.grades", "ok": True})

        metrics_summary = run_result.get("metrics_summary", {}) if run_result else {}
        metric_keys = task.get("validate_metric_keys")
        if metric_keys is None:
            metric_keys = task.get("metric_keys", [])
        missing_metrics = [key for key in metric_keys if not isinstance(metrics_summary.get(key), (int, float))]
        checks.append({
            "name": "metrics.oracle_keys",
            "ok": len(missing_metrics) == 0,
            "missing": missing_metrics
        })

        truncated_value = metrics_summary.get("telemetry.truncated")
        truncated_ok = True
        if isinstance(truncated_value, (int, float)):
            truncated_ok = truncated_value == 0
        checks.append({
            "name": "telemetry.truncated",
            "ok": truncated_ok,
            "value": truncated_value
        })

        runner_ok = stdout_ok and not missing_keys and all(check.get("ok") for check in checks)
        if not runner_ok:
            ok = False
            errors.append({
                "runner": runner,
                "task_id": task_id,
                "stdout_error": stdout_error,
                "missing_keys": missing_keys
            })

        results[runner] = {
            "task_id": task_id,
            "exit_code": proc.returncode,
            "stdout_ok": stdout_ok,
            "stdout_error": stdout_error,
            "missing_keys": missing_keys,
            "checks": checks,
            "run_id": run_id,
            "diff_exit_code": diff_exit,
            "diff_ok": diff_ok
        }

        eprint(f"HEADLESSCTL: validate done runner={runner} ok={runner_ok}")

    out = {
        "ok": ok,
        "error_code": "none" if ok else "validation_failed",
        "error": None if ok else "headlessctl validate failed",
        "run_id": None,
        "results": results,
        "errors": errors
    }
    emit_result(out, 0 if ok else 3)


def main():
    cmd, args = parse_args(sys.argv[1:])
    if cmd is None:
        emit_result({
            "ok": False,
            "error_code": "missing_command",
            "error": "missing command",
            "run_id": None
        }, 2)

    if cmd == "run_task":
        task_id, seed, seeds, pack, err = parse_run_task_args(args)
        if err:
            emit_result({
                "ok": False,
                "error_code": err,
                "error": "invalid run_task args",
                "run_id": None
            }, 2)
        run_task(task_id, seed, seeds, pack)

    if cmd == "get_metrics":
        values, err = parse_simple_args(args, 1)
        if err:
            emit_result({
                "ok": False,
                "error_code": err,
                "error": "missing run_id",
                "run_id": None
            }, 2)
        get_metrics(values[0])

    if cmd == "diff_metrics":
        values, err = parse_simple_args(args, 2)
        if err:
            emit_result({
                "ok": False,
                "error_code": err,
                "error": "missing run ids",
                "run_id": None
            }, 2)
        diff_metrics(values[0], values[1])

    if cmd == "contract_check":
        contract_check()

    if cmd == "bundle_artifacts":
        values, err = parse_simple_args(args, 1)
        if err:
            emit_result({
                "ok": False,
                "error_code": err,
                "error": "missing run_id",
                "run_id": None
            }, 2)
        bundle_artifacts(values[0])

    if cmd == "validate":
        validate()

    if cmd == "claim_session_lock":
        tri_root = resolve_tri_root()
        state_dir = resolve_state_dir(tri_root)
        ttl, purpose, _ = parse_session_lock_args(args)
        result = claim_session_lock(state_dir, ttl, purpose)
        acquired = result.get("acquired", False)
        lock = result.get("lock")
        emit_result({
            "ok": acquired,
            "error_code": "none" if acquired else "locked",
            "error": None if acquired else "session lock already held",
            "run_id": lock.get("run_id") if lock else None,
            "acquired": acquired,
            "lock_path": result.get("lock_path"),
            "lock": lock,
            "warning": result.get("warning"),
            "ttl_sec": ttl
        }, 0 if acquired else 3)

    if cmd == "release_session_lock":
        tri_root = resolve_tri_root()
        state_dir = resolve_state_dir(tri_root)
        _, _, run_id = parse_session_lock_args(args)
        result = release_session_lock(state_dir, run_id)
        emit_result({
            "ok": True,
            "error_code": "none",
            "error": None,
            "run_id": result.get("lock", {}).get("run_id") if result.get("lock") else None,
            "released": result.get("released"),
            "lock_path": result.get("lock_path"),
            "lock": result.get("lock")
        }, 0)

    if cmd == "show_session_lock":
        tri_root = resolve_tri_root()
        state_dir = resolve_state_dir(tri_root)
        result = show_session_lock(state_dir)
        lock = result.get("lock")
        emit_result({
            "ok": lock is None,
            "error_code": "none" if lock is None else "locked",
            "error": None if lock is None else "session lock present",
            "run_id": lock.get("run_id") if lock else None,
            "lock_path": result.get("lock_path"),
            "lock": lock
        }, 0)

    if cmd == "cleanup_locks":
        tri_root = resolve_tri_root()
        state_dir = resolve_state_dir(tri_root)
        ttl, _, _ = parse_session_lock_args(args)
        reclaimed = cleanup_session_locks(state_dir, ttl)
        emit_result({
            "ok": True,
            "error_code": "none",
            "error": None,
            "run_id": None,
            "reclaimed": reclaimed
        }, 0)

    if cmd == "cleanup_runs":
        tri_root = resolve_tri_root()
        state_dir = resolve_state_dir(tri_root)
        days, keep_per_task, max_bytes = parse_cleanup_runs_args(args)
        removed = cleanup_runs(state_dir, days, keep_per_task, max_bytes)
        emit_result({
            "ok": True,
            "error_code": "none",
            "error": None,
            "run_id": None,
            "removed": removed,
            "days": days,
            "keep_per_task": keep_per_task,
            "max_bytes": max_bytes
        }, 0)

    emit_result({
        "ok": False,
        "error_code": "unknown_command",
        "error": f"unknown command: {cmd}",
        "run_id": None
    }, 2)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:
        emit_result({
            "ok": False,
            "error_code": "exception",
            "error": str(exc),
            "run_id": None
        }, 2)
