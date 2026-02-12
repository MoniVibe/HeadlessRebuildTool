#!/usr/bin/env python3
import argparse
import json
import os
import re
import sys
import time
import zipfile
from datetime import datetime, timezone
from pathlib import Path


INTEL_ROOT = Path(os.environ.get("ANVILOOP_INTEL_ROOT", "/home/oni/anviloop_intel"))
LEDGER_PATH = Path(
    os.environ.get(
        "ANVILOOP_INTEL_LEDGER_PATH",
        "/home/oni/headless/HeadlessRebuildTool/Polish/Docs/ANVILOOP_RECURRING_ERRORS.md",
    )
)


def utc_now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def ensure_layout():
    for subdir in ("store", "state", "logs"):
        (INTEL_ROOT / subdir).mkdir(parents=True, exist_ok=True)
    for jsonl_name in ("records.jsonl", "actions.jsonl", "rewards.jsonl"):
        path = INTEL_ROOT / "store" / jsonl_name
        if not path.exists():
            path.write_text("", encoding="utf-8")


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except json.JSONDecodeError:
        return None


def write_json(path, payload):
    Path(path).write_text(json.dumps(payload, indent=2, sort_keys=False), encoding="utf-8")


def append_jsonl(path, payload):
    with Path(path).open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, sort_keys=False) + "\n")


def load_processed_state():
    path = INTEL_ROOT / "state" / "processed.json"
    data = read_json(path)
    return data if isinstance(data, dict) else {}


def save_processed_state(state):
    path = INTEL_ROOT / "state" / "processed.json"
    write_json(path, state)


def file_key(path):
    stat = Path(path).stat()
    return f"{Path(path).name}|{stat.st_size}|{int(stat.st_mtime)}"


def lazy_import_numpy():
    try:
        import numpy as np

        return np
    except Exception:
        return None


def lazy_import_faiss():
    try:
        import faiss

        return faiss
    except Exception:
        return None


def lazy_import_sentence_transformers():
    try:
        from sentence_transformers import SentenceTransformer

        return SentenceTransformer
    except Exception:
        return None


def lazy_import_drain3():
    try:
        from drain3 import TemplateMiner
        from drain3.persistence_handler import FilePersistence
        from drain3.template_miner_config import TemplateMinerConfig

        return TemplateMiner, FilePersistence, TemplateMinerConfig
    except Exception:
        return None, None, None


def init_drain3(state_path):
    template_miner_cls, persistence_cls, config_cls = lazy_import_drain3()
    if not template_miner_cls or not persistence_cls or not config_cls:
        return None
    try:
        config = config_cls()
        persistence = persistence_cls(str(state_path))
        return template_miner_cls(persistence, config)
    except Exception:
        return None


def save_drain3_state(miner):
    if not miner:
        return
    if hasattr(miner, "save_state"):
        try:
            miner.save_state()
        except Exception:
            return
    if hasattr(miner, "persistence_handler") and hasattr(miner, "drain"):
        try:
            miner.persistence_handler.save_state(miner.drain)
        except Exception:
            return


def normalize_text(text, max_chars=4000):
    if not text:
        return ""
    text = text.strip()
    if len(text) <= max_chars:
        return text
    return text[-max_chars:]


def split_lines(text, max_lines=80):
    if not text:
        return []
    lines = [line.rstrip() for line in text.splitlines() if line.strip()]
    if len(lines) <= max_lines:
        return lines
    return lines[-max_lines:]


BANK_RE = re.compile(r"\bBANK:(?P<test_id>[^:]+):(?P<status>PASS|FAIL)\b(?P<rest>.*)", re.IGNORECASE)


def extract_bank_signal(text):
    if not text:
        return {"found": False, "status": "MISSING", "test_id": None, "line": None}
    for line in text.splitlines():
        if "BANK:" not in line:
            continue
        match = BANK_RE.search(line)
        if not match:
            continue
        test_id = (match.group("test_id") or "").strip()
        status = (match.group("status") or "").upper()
        return {
            "found": True,
            "status": status or "UNKNOWN",
            "test_id": test_id or None,
            "line": line.strip(),
        }
    return {"found": False, "status": "MISSING", "test_id": None, "line": None}


PIPELINE_SMOKE_KV_RE = re.compile(r"^\*\s+(?P<key>[A-Za-z0-9_]+)\s*:\s*(?P<value>.*)\s*$")


def parse_pipeline_smoke_summary(text):
    payload = {}
    if not text:
        return payload
    for line in text.splitlines():
        match = PIPELINE_SMOKE_KV_RE.match(line.strip())
        if not match:
            continue
        key = match.group("key").strip()
        value = (match.group("value") or "").strip()
        payload[key] = value
    return payload


CS_ERROR_RE = re.compile(r"\berror\s+(CS\d+)\b", re.IGNORECASE)
BURST_ERROR_RE = re.compile(r"\bBurst\s+error\s+(BC\d+)\b", re.IGNORECASE)
IL2CPP_RE = re.compile(r"\bIL2CPP\b|\bil2cpp\.exe\b", re.IGNORECASE)
LINKER_RE = re.compile(r"\bUnityLinker\b|\blink(er)?\s+error\b|\bld:\s+error\b", re.IGNORECASE)
SCRIPT_COMPILATION_RE = re.compile(r"\bScriptCompilation\b|\bCompilationFailedException\b", re.IGNORECASE)
BEE_RE = re.compile(r"\bBeeStall\b|\bLibrary/Bee\b|\bScriptCompilationBuildProgram\b", re.IGNORECASE)
HANG_RE = re.compile(
    r"\bHANG_TIMEOUT\b|\bhung\b|\bhang\b|\bstall\b|\bdeadlock\b|\bno progress\b",
    re.IGNORECASE,
)
ONDEMAND_TIMEOUT_RE = re.compile(
    r"\bOnDemand\b.*\btimeout\b|\btimed out connecting\b|\bWorker timed out\b",
    re.IGNORECASE,
)
THREADPOOL_STARVATION_RE = re.compile(r"\bthread pool starvation\b", re.IGNORECASE)


def extract_compilation_signals(text):
    """Heuristically summarize build/compile-related failures from arbitrary logs/snippets.

    This is intentionally broad: it should classify "compilation in general" without
    depending on a single subsystem (Burst/C#/IL2CPP/linker).
    """
    signals = {
        "detected": False,
        "csharp_error_codes": [],
        "burst_error_codes": [],
        "has_il2cpp": False,
        "has_linker": False,
        "has_script_compilation": False,
        "has_bee": False,
        "sample_lines": [],
    }
    if not text:
        return signals

    # Codes: scan full text (head + tail), not just tail lines.
    csharp = CS_ERROR_RE.findall(text) or []
    burst = BURST_ERROR_RE.findall(text) or []
    signals["csharp_error_codes"] = sorted(set(csharp))[:10]
    signals["burst_error_codes"] = sorted(set(burst))[:10]
    signals["has_il2cpp"] = bool(IL2CPP_RE.search(text))
    signals["has_linker"] = bool(LINKER_RE.search(text))
    signals["has_script_compilation"] = bool(SCRIPT_COMPILATION_RE.search(text))
    signals["has_bee"] = bool(BEE_RE.search(text))

    # Samples: prefer lines that include actionable compilation markers; avoid generic noise.
    samples = []
    for raw in text.splitlines():
        line = (raw or "").strip()
        if not line:
            continue
        lowered = line.lower()
        if "burst error bc" in lowered or "error cs" in lowered:
            samples.append(line)
        elif "compilationfailedexception" in lowered or "scriptcompilation" in lowered:
            samples.append(line)
        elif "unitylinker" in lowered or "linker error" in lowered:
            samples.append(line)
        elif "il2cpp" in lowered:
            samples.append(line)
        elif "beestall" in lowered:
            samples.append(line)
        if len(samples) >= 15:
            break
    signals["sample_lines"] = samples[:15]

    signals["detected"] = bool(
        signals["csharp_error_codes"]
        or signals["burst_error_codes"]
        or signals["has_il2cpp"]
        or signals["has_linker"]
        or signals["has_script_compilation"]
    )
    return signals


def extract_stall_signals(text):
    signals = {
        "detected": False,
        "has_hang_timeout": False,
        "has_beestall": False,
        "has_on_demand_timeout": False,
        "has_threadpool_starvation": False,
        "sample_lines": [],
    }
    if not text:
        return signals

    signals["has_hang_timeout"] = bool(HANG_RE.search(text))
    signals["has_beestall"] = bool(re.search(r"\bBeeStall\b", text, re.IGNORECASE))
    signals["has_on_demand_timeout"] = bool(ONDEMAND_TIMEOUT_RE.search(text))
    signals["has_threadpool_starvation"] = bool(THREADPOOL_STARVATION_RE.search(text))

    samples = []
    for raw in text.splitlines():
        line = (raw or "").strip()
        if not line:
            continue
        lowered = line.lower()
        if "hang_timeout" in lowered or "beestall" in lowered:
            samples.append(line)
        elif "thread pool starvation" in lowered:
            samples.append(line)
        elif "timed out" in lowered and ("worker" in lowered or "ondemand" in lowered):
            samples.append(line)
        if len(samples) >= 15:
            break
    signals["sample_lines"] = samples[:15]

    signals["detected"] = bool(
        signals["has_hang_timeout"]
        or signals["has_beestall"]
        or signals["has_on_demand_timeout"]
        or signals["has_threadpool_starvation"]
    )
    return signals


def read_zip_json(zf, member):
    try:
        with zf.open(member) as handle:
            return json.loads(handle.read().decode("utf-8"))
    except KeyError:
        return None
    except Exception:
        return None


def read_zip_tail_text(zf, member, max_bytes=65536):
    try:
        info = zf.getinfo(member)
    except KeyError:
        return ""
    try:
        buf = bytearray()
        with zf.open(info) as handle:
            while True:
                chunk = handle.read(8192)
                if not chunk:
                    break
                buf.extend(chunk)
                if len(buf) > max_bytes:
                    buf = buf[-max_bytes:]
        return buf.decode("utf-8", errors="replace")
    except Exception:
        return ""


def read_zip_head_text(zf, member, max_bytes=65536):
    try:
        with zf.open(member) as handle:
            data = handle.read(max_bytes)
    except KeyError:
        return ""
    except Exception:
        return ""
    return data.decode("utf-8", errors="replace")


def zip_has_entry(zf, member):
    try:
        zf.getinfo(member)
        return True
    except KeyError:
        return False


def parse_telemetry_tail_metrics(zf):
    metrics = {}
    text = read_zip_tail_text(zf, "out/telemetry.ndjson", max_bytes=262144)
    if not text:
        text = read_zip_tail_text(zf, "telemetry.ndjson", max_bytes=262144)
    if not text:
        return metrics
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    for line in lines[-200:]:
        try:
            payload = json.loads(line)
        except Exception:
            continue
        if not isinstance(payload, dict):
            continue
        name = payload.get("metric") or payload.get("key")
        if not name:
            continue
        value = payload.get("value")
        if value is None:
            continue
        metrics[name] = value
    return metrics


def telemetry_contains_key(zf, key, max_bytes=1048576):
    for member in ("out/telemetry.ndjson", "telemetry.ndjson"):
        text = read_zip_head_text(zf, member, max_bytes=max_bytes)
        if text and key in text:
            return True
        text = read_zip_tail_text(zf, member, max_bytes=max_bytes)
        if text and key in text:
            return True
    return False


def normalize_bool(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "y", "t")
    return False


def read_zip_json_any(zf, members):
    for member in members:
        payload = read_zip_json(zf, member)
        if payload is not None:
            return payload
    return None


def summarize_operator_report(report):
    if not isinstance(report, dict):
        return None

    summary = {
        "required": {"pass": 0, "fail": 0, "unknown": 0, "total": 0},
        "optional": {"pass": 0, "fail": 0, "unknown": 0, "total": 0},
        "unknown_reasons": [],
        "failing_required_ids": [],
        "unknown_required_ids": [],
        "source": "operator_report",
    }

    def normalize_status(value):
        text = str(value or "").strip().lower()
        if text in ("pass", "passed", "ok", "success", "true"):
            return "pass"
        if text in ("fail", "failed", "error", "false"):
            return "fail"
        if text in ("unknown", "missing", "unanswered", "unresolved", "pending", "n/a", "na"):
            return "unknown"
        return "unknown"

    def push_reason(bucket, reason):
        if not reason:
            return
        bucket[reason] = bucket.get(reason, 0) + 1

    questions = report.get("questions")
    if not isinstance(questions, list):
        questions = report.get("required_questions")
    if not isinstance(questions, list):
        questions = report.get("question_statuses")

    unknown_reason_counts = {}
    failing_required_ids = []
    unknown_required_ids = []

    if isinstance(questions, list):
        for item in questions:
            if not isinstance(item, dict):
                continue
            required = bool(item.get("required", False))
            status = normalize_status(item.get("status"))
            reason = (
                item.get("unknown_reason")
                or item.get("reason")
                or item.get("message")
                or ""
            )
            qid = item.get("id") or item.get("question_id") or item.get("key")
            bucket = summary["required"] if required else summary["optional"]
            bucket["total"] += 1
            bucket[status] += 1
            if status == "unknown":
                push_reason(unknown_reason_counts, str(reason))
                if required and qid:
                    unknown_required_ids.append(str(qid))
            if status == "fail" and required and qid:
                failing_required_ids.append(str(qid))
    else:
        summary["source"] = "operator_report_missing_questions"

    if not isinstance(questions, list):
        unknown_flags = []
        for key in (
            "required_questions_unknown",
            "unknown_required_questions",
            "required_questions_missing",
            "required_questions_unanswered",
            "required_questions_unresolved",
        ):
            value = report.get(key)
            if value:
                unknown_flags.append(key)
        if unknown_flags:
            summary["required"]["unknown"] += len(unknown_flags)
            summary["required"]["total"] += len(unknown_flags)
            for key in unknown_flags:
                push_reason(unknown_reason_counts, key)

    summary["unknown_reasons"] = [
        {"reason": reason, "count": count}
        for reason, count in sorted(unknown_reason_counts.items(), key=lambda item: (-item[1], item[0]))
        if reason
    ][:5]
    summary["failing_required_ids"] = failing_required_ids[:5]
    summary["unknown_required_ids"] = unknown_required_ids[:5]

    return summary


def extract_proof_lines(text, max_lines=10):
    proof = []
    for line in split_lines(text, max_lines=200):
        if "[Anviloop]" in line or "[Anviloop][FTL]" in line:
            proof.append(line)
    return proof[:max_lines]


def pick_headline(stderr_lines, raw_signature, exit_reason):
    for line in reversed(stderr_lines):
        lowered = line.lower()
        if "exception" in lowered or "error" in lowered or "fatal" in lowered:
            return line.strip()
    if raw_signature:
        return raw_signature.strip()
    return exit_reason or "UNKNOWN"


def drain3_templates(miner, lines):
    if not miner:
        return [], []
    template_ids = []
    template_texts = []
    for line in lines:
        if not line.strip():
            continue
        result = miner.add_log_message(line)
        if not isinstance(result, dict):
            continue
        cluster_id = result.get("cluster_id")
        template = result.get("template_mined")
        if template is None and cluster_id is not None:
            try:
                cluster = miner.drain.clusters[cluster_id]
                template = cluster.get_template()
            except Exception:
                template = None
        if cluster_id is not None:
            template_ids.append(str(cluster_id))
        if template:
            template_texts.append(template)
    save_drain3_state(miner)
    return template_ids, template_texts


def load_embedding_model():
    model_name = os.environ.get("ANVILOOP_EMBED_MODEL", "all-MiniLM-L6-v2")
    sentence_transformers = lazy_import_sentence_transformers()
    if not sentence_transformers:
        return None
    try:
        return sentence_transformers(model_name)
    except Exception:
        return None


def embed_texts(model, texts):
    if not model:
        return None
    if not texts:
        return None
    try:
        return model.encode(texts, normalize_embeddings=True)
    except Exception:
        return None


def create_faiss_index(dim):
    faiss = lazy_import_faiss()
    if not faiss:
        return None
    return faiss.IndexFlatIP(dim)


def load_faiss_index(path):
    faiss = lazy_import_faiss()
    if not faiss:
        return None
    try:
        return faiss.read_index(str(path))
    except Exception:
        return None


def save_faiss_index(index, path):
    faiss = lazy_import_faiss()
    if not faiss or index is None:
        return
    faiss.write_index(index, str(path))


def search_index(index, query_vec, meta_path, top_k=3):
    np = lazy_import_numpy()
    if not index or np is None:
        return []
    try:
        distances, indices = index.search(query_vec, top_k)
    except Exception:
        return []
    meta_lines = []
    if Path(meta_path).exists():
        with Path(meta_path).open("r", encoding="utf-8") as handle:
            meta_lines = [json.loads(line) for line in handle if line.strip()]
    results = []
    for score, idx in zip(distances[0], indices[0]):
        if idx < 0 or idx >= len(meta_lines):
            continue
        entry = dict(meta_lines[idx])
        entry["score"] = float(score)
        results.append(entry)
    return results


def parse_ledger_entries(ledger_text):
    entries = []
    current_id = None
    current_lines = []
    for line in ledger_text.splitlines():
        if line.startswith("ERR-"):
            if current_id:
                entries.append((current_id, current_lines))
            current_id = line.strip()
            current_lines = []
        elif current_id:
            current_lines.append(line.rstrip())
    if current_id:
        entries.append((current_id, current_lines))

    parsed = []
    for entry_id, lines in entries:
        fields = {}
        for line in lines:
            match = re.match(r"-\s*([A-Za-z0-9_]+):\s*(.*)", line)
            if not match:
                continue
            key = match.group(1).strip().lower()
            value = match.group(2).strip()
            fields[key] = value
        parsed.append(
            {
                "id": entry_id,
                "symptom": fields.get("symptom", ""),
                "signature": fields.get("signature", ""),
                "rootcause": fields.get("rootcause", ""),
                "fix": fields.get("fix", ""),
                "prevention": fields.get("prevention", ""),
                "verification": fields.get("verification", ""),
                "commit": fields.get("commit", ""),
                "raw_text": "\n".join(lines).strip(),
            }
        )
    return parsed


def read_text_file(path, max_bytes=262144):
    try:
        data = Path(path).read_bytes()
    except FileNotFoundError:
        return ""
    except Exception:
        return ""
    if max_bytes and len(data) > max_bytes:
        data = data[-max_bytes:]
    try:
        return data.decode("utf-8", errors="replace")
    except Exception:
        return ""


def find_first_existing(paths):
    for path in paths:
        if Path(path).exists():
            return Path(path)
    return None


BUILD_ID_RE = re.compile(r"^(?:artifact|result)_(?P<build_id>\d{8}_\d{6}_\d+_[0-9a-f]{8})", re.IGNORECASE)


def extract_build_id_from_filename(name):
    match = BUILD_ID_RE.match(name or "")
    if not match:
        return None
    return match.group("build_id")


def pick_results_entries_for_build_id(results_dir, build_id):
    """Support both extracted diagnostics (directories) and raw zips.

    buildbox downloads often contain extracted `results/artifact_<build_id>/...` directories
    rather than `*.zip` files.
    """
    if not results_dir or not Path(results_dir).exists() or not build_id:
        return None, None, []
    results_dir = Path(results_dir)
    artifact_entry = None
    result_entry = None
    all_build_ids = []

    for candidate in sorted(results_dir.iterdir()):
        bid = extract_build_id_from_filename(candidate.name)
        if bid:
            all_build_ids.append(bid)
        if bid != build_id:
            continue
        if candidate.name.startswith("artifact_") and artifact_entry is None:
            artifact_entry = candidate
        if candidate.name.startswith("result_") and result_entry is None:
            result_entry = candidate

    # If directories weren't present, fall back to zips (older layouts).
    if artifact_entry is None or result_entry is None:
        for candidate in sorted(results_dir.glob("*.zip")):
            bid = extract_build_id_from_filename(candidate.name)
            if bid and bid not in all_build_ids:
                all_build_ids.append(bid)
            if bid != build_id:
                continue
            if candidate.name.startswith("artifact_") and artifact_entry is None:
                artifact_entry = candidate
            if candidate.name.startswith("result_") and result_entry is None:
                result_entry = candidate

    return artifact_entry, result_entry, all_build_ids


def pick_build_headline(smoke, compiler_signals, fallback_text):
    first = (smoke.get("build_first_error") or "").strip()
    if first:
        return first
    for line in split_lines(fallback_text or "", max_lines=120):
        lowered = line.lower()
        if "error" in lowered or "exception" in lowered or "fatal" in lowered:
            return line.strip()
    if compiler_signals and compiler_signals.get("sample_lines"):
        return compiler_signals["sample_lines"][-1]
    return (smoke.get("failure") or smoke.get("status") or "UNKNOWN").strip() or "UNKNOWN"


def build_record_from_diag_dir(diag_dir):
    diag_dir = Path(diag_dir)
    smoke_path = diag_dir / "pipeline_smoke_summary_latest.md"
    smoke_text = read_text_file(smoke_path)
    smoke = parse_pipeline_smoke_summary(smoke_text)

    compiler_errors = read_text_file(diag_dir / "compiler_errors.txt")
    build_error_summary = read_text_file(diag_dir / "build_error_summary.txt")
    missing_scripts = read_text_file(diag_dir / "missing_scripts.txt")
    pipeline_smoke_log = read_text_file(diag_dir / "pipeline_smoke.log")

    build_id = smoke.get("build_id") or None
    smoke_commit = smoke.get("commit") or None
    smoke_scenario_id = smoke.get("scenario_id") or None

    artifact_snippet = ""
    results_dir = diag_dir / "results"
    artifact_entry, result_entry, found_build_ids = pick_results_entries_for_build_id(
        results_dir, build_id
    )

    if artifact_entry:
        if artifact_entry.is_dir():
            artifact_snippet = read_text_file(
                artifact_entry / "logs" / "primary_error_snippet.txt",
                max_bytes=65536,
            )
            if not artifact_snippet:
                artifact_snippet = read_text_file(
                    artifact_entry / "logs" / "unity_build_tail.txt",
                    max_bytes=65536,
                )
        else:
            try:
                with zipfile.ZipFile(artifact_entry, "r") as zf:
                    artifact_snippet = read_zip_tail_text(
                        zf, "logs/primary_error_snippet.txt", max_bytes=65536
                    )
                    if not artifact_snippet:
                        artifact_snippet = read_zip_tail_text(
                            zf, "logs/unity_build_tail.txt", max_bytes=65536
                        )
            except Exception:
                artifact_snippet = ""

    # If a matching result zip exists for this build_id, pull additional evidence/telemetry signals.
    run_summary = {}
    watchdog = {}
    meta = {}
    telemetry_truncated = None
    telemetry_events = None
    telemetry_bytes = None
    if result_entry:
        try:
            if result_entry.is_dir():
                meta = read_json(result_entry / "meta.json") or {}
                watchdog = read_json(result_entry / "out" / "watchdog.json") or {}
                run_summary = read_json(result_entry / "out" / "run_summary.json") or {}

                telemetry_path = result_entry / "out" / "telemetry.ndjson"
                telemetry_metrics = {}
                if telemetry_path.exists():
                    try:
                        tail = read_text_file(telemetry_path, max_bytes=262144)
                        for line in [ln.strip() for ln in tail.splitlines() if ln.strip()][-200:]:
                            try:
                                payload = json.loads(line)
                            except Exception:
                                continue
                            if not isinstance(payload, dict):
                                continue
                            name = payload.get("metric") or payload.get("key")
                            if not name:
                                continue
                            value = payload.get("value")
                            if value is None:
                                continue
                            telemetry_metrics[name] = value
                    except Exception:
                        telemetry_metrics = {}
                telemetry_truncated = telemetry_metrics.get("telemetry.truncated")
            else:
                with zipfile.ZipFile(result_entry, "r") as zf:
                    meta = read_zip_json(zf, "meta.json") or {}
                    watchdog = read_zip_json(zf, "out/watchdog.json") or {}
                    run_summary = read_zip_json(zf, "out/run_summary.json") or {}
                    telemetry_metrics = parse_telemetry_tail_metrics(zf)
                    telemetry_truncated = telemetry_metrics.get("telemetry.truncated")
        except Exception:
            meta = {}
            watchdog = {}
            run_summary = {}
            telemetry_truncated = None

        telemetry_summary = run_summary.get("telemetry_summary") if isinstance(run_summary, dict) else None
        telemetry_events = (
            telemetry_summary.get("event_total") if isinstance(telemetry_summary, dict) else None
        )
        telemetry_bytes = run_summary.get("telemetry_bytes") if isinstance(run_summary, dict) else None

        if telemetry_truncated is None and isinstance(run_summary, dict):
            telemetry = run_summary.get("telemetry")
            if isinstance(telemetry, dict):
                telemetry_truncated = telemetry.get("truncated")
            if telemetry_truncated is None:
                telemetry_truncated = run_summary.get("telemetry_truncated")

    # Detect obvious metadata mismatches when both smoke summary and result meta exist.
    meta_mismatch = []
    if result_entry and isinstance(meta, dict) and meta:
        if build_id and meta.get("build_id") and str(meta.get("build_id")) != str(build_id):
            meta_mismatch.append("build_id")
        if smoke_commit and meta.get("commit") and str(meta.get("commit")) != str(smoke_commit):
            meta_mismatch.append("commit")
        if smoke_scenario_id and meta.get("scenario_id") and str(meta.get("scenario_id")) != str(smoke_scenario_id):
            meta_mismatch.append("scenario_id")

    corpus = "\n".join(
        [
            smoke_text.strip(),
            build_error_summary.strip(),
            compiler_errors.strip(),
            missing_scripts.strip(),
            artifact_snippet.strip(),
            pipeline_smoke_log.strip(),
            read_text_file(diag_dir / "logs" / "watchdog_heartbeat.log", max_bytes=262144).strip(),
        ]
    ).strip()
    compiler_signals = extract_compilation_signals(corpus)
    stall_signals = extract_stall_signals(corpus)

    run_id = None
    match = re.search(r"_(\d{6,})$", diag_dir.name)
    if match:
        run_id = match.group(1)

    title = smoke.get("title") or smoke.get("Title") or None
    status = smoke.get("status") or ""

    headline = pick_build_headline(smoke, compiler_signals, build_error_summary or artifact_snippet or pipeline_smoke_log)
    embed_text = " | ".join(
        [
            "BUILD",
            title or "",
            status,
            smoke.get("failure") or "",
            headline,
            " ".join(compiler_signals.get("csharp_error_codes") or []),
            " ".join(compiler_signals.get("burst_error_codes") or []),
            "BeeStall" if stall_signals.get("has_beestall") else "",
            "HANG_TIMEOUT" if stall_signals.get("has_hang_timeout") else "",
        ]
    ).strip()

    record_id = f"diag_{run_id}" if run_id else f"diag_{diag_dir.name}"

    invalid_reasons = []
    warning_reasons = []
    if not smoke:
        invalid_reasons.append("smoke_summary_missing")
    if build_id and not artifact_entry and results_dir.exists():
        invalid_reasons.append("artifact_zip_missing_for_build_id")
    if found_build_ids and build_id:
        other = [bid for bid in found_build_ids if bid != build_id]
        if other:
            warning_reasons.append("stale_mixed_results_present")
    if status.upper() == "SUCCESS" and not result_entry and results_dir.exists():
        invalid_reasons.append("result_zip_missing_for_success")
    if result_entry:
        if not meta:
            invalid_reasons.append("meta_missing_in_result_zip")
        if not watchdog:
            invalid_reasons.append("watchdog_missing_in_result_zip")
        if not run_summary:
            invalid_reasons.append("run_summary_missing_in_result_zip")
        if telemetry_events in (None, 0):
            warning_reasons.append("telemetry_event_total_missing_or_zero")
        if normalize_bool(telemetry_truncated):
            warning_reasons.append("telemetry_truncated")
        if meta_mismatch:
            warning_reasons.append("meta_mismatch:" + ",".join(sorted(set(meta_mismatch))))

    validity = {
        "status": "INVALID"
        if invalid_reasons
        else "OK_WITH_WARNINGS"
        if warning_reasons
        else "VALID",
        "invalid_reasons": invalid_reasons,
        "warning_reasons": warning_reasons,
        "evidence": {
            "has_smoke_summary": bool(smoke_text.strip()),
            "has_build_error_summary": bool(build_error_summary.strip()),
            "has_compiler_errors": bool(compiler_errors.strip()),
            "has_missing_scripts_report": bool(missing_scripts.strip()),
            "artifact_zip_for_build_id": str(artifact_entry) if artifact_entry else None,
            "result_zip_for_build_id": str(result_entry) if result_entry else None,
            "results_build_ids": sorted(set(found_build_ids))[:10],
            "meta_mismatch": meta_mismatch,
            "telemetry_events": telemetry_events,
            "telemetry_bytes": telemetry_bytes,
            "telemetry_truncated": telemetry_truncated,
        },
    }

    record = {
        "record_id": record_id,
        "created_utc": utc_now(),
        "diag_dir": str(diag_dir),
        "meta": {
            "job_id": run_id,
            "build_id": build_id,
            "title": title,
            "status": status,
            "failure": smoke.get("failure") or None,
            "build_first_error": smoke.get("build_first_error") or None,
        },
        "headline": headline,
        "raw_signature_string": "",
        "stdout_tail": split_lines(pipeline_smoke_log, max_lines=60)[-20:],
        "stderr_tail": split_lines(build_error_summary or compiler_errors or artifact_snippet, max_lines=60)[-20:],
        "proof_lines": [],
        "template_ids": [],
        "template_texts": [],
        "metrics": {},
        "validity": validity,
        "questions": None,
        "bank": None,
        "signals": {
            "compilation": compiler_signals,
            "stall": stall_signals,
            "telemetry": {
                "truncated": telemetry_truncated,
                "event_total": telemetry_events,
                "bytes": telemetry_bytes,
            }
            if result_entry
            else {"present": False},
            "evidence": {
                "stale_mixed_results_present": "stale_mixed_results_present"
                in warning_reasons,
                "artifact_zip_for_build_id_present": bool(artifact_entry),
                "result_zip_for_build_id_present": bool(result_entry),
            },
            "missing_scripts_text_present": bool(
                missing_scripts and "no missing script" not in missing_scripts.lower()
            ),
        },
        "embed_text": embed_text,
    }
    return record


def ingest_ledger():
    ensure_layout()
    ledger_text = LEDGER_PATH.read_text(encoding="utf-8") if LEDGER_PATH.exists() else ""
    entries = parse_ledger_entries(ledger_text)
    meta_path = INTEL_ROOT / "state" / "ledger_meta.jsonl"
    index_path = INTEL_ROOT / "state" / "ledger.faiss"

    model = load_embedding_model()
    embeddings = embed_texts(
        model,
        [
            "\n".join(
                [
                    entry.get("symptom", ""),
                    entry.get("signature", ""),
                    entry.get("rootcause", ""),
                    entry.get("fix", ""),
                    entry.get("prevention", ""),
                ]
            ).strip()
            for entry in entries
        ],
    )

    meta_path.write_text("", encoding="utf-8")
    for entry in entries:
        append_jsonl(meta_path, entry)

    if embeddings is None:
        return
    np = lazy_import_numpy()
    if np is None:
        return
    embeddings = np.asarray(embeddings, dtype="float32")
    index = create_faiss_index(embeddings.shape[1])
    if index is None:
        return
    index.add(embeddings)
    save_faiss_index(index, index_path)


def build_record_from_zip(result_zip):
    with zipfile.ZipFile(result_zip, "r") as zf:
        meta = read_zip_json(zf, "meta.json") or {}
        watchdog = read_zip_json(zf, "out/watchdog.json") or {}
        run_summary = read_zip_json(zf, "out/run_summary.json") or {}
        score = read_zip_json(zf, "out/polish_score_v0.json") or {}
        operator_report = read_zip_json_any(
            zf, ["out/operator_report.json", "operator_report.json"]
        )
        questions_summary = summarize_operator_report(operator_report)

        artifact_paths = (
            meta.get("artifact_paths") if isinstance(meta.get("artifact_paths"), dict) else {}
        )
        has_watchdog = bool(watchdog)
        has_run_summary = isinstance(run_summary, dict) and bool(run_summary)
        has_goal_report = zip_has_entry(zf, "out/goal_report.json")

        telemetry_summary = (
            run_summary.get("telemetry_summary") if isinstance(run_summary, dict) else None
        )
        telemetry_events = (
            telemetry_summary.get("event_total")
            if isinstance(telemetry_summary, dict)
            else None
        )
        telemetry_bytes = None
        telemetry_files = None
        if isinstance(run_summary, dict):
            telemetry = run_summary.get("telemetry")
            if isinstance(telemetry, dict):
                telemetry_bytes = telemetry.get("bytes_total")
                telemetry_files = telemetry.get("files")

        telemetry_metrics = parse_telemetry_tail_metrics(zf)
        telemetry_truncated = telemetry_metrics.get("telemetry.truncated")
        if telemetry_truncated is None and isinstance(run_summary, dict):
            telemetry = run_summary.get("telemetry")
            if isinstance(telemetry, dict):
                telemetry_truncated = telemetry.get("truncated")
            if telemetry_truncated is None:
                telemetry_truncated = run_summary.get("telemetry_truncated")

        oracle_heartbeat_present = any(
            telemetry_metrics.get(key) not in (None, 0, False)
            for key in ("telemetry.heartbeat", "telemetry.oracle.heartbeat")
        )
        if not oracle_heartbeat_present:
            oracle_heartbeat_present = telemetry_contains_key(
                zf, "telemetry.heartbeat"
            ) or telemetry_contains_key(zf, "telemetry.oracle.heartbeat")

        invalid_reasons = []
        if not meta:
            invalid_reasons.append("meta_missing")
        if not has_watchdog:
            invalid_reasons.append("watchdog_missing")
        if not has_run_summary:
            invalid_reasons.append("run_summary_missing")
        if telemetry_summary is None:
            invalid_reasons.append("telemetry_summary_missing")
        elif telemetry_events in (None, 0):
            invalid_reasons.append("telemetry_event_total_missing_or_zero")
        if normalize_bool(telemetry_truncated):
            invalid_reasons.append("telemetry_truncated")
        if not oracle_heartbeat_present:
            invalid_reasons.append("telemetry_oracle_heartbeat_missing")

        invariants_present = (
            "invariants_json" in artifact_paths
            or zip_has_entry(zf, "out/invariants.json")
        )
        if not invariants_present:
            invalid_reasons.append("invariants_missing")

        if normalize_bool(meta.get("repo_dirty_post")):
            invalid_reasons.append("repo_dirty_post")
        manifest_drift = meta.get("manifest_drift")
        if isinstance(manifest_drift, dict) and manifest_drift.get("detected"):
            invalid_reasons.append("manifest_drift")

        if meta.get("goal_id") and not meta.get("base_ref"):
            invalid_reasons.append("base_ref_missing")
        if not meta.get("scenario_id") and not meta.get("scenario_rel"):
            invalid_reasons.append("scenario_missing")

        if (
            meta.get("exit_reason") == "OK_WITH_WARNINGS"
            and meta.get("original_exit_reason") == "TEST_FAIL"
        ):
            if "required_questions_unknown" not in invalid_reasons:
                invalid_reasons.append("required_questions_unknown")
        if questions_summary and questions_summary["required"]["unknown"] > 0:
            if "required_questions_unknown" not in invalid_reasons:
                invalid_reasons.append("required_questions_unknown")

        stdout_tail = watchdog.get("stdout_tail", "")
        stderr_tail = watchdog.get("stderr_tail", "")
        if isinstance(stdout_tail, list):
            stdout_tail = "\n".join(stdout_tail)
        if isinstance(stderr_tail, list):
            stderr_tail = "\n".join(stderr_tail)
        stdout_tail = normalize_text(stdout_tail)
        stderr_tail = normalize_text(stderr_tail)

        player_tail = read_zip_tail_text(zf, "out/player.log", max_bytes=65536)
        if not player_tail:
            player_tail = read_zip_tail_text(zf, "player.log", max_bytes=65536)

        required_bank = meta.get("required_bank") or run_summary.get("required_bank")
        bank_info = extract_bank_signal(player_tail)
        if required_bank:
            if not bank_info.get("found"):
                invalid_reasons.append("bank_missing")
            elif bank_info.get("status") != "PASS":
                invalid_reasons.append("bank_fail")
            elif bank_info.get("test_id") and bank_info.get("test_id") != required_bank:
                invalid_reasons.append("bank_wrong_test")

        validity_status = (
            "INVALID"
            if invalid_reasons
            else "OK_WITH_WARNINGS"
            if meta.get("exit_reason") == "OK_WITH_WARNINGS"
            else "VALID"
        )
        evidence = {
            "artifact_paths": sorted(list(artifact_paths.keys())),
            "telemetry_bytes": telemetry_bytes,
            "telemetry_events": telemetry_events,
            "telemetry_files": telemetry_files,
            "telemetry_truncated": telemetry_truncated,
            "oracle_heartbeat_present": oracle_heartbeat_present,
            "has_watchdog": has_watchdog,
            "has_run_summary": has_run_summary,
            "has_goal_report": has_goal_report,
            "repo_status_pre": meta.get("repo_status_pre"),
            "repo_status_post": meta.get("repo_status_post"),
        }
        if isinstance(manifest_drift, dict):
            evidence["manifest_drift"] = manifest_drift

        validity = {
            "status": validity_status,
            "invalid_reasons": invalid_reasons,
            "comparability": {
                "scenario_id": meta.get("scenario_id") or None,
                "scenario_rel": meta.get("scenario_rel") or None,
                "seed": meta.get("seed"),
                "build_id": meta.get("build_id"),
                "commit": meta.get("commit"),
                "base_ref": meta.get("base_ref") or None,
                "goal_id": meta.get("goal_id") or None,
                "goal_spec": meta.get("goal_spec") or None,
            },
            "evidence": evidence,
        }

    stderr_lines = split_lines(stderr_tail, max_lines=80)
    stdout_lines = split_lines(stdout_tail, max_lines=80)
    player_lines = split_lines(player_tail, max_lines=120)

    proof_lines = extract_proof_lines(player_tail) or extract_proof_lines(stderr_tail)
    raw_signature = watchdog.get("raw_signature_string", "")
    headline = pick_headline(stderr_lines, raw_signature, meta.get("exit_reason"))

    drain3_state = INTEL_ROOT / "state" / "drain3_state.json"
    miner = init_drain3(drain3_state)
    template_ids, template_texts = drain3_templates(
        miner, stderr_lines + stdout_lines + player_lines
    )

    embed_text = " | ".join(
        [
            meta.get("exit_reason", ""),
            headline,
            meta.get("failure_signature", ""),
            " ".join(proof_lines[:3]),
            " ".join(template_texts[:3]),
        ]
    ).strip()

    record = {
        "record_id": meta.get("job_id") or Path(result_zip).stem,
        "created_utc": utc_now(),
        "result_zip": str(result_zip),
        "meta": {
            "job_id": meta.get("job_id"),
            "build_id": meta.get("build_id"),
            "commit": meta.get("commit"),
            "scenario_id": meta.get("scenario_id"),
            "seed": meta.get("seed"),
            "exit_reason": meta.get("exit_reason"),
            "exit_code": meta.get("exit_code"),
            "failure_signature": meta.get("failure_signature"),
            "goal_id": meta.get("goal_id"),
            "goal_spec": meta.get("goal_spec"),
            "base_ref": meta.get("base_ref"),
            "required_bank": meta.get("required_bank"),
            "repo_dirty_post": meta.get("repo_dirty_post"),
            "manifest_drift": meta.get("manifest_drift"),
            "repo_status_pre": meta.get("repo_status_pre"),
            "repo_status_post": meta.get("repo_status_post"),
            "original_exit_reason": meta.get("original_exit_reason"),
            "original_exit_code": meta.get("original_exit_code"),
            "artifact_paths": artifact_paths,
        },
        "headline": headline,
        "raw_signature_string": raw_signature,
        "stdout_tail": stdout_lines[-20:],
        "stderr_tail": stderr_lines[-20:],
        "proof_lines": proof_lines,
        "template_ids": template_ids,
        "template_texts": template_texts[:10],
        "metrics": {
            "determinism_hash": run_summary.get("determinism_hash"),
            "failing_invariants": run_summary.get("failing_invariants"),
            "telemetry_bytes": run_summary.get("telemetry_bytes"),
            "perf": run_summary.get("perf"),
            "grade": score.get("grade"),
            "total_loss": score.get("total_loss"),
        },
        "validity": validity,
        "questions": questions_summary,
        "bank": bank_info,
        "embed_text": embed_text,
    }
    return record


def rebuild_runs_index(model, records_path, index_path, meta_path):
    if not model:
        return None
    np = lazy_import_numpy()
    if np is None:
        return None
    if not Path(records_path).exists():
        return None
    records = []
    with Path(records_path).open("r", encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            records.append(json.loads(line))

    texts = []
    meta_entries = []
    for record in records:
        embed_text = record.get("embed_text", "")
        if not embed_text:
            continue
        texts.append(embed_text)
        meta_entries.append(
            {
                "record_id": record.get("record_id"),
                "job_id": record.get("meta", {}).get("job_id"),
                "failure_signature": record.get("meta", {}).get("failure_signature"),
                "exit_reason": record.get("meta", {}).get("exit_reason"),
                "headline": record.get("headline"),
                "result_zip": record.get("result_zip"),
            }
        )

    embeddings = embed_texts(model, texts)
    if embeddings is None:
        return None
    embeddings = np.asarray(embeddings, dtype="float32")
    index = create_faiss_index(embeddings.shape[1])
    if index is None:
        return None
    index.add(embeddings)
    save_faiss_index(index, index_path)
    meta_path.write_text("", encoding="utf-8")
    for entry in meta_entries:
        append_jsonl(meta_path, entry)
    return index


def update_runs_index(record, model):
    index_path = INTEL_ROOT / "state" / "runs.faiss"
    meta_path = INTEL_ROOT / "state" / "runs_meta.jsonl"
    records_path = INTEL_ROOT / "store" / "records.jsonl"
    index = load_faiss_index(index_path)
    if index is None:
        index = rebuild_runs_index(model, records_path, index_path, meta_path)
        return index

    if not record.get("embed_text"):
        return index

    np = lazy_import_numpy()
    if np is None:
        return index
    embedding = embed_texts(model, [record["embed_text"]])
    if embedding is None:
        return index
    embedding = np.asarray(embedding, dtype="float32")
    index.add(embedding)
    save_faiss_index(index, index_path)
    append_jsonl(
        meta_path,
        {
            "record_id": record.get("record_id"),
            "job_id": record.get("meta", {}).get("job_id"),
            "failure_signature": record.get("meta", {}).get("failure_signature"),
            "exit_reason": record.get("meta", {}).get("exit_reason"),
            "headline": record.get("headline"),
            "result_zip": record.get("result_zip"),
        },
    )
    return index


def build_explain(record):
    ensure_layout()
    model = load_embedding_model()
    embed = None
    if model and record.get("embed_text"):
        embed = embed_texts(model, [record["embed_text"]])
    np = lazy_import_numpy()
    if embed is not None and np is not None:
        embed = np.asarray(embed, dtype="float32")

    runs_index = load_faiss_index(INTEL_ROOT / "state" / "runs.faiss")
    ledger_index = load_faiss_index(INTEL_ROOT / "state" / "ledger.faiss")
    similar_runs = []
    similar_ledger = []

    if embed is not None:
        similar_runs = search_index(
            runs_index, embed, INTEL_ROOT / "state" / "runs_meta.jsonl", top_k=5
        )
        similar_runs = [
            run
            for run in similar_runs
            if run.get("job_id") != record.get("meta", {}).get("job_id")
        ]
        similar_ledger = search_index(
            ledger_index, embed, INTEL_ROOT / "state" / "ledger_meta.jsonl", top_k=3
        )

    suggested_fix = None
    suggested_prevention = None
    if similar_ledger:
        top = similar_ledger[0]
        if top.get("score", 0.0) >= 0.6:
            suggested_fix = top.get("fix")
            suggested_prevention = top.get("prevention")

    explain = {
        "job_id": record.get("meta", {}).get("job_id"),
        "build_id": record.get("meta", {}).get("build_id"),
        "goal_id": record.get("meta", {}).get("goal_id"),
        "exit_reason": record.get("meta", {}).get("exit_reason"),
        "exit_code": record.get("meta", {}).get("exit_code"),
        "failure_signature": record.get("meta", {}).get("failure_signature"),
        "headline": record.get("headline"),
        "similar_runs": similar_runs,
        "similar_ledger": similar_ledger,
        "suggested_fix": suggested_fix,
        "suggested_prevention": suggested_prevention,
    }

    signals = record.get("signals")
    if isinstance(signals, dict) and signals:
        explain["signals"] = signals

    validity = record.get("validity")
    if isinstance(validity, dict):
        explain["validity"] = validity
        invalid_reasons = validity.get("invalid_reasons") or []
        missing_evidence = {
            "meta_missing",
            "watchdog_missing",
            "run_summary_missing",
            "telemetry_summary_missing",
            "telemetry_event_total_missing_or_zero",
            "invariants_missing",
        }
        primary_issue = None
        for reason in invalid_reasons:
            if reason in missing_evidence:
                primary_issue = reason
                break
        if primary_issue:
            explain["primary_evidence_issue"] = primary_issue
            explain["headline"] = f"EVIDENCE_INVALID:{primary_issue}"
    questions = record.get("questions")
    if isinstance(questions, dict):
        explain["questions"] = questions
    bank = record.get("bank")
    if isinstance(bank, dict):
        explain["bank"] = bank

    reports_dir = Path("/mnt/c/polish/queue/reports/intel")
    reports_dir.mkdir(parents=True, exist_ok=True)

    # Avoid collisions between run-result explains and diag explains (both can share the same job_id).
    file_id = None
    if record.get("diag_dir"):
        file_id = record.get("record_id")
    if not file_id:
        file_id = record.get("meta", {}).get("job_id") or record.get("record_id")

    explain_path = reports_dir / f"explain_{file_id}.json"
    write_json(explain_path, explain)
    if isinstance(questions, dict):
        questions_path = reports_dir / f"questions_{file_id}.json"
        write_json(questions_path, questions)
    return explain_path


def ingest_result_zip(result_zip):
    ensure_layout()
    processed = load_processed_state()
    key = file_key(result_zip)
    if key in processed:
        return None

    record = build_record_from_zip(result_zip)
    append_jsonl(INTEL_ROOT / "store" / "records.jsonl", record)

    model = load_embedding_model()
    update_runs_index(record, model)
    explain_path = build_explain(record)

    processed[key] = {"processed_utc": utc_now(), "result_zip": str(result_zip)}
    save_processed_state(processed)
    return explain_path


def ingest_diag_dir(diag_dir):
    ensure_layout()
    processed = load_processed_state()

    diag_dir = Path(diag_dir)
    smoke_path = diag_dir / "pipeline_smoke_summary_latest.md"
    key_basis = smoke_path if smoke_path.exists() else diag_dir
    key = "diag|" + file_key(key_basis)
    if key in processed:
        return None

    record = build_record_from_diag_dir(diag_dir)
    append_jsonl(INTEL_ROOT / "store" / "records.jsonl", record)

    model = load_embedding_model()
    update_runs_index(record, model)
    explain_path = build_explain(record)

    processed[key] = {"processed_utc": utc_now(), "diag_dir": str(diag_dir)}
    save_processed_state(processed)
    return explain_path


def ingest_diag_dir_cli(args):
    explain_path = ingest_diag_dir(args.diag_dir)
    if explain_path:
        print(f"explain: {explain_path}")
    else:
        print("already_processed")


def ingest_result_zip_cli(args):
    explain_path = ingest_result_zip(args.result_zip)
    if explain_path:
        print(f"explain: {explain_path}")
    else:
        print("already_processed")


def daemon(args):
    ensure_layout()
    last_ledger_mtime = None
    ledger_refresh_deadline = time.time()
    results_dir = Path(args.results_dir)
    diag_root = Path(args.diag_root) if getattr(args, "diag_root", None) else None

    while True:
        try:
            if LEDGER_PATH.exists():
                mtime = LEDGER_PATH.stat().st_mtime
                if last_ledger_mtime is None or mtime != last_ledger_mtime:
                    ingest_ledger()
                    last_ledger_mtime = mtime
            if time.time() >= ledger_refresh_deadline:
                ingest_ledger()
                ledger_refresh_deadline = time.time() + 300
        except Exception:
            pass

        for result_zip in sorted(results_dir.glob("result_*.zip")):
            if result_zip.name.endswith(".tmp"):
                continue
            try:
                ingest_result_zip(result_zip)
            except Exception:
                continue

        if diag_root and diag_root.exists():
            # Default layout on Windows: <diag_root>/<run_id>/buildbox_diag_<title>_<run_id>/...
            for diag_dir in sorted(diag_root.glob("*/buildbox_diag_*")):
                try:
                    ingest_diag_dir(diag_dir)
                except Exception:
                    continue

        time.sleep(args.poll_sec)


def choose_goal(args):
    ensure_layout()
    plan = read_json(args.plan) or {}
    candidates = []
    if isinstance(plan.get("concept_goals"), list):
        candidates = plan.get("concept_goals")
    elif isinstance(plan.get("goals"), list):
        candidates = plan.get("goals")
    elif plan.get("concept_goal"):
        candidates = [plan.get("concept_goal")]
    elif plan.get("goal"):
        candidates = [plan.get("goal")]

    chosen = candidates[0] if candidates else plan.get("concept", "default")
    cursor_path = INTEL_ROOT / "state" / "goal_cursor.json"
    cursor = read_json(cursor_path) or {"index": 0}
    if candidates:
        idx = cursor.get("index", 0) % len(candidates)
        chosen = candidates[idx]
        cursor["index"] = idx + 1
        write_json(cursor_path, cursor)

    output = {
        "chosen_goal": chosen,
        "why": "mvp_rotation" if candidates else "mvp_default",
        "timestamp_utc": utc_now(),
    }
    write_json(args.out, output)

    append_jsonl(
        INTEL_ROOT / "store" / "actions.jsonl",
        {
            "action_id": f"{utc_now()}_{Path(args.out).stem}",
            "timestamp_utc": utc_now(),
            "chosen_goal": chosen,
            "source_plan": args.plan,
        },
    )
    print(args.out)


def log_reward(args):
    ensure_layout()
    cycle = read_json(args.cycle_json) or {}
    exit_code = cycle.get("exit_code")
    exit_reason = str(cycle.get("exit_reason", "")).upper()
    failure_signature = cycle.get("failure_signature")
    proof = cycle.get("proof") or cycle.get("evidence") or cycle.get("proof_lines")
    new_signature = (
        cycle.get("failure_signature_new")
        or cycle.get("is_new_signature")
        or cycle.get("new_failure_signature")
    )

    reward = 0.0
    if proof:
        reward += 1.0
    if exit_code == 0:
        reward += 0.2
    if "INFRA_FAIL" in exit_reason or "CRASH" in exit_reason or "HANG_TIMEOUT" in exit_reason:
        reward -= 1.0
    if new_signature:
        reward -= 0.3

    append_jsonl(
        INTEL_ROOT / "store" / "rewards.jsonl",
        {
            "timestamp_utc": utc_now(),
            "cycle_json": args.cycle_json,
            "exit_code": exit_code,
            "exit_reason": exit_reason,
            "failure_signature": failure_signature,
            "reward": reward,
        },
    )
    print(f"reward={reward:.2f}")


def main():
    parser = argparse.ArgumentParser(description="Anviloop Intel Sidecar")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("ingest-ledger", help="Parse ERR ledger and build index")

    ingest_zip = sub.add_parser("ingest-result-zip", help="Ingest a result zip")
    ingest_zip.add_argument("--result-zip", required=True)

    ingest_diag = sub.add_parser("ingest-diag-dir", help="Ingest a buildbox diagnostics directory")
    ingest_diag.add_argument("--diag-dir", required=True)

    daemon_cmd = sub.add_parser("daemon", help="Watch results directory")
    daemon_cmd.add_argument("--results-dir", required=True)
    daemon_cmd.add_argument("--poll-sec", type=int, default=2)
    daemon_cmd.add_argument("--diag-root", required=False, help="Optional: also watch a buildbox diag root (e.g. /mnt/c/polish/queue/reports/_diag_downloads)")

    choose = sub.add_parser("choose-goal", help="Choose goal (MVP)")
    choose.add_argument("--plan", required=True)
    choose.add_argument("--out", required=True)

    reward_cmd = sub.add_parser("log-reward", help="Log reward from cycle JSON")
    reward_cmd.add_argument("--cycle-json", required=True)

    args = parser.parse_args()

    if args.command == "ingest-ledger":
        ingest_ledger()
        return
    if args.command == "ingest-result-zip":
        ingest_result_zip_cli(args)
        return
    if args.command == "ingest-diag-dir":
        ingest_diag_dir_cli(args)
        return
    if args.command == "daemon":
        daemon(args)
        return
    if args.command == "choose-goal":
        choose_goal(args)
        return
    if args.command == "log-reward":
        log_reward(args)
        return


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
