#!/usr/bin/env python3
"""Generate a human-readable demo report from headless run artifacts."""

from __future__ import annotations

import argparse
import datetime
import html
import json
import os
import re
import sys
import zipfile
from dataclasses import dataclass, field
from typing import Any, Dict, Iterable, List, Optional, Tuple


QUESTION_PASS = "PASS"
QUESTION_FAIL = "FAIL"
QUESTION_UNKNOWN = "UNKNOWN"


@dataclass
class QuestionEntry:
    question_id: str
    status: str
    required: bool
    answer: str
    unknown_reason: str


@dataclass
class RunRecord:
    run_id: str
    timestamp: str
    scenario_or_task: str
    run_status: str
    source_type: str
    source_path: str
    artifact_paths: Dict[str, str] = field(default_factory=dict)
    questions: List[QuestionEntry] = field(default_factory=list)
    metrics: Dict[str, float] = field(default_factory=dict)
    determinism_hash: str = ""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Package headless runs into a demo report")
    parser.add_argument("--results_dir", required=True, help="Folder containing result zips and/or extracted run folders")
    parser.add_argument("--out_md", default="demo_report.md", help="Output markdown path (default: demo_report.md in results_dir)")
    parser.add_argument("--write_html", action="store_true", help="Also write a minimal HTML report")
    parser.add_argument("--out_html", default="demo_report.html", help="Output html path (default: demo_report.html in results_dir)")
    return parser.parse_args()


def safe_load_json_file(path: str) -> Optional[Dict[str, Any]]:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return None


def safe_load_json_zip(zip_handle: zipfile.ZipFile, member: str) -> Optional[Dict[str, Any]]:
    try:
        with zip_handle.open(member, "r") as handle:
            return json.loads(handle.read().decode("utf-8", errors="replace"))
    except Exception:
        return None


def normalize_status(raw_status: Any) -> str:
    value = str(raw_status or "").strip().lower()
    if value == "pass":
        return QUESTION_PASS
    if value == "fail":
        return QUESTION_FAIL
    return QUESTION_UNKNOWN


def parse_questions(payload: Optional[Dict[str, Any]]) -> List[QuestionEntry]:
    if not payload:
        return []

    questions = payload.get("questions")
    if not isinstance(questions, list):
        return []

    parsed: List[QuestionEntry] = []
    for item in questions:
        if not isinstance(item, dict):
            continue

        parsed.append(
            QuestionEntry(
                question_id=str(item.get("id") or "unknown.question"),
                status=normalize_status(item.get("status")),
                required=bool(item.get("required", False)),
                answer=str(item.get("answer") or ""),
                unknown_reason=str(item.get("unknownReason") or item.get("unknown_reason") or ""),
            )
        )

    parsed.sort(key=lambda question: question.question_id.lower())
    return parsed


def merge_numeric_metrics(target: Dict[str, float], payload: Optional[Dict[str, Any]]) -> None:
    if not payload or not isinstance(payload, dict):
        return

    for key, value in payload.items():
        if isinstance(value, bool):
            continue
        if isinstance(value, (int, float)):
            target[str(key)] = float(value)


def merge_question_metrics(target: Dict[str, float], payload: Optional[Dict[str, Any]]) -> None:
    if not payload:
        return
    questions = payload.get("questions")
    if not isinstance(questions, list):
        return

    for item in questions:
        if not isinstance(item, dict):
            continue
        metrics = item.get("metrics")
        if not isinstance(metrics, dict):
            continue
        merge_numeric_metrics(target, metrics)


def parse_dt(value: Any) -> Optional[datetime.datetime]:
    if not value:
        return None
    text = str(value).strip()
    if not text:
        return None
    try:
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        return datetime.datetime.fromisoformat(text)
    except Exception:
        return None


def parse_timestamp_from_name(name: str) -> Optional[str]:
    match = re.search(r"(20\d{6}_\d{6})", name)
    if not match:
        return None

    token = match.group(1)
    try:
        parsed = datetime.datetime.strptime(token, "%Y%m%d_%H%M%S")
        return parsed.replace(tzinfo=datetime.timezone.utc).isoformat().replace("+00:00", "Z")
    except Exception:
        return None


def pick_timestamp(
    meta: Optional[Dict[str, Any]],
    run_summary: Optional[Dict[str, Any]],
    result_payload: Optional[Dict[str, Any]],
    fallback_name: str,
) -> str:
    for payload in (meta, run_summary, result_payload):
        if not payload:
            continue
        for key in ("start_utc", "end_utc", "timestamp", "started_utc", "completed_utc"):
            dt = parse_dt(payload.get(key))
            if dt:
                return dt.astimezone(datetime.timezone.utc).isoformat().replace("+00:00", "Z")

    parsed = parse_timestamp_from_name(fallback_name)
    if parsed:
        return parsed

    return "unknown"


def first_non_empty(values: Iterable[Optional[str]]) -> str:
    for value in values:
        if value:
            text = str(value).strip()
            if text:
                return text
    return "unknown"


def infer_run_root(file_path: str, file_name: str) -> str:
    parent = os.path.dirname(file_path)
    lower_name = file_name.lower()
    if lower_name in ("run_summary.json", "operator_report.json", "headless_answers.json", "result.json") and os.path.basename(parent).lower() == "out":
        return os.path.dirname(parent)
    return parent


def find_file(root: str, candidates: Iterable[str]) -> Optional[str]:
    for relative in candidates:
        path = os.path.join(root, relative)
        if os.path.isfile(path):
            return path
    return None


def extract_zip_json(zip_handle: zipfile.ZipFile, basename: str) -> Tuple[Optional[str], Optional[Dict[str, Any]]]:
    members = [member for member in zip_handle.namelist() if member.lower().endswith(basename.lower())]
    if not members:
        return None, None

    members.sort(key=lambda member: (member.count("/"), len(member), member.lower()))
    selected = members[0]
    return selected, safe_load_json_zip(zip_handle, selected)


def resolve_run_status(
    run_summary: Optional[Dict[str, Any]],
    result_payload: Optional[Dict[str, Any]],
    meta: Optional[Dict[str, Any]],
) -> str:
    for payload in (run_summary, result_payload, meta):
        if not payload:
            continue
        for key in ("exit_reason", "status", "result"):
            value = payload.get(key)
            if value:
                return str(value)
    return "unknown"


def build_run_from_folder(root: str) -> Optional[RunRecord]:
    meta_path = find_file(root, ("meta.json",))
    result_path = find_file(root, ("result.json", os.path.join("out", "result.json")))
    run_summary_path = find_file(root, ("run_summary.json", os.path.join("out", "run_summary.json")))
    answers_path = find_file(root, ("headless_answers.json", os.path.join("out", "headless_answers.json")))
    operator_path = find_file(root, ("operator_report.json", os.path.join("out", "operator_report.json")))

    if not any((meta_path, result_path, run_summary_path, answers_path, operator_path)):
        return None

    meta = safe_load_json_file(meta_path) if meta_path else None
    result_payload = safe_load_json_file(result_path) if result_path else None
    run_summary = safe_load_json_file(run_summary_path) if run_summary_path else None
    answers = safe_load_json_file(answers_path) if answers_path else None
    operator = safe_load_json_file(operator_path) if operator_path else None

    run_id = first_non_empty(
        (
            run_summary.get("job_id") if run_summary else None,
            meta.get("job_id") if meta else None,
            result_payload.get("run_id") if result_payload else None,
            os.path.basename(root),
        )
    )

    scenario_or_task = first_non_empty(
        (
            run_summary.get("scenario_id") if run_summary else None,
            meta.get("scenario_id") if meta else None,
            operator.get("scenarioId") if operator else None,
            answers.get("scenarioId") if answers else None,
            result_payload.get("scenario_id") if result_payload else None,
            result_payload.get("task_name") if result_payload else None,
            os.path.basename(root),
        )
    )

    timestamp = pick_timestamp(meta, run_summary, result_payload, os.path.basename(root))
    run_status = resolve_run_status(run_summary, result_payload, meta)

    questions = parse_questions(answers) if answers else parse_questions(operator)

    metrics: Dict[str, float] = {}
    merge_numeric_metrics(metrics, operator.get("summary") if operator else None)
    merge_numeric_metrics(metrics, run_summary.get("metrics") if run_summary else None)
    merge_numeric_metrics(metrics, result_payload.get("metrics") if result_payload else None)
    merge_question_metrics(metrics, operator)
    merge_question_metrics(metrics, answers)

    artifact_paths: Dict[str, str] = {"run_root": root}
    if meta_path:
        artifact_paths["meta.json"] = meta_path
    if result_path:
        artifact_paths["result.json"] = result_path
    if run_summary_path:
        artifact_paths["run_summary.json"] = run_summary_path
    if operator_path:
        artifact_paths["operator_report.json"] = operator_path
    if answers_path:
        artifact_paths["headless_answers.json"] = answers_path

    return RunRecord(
        run_id=run_id,
        timestamp=timestamp,
        scenario_or_task=scenario_or_task,
        run_status=run_status,
        source_type="folder",
        source_path=root,
        artifact_paths=artifact_paths,
        questions=questions,
        metrics=metrics,
        determinism_hash=str(run_summary.get("determinism_hash") or "") if run_summary else "",
    )


def build_run_from_zip(zip_path: str) -> Optional[RunRecord]:
    try:
        with zipfile.ZipFile(zip_path, "r") as zip_handle:
            meta_member, meta = extract_zip_json(zip_handle, "meta.json")
            result_member, result_payload = extract_zip_json(zip_handle, "result.json")
            run_summary_member, run_summary = extract_zip_json(zip_handle, "run_summary.json")
            answers_member, answers = extract_zip_json(zip_handle, "headless_answers.json")
            operator_member, operator = extract_zip_json(zip_handle, "operator_report.json")
    except Exception:
        return None

    if not any((meta, result_payload, run_summary, answers, operator)):
        return None

    run_id = first_non_empty(
        (
            run_summary.get("job_id") if run_summary else None,
            meta.get("job_id") if meta else None,
            result_payload.get("run_id") if result_payload else None,
            os.path.basename(zip_path),
        )
    )

    scenario_or_task = first_non_empty(
        (
            run_summary.get("scenario_id") if run_summary else None,
            meta.get("scenario_id") if meta else None,
            operator.get("scenarioId") if operator else None,
            answers.get("scenarioId") if answers else None,
            result_payload.get("scenario_id") if result_payload else None,
            result_payload.get("task_name") if result_payload else None,
            os.path.basename(zip_path),
        )
    )

    timestamp = pick_timestamp(meta, run_summary, result_payload, os.path.basename(zip_path))
    run_status = resolve_run_status(run_summary, result_payload, meta)

    questions = parse_questions(answers) if answers else parse_questions(operator)

    metrics: Dict[str, float] = {}
    merge_numeric_metrics(metrics, operator.get("summary") if operator else None)
    merge_numeric_metrics(metrics, run_summary.get("metrics") if run_summary else None)
    merge_numeric_metrics(metrics, result_payload.get("metrics") if result_payload else None)
    merge_question_metrics(metrics, operator)
    merge_question_metrics(metrics, answers)

    artifact_paths: Dict[str, str] = {"zip": zip_path}
    if meta_member:
        artifact_paths["meta.json"] = f"{zip_path}::{meta_member}"
    if result_member:
        artifact_paths["result.json"] = f"{zip_path}::{result_member}"
    if run_summary_member:
        artifact_paths["run_summary.json"] = f"{zip_path}::{run_summary_member}"
    if operator_member:
        artifact_paths["operator_report.json"] = f"{zip_path}::{operator_member}"
    if answers_member:
        artifact_paths["headless_answers.json"] = f"{zip_path}::{answers_member}"

    return RunRecord(
        run_id=run_id,
        timestamp=timestamp,
        scenario_or_task=scenario_or_task,
        run_status=run_status,
        source_type="zip",
        source_path=zip_path,
        artifact_paths=artifact_paths,
        questions=questions,
        metrics=metrics,
        determinism_hash=str(run_summary.get("determinism_hash") or "") if run_summary else "",
    )


def discover_run_folders(results_dir: str) -> List[str]:
    roots: set[str] = set()
    interesting = {"meta.json", "result.json", "run_summary.json", "operator_report.json", "headless_answers.json"}

    for walk_root, _, files in os.walk(results_dir):
        for file_name in files:
            if file_name.lower() not in interesting:
                continue
            roots.add(infer_run_root(os.path.join(walk_root, file_name), file_name))

    return sorted(roots)


def discover_runs(results_dir: str) -> List[RunRecord]:
    records: List[RunRecord] = []

    for folder in discover_run_folders(results_dir):
        record = build_run_from_folder(folder)
        if record:
            records.append(record)

    for walk_root, _, files in os.walk(results_dir):
        for file_name in files:
            if not file_name.lower().endswith(".zip"):
                continue
            zip_path = os.path.join(walk_root, file_name)
            record = build_run_from_zip(zip_path)
            if record:
                records.append(record)

    deduped: Dict[str, RunRecord] = {}
    for record in records:
        key = f"{record.run_id}|{record.scenario_or_task}|{record.timestamp}"
        existing = deduped.get(key)
        if not existing:
            deduped[key] = record
            continue
        if existing.source_type == "zip" and record.source_type == "folder":
            deduped[key] = record

    ordered = list(deduped.values())

    def sort_key(item: RunRecord) -> Tuple[int, str]:
        dt_value = parse_dt(item.timestamp)
        if dt_value:
            return (0, dt_value.isoformat())
        return (1, item.timestamp)

    ordered.sort(key=sort_key, reverse=True)
    return ordered


def fmt_float(value: float) -> str:
    text = f"{value:.6f}".rstrip("0").rstrip(".")
    return text if text else "0"


def get_metric(metrics: Dict[str, float], key: str) -> Optional[float]:
    if key in metrics:
        return metrics[key]
    target = key.lower()
    for candidate, value in metrics.items():
        if candidate.lower() == target:
            return value
    return None


def collect_digests(record: RunRecord) -> List[Tuple[str, str]]:
    rows: List[Tuple[str, str]] = []
    if record.determinism_hash:
        rows.append(("run_summary.determinism_hash", record.determinism_hash))

    for key in sorted(record.metrics.keys(), key=lambda x: x.lower()):
        if "digest" not in key.lower():
            continue
        rows.append((key, fmt_float(record.metrics[key])))

    return rows


def collect_profilebias_summary(metrics: Dict[str, float]) -> List[Tuple[str, str]]:
    a_range = get_metric(metrics, "space4x.battle.profilebias.groupA.avg_range")
    b_range = get_metric(metrics, "space4x.battle.profilebias.groupB.avg_range")
    a_engage = get_metric(metrics, "space4x.battle.profilebias.groupA.engage_count")
    b_engage = get_metric(metrics, "space4x.battle.profilebias.groupB.engage_count")

    if all(value is None for value in (a_range, b_range, a_engage, b_engage)):
        return []

    rows: List[Tuple[str, str]] = []
    if a_range is not None:
        rows.append(("groupA.avg_range", fmt_float(a_range)))
    if b_range is not None:
        rows.append(("groupB.avg_range", fmt_float(b_range)))
    if a_range is not None and b_range is not None:
        rows.append(("delta.avg_range(groupA-groupB)", fmt_float(a_range - b_range)))

    if a_engage is not None:
        rows.append(("groupA.engage_count", fmt_float(a_engage)))
    if b_engage is not None:
        rows.append(("groupB.engage_count", fmt_float(b_engage)))
    if a_engage is not None and b_engage is not None:
        rows.append(("delta.engage_count(groupA-groupB)", fmt_float(a_engage - b_engage)))

    return rows


def collect_module_pipeline_summary(metrics: Dict[str, float]) -> List[Tuple[str, str]]:
    keys = [
        "modules.avg_limb_quality.cooling",
        "modules.avg_limb_quality.power",
        "modules.avg_limb_quality.optics",
        "modules.avg_limb_quality.mount",
        "modules.avg_limb_quality.firmware",
        "modules.avg_integration_quality",
        "modules.avg_install_quality",
    ]

    rows: List[Tuple[str, str]] = []
    for key in keys:
        value = get_metric(metrics, key)
        if value is not None:
            rows.append((key, fmt_float(value)))
    return rows


def render_markdown(runs: List[RunRecord], results_dir: str) -> str:
    now_utc = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
    lines: List[str] = [
        "# Demo Report",
        "",
        f"- Generated: `{now_utc}`",
        f"- Results dir: `{results_dir}`",
        f"- Runs found: `{len(runs)}`",
    ]

    for index, run in enumerate(runs, start=1):
        lines.append("")
        lines.append(f"## {index}. {run.run_id}")
        lines.append(f"- Timestamp: `{run.timestamp}`")
        lines.append(f"- Scenario/Task: `{run.scenario_or_task}`")
        lines.append(f"- Run status: `{run.run_status}`")
        lines.append(f"- Source: `{run.source_type}`")
        lines.append(f"- Source path: `{run.source_path}`")

        lines.append("- Artifacts:")
        for key in sorted(run.artifact_paths.keys()):
            lines.append(f"  - `{key}`: `{run.artifact_paths[key]}`")

        lines.append("- Questions:")
        if run.questions:
            for question in run.questions:
                parts = [f"status={question.status}", f"required={str(question.required).lower()}"]
                if question.unknown_reason:
                    parts.append(f"unknownReason={question.unknown_reason}")
                if question.answer:
                    parts.append(f"answer={question.answer}")
                lines.append(f"  - `{question.question_id}`: " + "; ".join(parts))
        else:
            lines.append("  - none")

        digest_rows = collect_digests(run)
        profilebias_rows = collect_profilebias_summary(run.metrics)
        module_rows = collect_module_pipeline_summary(run.metrics)

        lines.append("- Key metrics:")
        if digest_rows:
            lines.append("  - Determinism:")
            for key, value in digest_rows:
                lines.append(f"    - `{key}` = `{value}`")
        else:
            lines.append("  - Determinism: none")

        if profilebias_rows:
            lines.append("  - Profilebias:")
            for key, value in profilebias_rows:
                lines.append(f"    - `{key}` = `{value}`")
        else:
            lines.append("  - Profilebias: none")

        if module_rows:
            lines.append("  - Module pipeline qualities:")
            for key, value in module_rows:
                lines.append(f"    - `{key}` = `{value}`")
        else:
            lines.append("  - Module pipeline qualities: none")

    lines.append("")
    return "\n".join(lines)


def render_html_from_markdown(markdown_text: str) -> str:
    escaped = html.escape(markdown_text)
    return (
        "<!doctype html>\n"
        "<html><head><meta charset=\"utf-8\"><title>Demo Report</title>"
        "<style>body{font-family:Segoe UI,Arial,sans-serif;padding:16px;}pre{white-space:pre-wrap;}</style>"
        "</head><body><pre>"
        + escaped
        + "</pre></body></html>\n"
    )


def resolve_output_path(results_dir: str, value: str) -> str:
    return value if os.path.isabs(value) else os.path.join(results_dir, value)


def main() -> int:
    args = parse_args()
    results_dir = os.path.abspath(args.results_dir)

    if not os.path.isdir(results_dir):
        print(f"results_dir does not exist or is not a directory: {results_dir}", file=sys.stderr)
        return 2

    runs = discover_runs(results_dir)
    markdown = render_markdown(runs, results_dir)

    md_path = resolve_output_path(results_dir, args.out_md)
    os.makedirs(os.path.dirname(md_path), exist_ok=True)
    with open(md_path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(markdown)

    print(f"Wrote markdown report: {md_path}")

    if args.write_html:
        html_path = resolve_output_path(results_dir, args.out_html)
        os.makedirs(os.path.dirname(html_path), exist_ok=True)
        with open(html_path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(render_html_from_markdown(markdown))
        print(f"Wrote html report: {html_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
