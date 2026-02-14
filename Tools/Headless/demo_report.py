#!/usr/bin/env python3
import argparse
import datetime as dt
import html
import json
import re
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple


INDICATOR_FILES = ("headless_answers.json", "result.json", "operator_report.json")


@dataclass
class QuestionEntry:
    question_id: str
    status: str
    required: bool
    unknown_reason: str
    answer: str
    metrics: Dict[str, float] = field(default_factory=dict)


@dataclass
class RunRecord:
    source_type: str
    source_path: Path
    timestamp: str
    task_name: str
    scenario_name: str
    status: str
    required_pass: int
    required_fail: int
    required_unknown: int
    zip_path: str
    answers_path: str
    result_path: str
    operator_report_path: str
    questions: List[QuestionEntry] = field(default_factory=list)
    metrics: Dict[str, float] = field(default_factory=dict)


def to_path_string(path: Optional[Path]) -> str:
    if path is None:
        return ""
    return str(path)


def parse_iso_timestamp(value: str) -> Optional[dt.datetime]:
    if not value:
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return dt.datetime.fromisoformat(text)
    except ValueError:
        return None


def format_timestamp(value: Optional[dt.datetime]) -> str:
    if value is None:
        return ""
    if value.tzinfo is None:
        return value.isoformat(timespec="seconds")
    return value.astimezone(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def guess_timestamp_from_name(text: str) -> Optional[dt.datetime]:
    patterns = [
        r"(20\d{2})[-_]?(\d{2})[-_]?(\d{2})[Tt _-]?(\d{2})[:_-]?(\d{2})[:_-]?(\d{2})",
        r"(20\d{2})[-_]?(\d{2})[-_]?(\d{2})",
    ]
    for pattern in patterns:
        m = re.search(pattern, text)
        if not m:
            continue
        groups = [int(x) for x in m.groups()]
        try:
            if len(groups) == 6:
                return dt.datetime(groups[0], groups[1], groups[2], groups[3], groups[4], groups[5], tzinfo=dt.timezone.utc)
            return dt.datetime(groups[0], groups[1], groups[2], tzinfo=dt.timezone.utc)
        except ValueError:
            continue
    return None


def load_json_file(path: Path) -> Optional[dict]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def load_json_from_zip(zf: zipfile.ZipFile, member: str) -> Optional[dict]:
    try:
        with zf.open(member) as handle:
            return json.loads(handle.read().decode("utf-8", errors="replace"))
    except Exception:
        return None


def numeric_metrics_from_dict(value: dict) -> Dict[str, float]:
    out: Dict[str, float] = {}
    if not isinstance(value, dict):
        return out
    for k, v in value.items():
        if isinstance(v, bool):
            continue
        if isinstance(v, (int, float)):
            out[str(k)] = float(v)
    return out


def extract_questions(answers_data: Optional[dict]) -> List[QuestionEntry]:
    if not isinstance(answers_data, dict):
        return []
    raw_questions = answers_data.get("questions")
    if not isinstance(raw_questions, list):
        return []
    questions: List[QuestionEntry] = []
    for item in raw_questions:
        if not isinstance(item, dict):
            continue
        qid = str(item.get("id", "")).strip()
        if not qid:
            continue
        status = str(item.get("status", "UNKNOWN")).upper()
        required = bool(item.get("required", False))
        unknown_reason = str(item.get("unknown_reason", "") or item.get("UnknownReason", "")).strip()
        answer = str(item.get("answer", "")).strip()
        metrics = numeric_metrics_from_dict(item.get("metrics"))
        questions.append(QuestionEntry(qid, status, required, unknown_reason, answer, metrics))
    return questions


def fold_metrics(questions: List[QuestionEntry], operator_report: Optional[dict]) -> Dict[str, float]:
    out: Dict[str, float] = {}

    if isinstance(operator_report, dict):
        summary = operator_report.get("summary")
        out.update(numeric_metrics_from_dict(summary))
        report_questions = operator_report.get("questions")
        if isinstance(report_questions, list):
            for rq in report_questions:
                if not isinstance(rq, dict):
                    continue
                qid = str(rq.get("id", "")).strip()
                for k, v in numeric_metrics_from_dict(rq.get("metrics")).items():
                    key = f"{qid}.{k}" if qid and "." not in k else k
                    out[key] = v

    for q in questions:
        for k, v in q.metrics.items():
            key = k if "." in k else f"{q.question_id}.{k}"
            out[key] = v
        if q.question_id == "space4x.q.modules.provenance_advantage" or q.question_id == "space4x.q.modules.reverse_engineer_surpass":
            if "orgA_avg_integration_quality" in q.metrics:
                out["modules.provenance.orgA.avg_integration_quality"] = q.metrics["orgA_avg_integration_quality"]
            if "orgB_avg_integration_quality" in q.metrics:
                out["modules.provenance.orgB.avg_integration_quality"] = q.metrics["orgB_avg_integration_quality"]
            if "integration_quality_delta" in q.metrics:
                out["modules.provenance.integration_quality_delta"] = q.metrics["integration_quality_delta"]
        if "avg_part_quality" in q.metrics:
            out["modules.avg_part_quality"] = q.metrics["avg_part_quality"]
        if "avg_module_quality" in q.metrics:
            out["modules.avg_module_quality"] = q.metrics["avg_module_quality"]
        if "avg_install_quality" in q.metrics:
            out["modules.avg_install_quality"] = q.metrics["avg_install_quality"]

    return out


def compute_required_status(questions: List[QuestionEntry]) -> Tuple[str, int, int, int]:
    required = [q for q in questions if q.required]
    if not required:
        return "UNKNOWN", 0, 0, 0
    passed = sum(1 for q in required if q.status == "PASS")
    failed = sum(1 for q in required if q.status == "FAIL")
    unknown = sum(1 for q in required if q.status not in ("PASS", "FAIL"))
    if failed > 0:
        return "FAIL", passed, failed, unknown
    if unknown > 0:
        return "UNKNOWN", passed, failed, unknown
    return "PASS", passed, failed, unknown


def discover_directory_runs(results_dir: Path) -> List[RunRecord]:
    run_roots: Dict[Path, None] = {}
    for indicator in INDICATOR_FILES:
        for p in results_dir.rglob(indicator):
            root = p.parent.parent if p.parent.name.lower() == "reports" else p.parent
            run_roots[root.resolve()] = None

    runs: List[RunRecord] = []
    for run_root in sorted(run_roots.keys()):
        result_file = next(iter(sorted(run_root.rglob("result.json"))), None)
        answers_file = next(iter(sorted(run_root.rglob("headless_answers.json"))), None)
        report_file = next(iter(sorted(run_root.rglob("operator_report.json"))), None)
        result_data = load_json_file(result_file) if result_file else None
        answers_data = load_json_file(answers_file) if answers_file else None
        report_data = load_json_file(report_file) if report_file else None
        run = build_run_record("dir", run_root, result_data, answers_data, report_data, "", to_path_string(answers_file), to_path_string(result_file), to_path_string(report_file))
        runs.append(run)
    return runs


def find_zip_member(zf: zipfile.ZipFile, file_name: str) -> Optional[str]:
    matches = [n for n in zf.namelist() if n.lower().endswith(file_name.lower())]
    if not matches:
        return None
    matches.sort(key=len)
    return matches[0]


def discover_zip_runs(results_dir: Path) -> List[RunRecord]:
    runs: List[RunRecord] = []
    for zip_path in sorted(results_dir.rglob("*.zip")):
        try:
            with zipfile.ZipFile(zip_path, "r") as zf:
                result_member = find_zip_member(zf, "result.json")
                answers_member = find_zip_member(zf, "headless_answers.json")
                report_member = find_zip_member(zf, "operator_report.json")
                result_data = load_json_from_zip(zf, result_member) if result_member else None
                answers_data = load_json_from_zip(zf, answers_member) if answers_member else None
                report_data = load_json_from_zip(zf, report_member) if report_member else None
                run = build_run_record("zip", zip_path, result_data, answers_data, report_data, str(zip_path), answers_member or "", result_member or "", report_member or "")
                runs.append(run)
        except zipfile.BadZipFile:
            continue
    return runs


def build_run_record(source_type: str, source_path: Path, result_data: Optional[dict], answers_data: Optional[dict], report_data: Optional[dict], zip_path: str, answers_path: str, result_path: str, operator_report_path: str) -> RunRecord:
    questions = extract_questions(answers_data)
    metrics = fold_metrics(questions, report_data)
    status, req_pass, req_fail, req_unknown = compute_required_status(questions)

    scenario_name = ""
    task_name = ""
    ts_dt: Optional[dt.datetime] = None
    if isinstance(result_data, dict):
        task_name = str(result_data.get("task_id", "")).strip()
        scenario_name = str(result_data.get("scenario_id", "") or result_data.get("scenario_used", "")).strip()
        ts_dt = parse_iso_timestamp(str(result_data.get("ended_utc", ""))) or parse_iso_timestamp(str(result_data.get("started_utc", "")))
    if not scenario_name and isinstance(answers_data, dict):
        scenario_name = str(answers_data.get("scenarioId", "")).strip()
    if not scenario_name and isinstance(report_data, dict):
        scenario_name = str(report_data.get("scenarioId", "")).strip()
    if not task_name and scenario_name:
        task_name = scenario_name

    if ts_dt is None:
        ts_dt = guess_timestamp_from_name(source_path.name)
    if ts_dt is None:
        ts_dt = dt.datetime.fromtimestamp(source_path.stat().st_mtime, tz=dt.timezone.utc)

    if not task_name:
        task_name = source_path.stem
    if not scenario_name:
        scenario_name = "unknown"

    return RunRecord(
        source_type=source_type,
        source_path=source_path,
        timestamp=format_timestamp(ts_dt),
        task_name=task_name,
        scenario_name=scenario_name,
        status=status,
        required_pass=req_pass,
        required_fail=req_fail,
        required_unknown=req_unknown,
        zip_path=zip_path,
        answers_path=answers_path,
        result_path=result_path,
        operator_report_path=operator_report_path,
        questions=questions,
        metrics=metrics,
    )


def collect_key_metric_lines(run: RunRecord) -> List[str]:
    lines: List[str] = []
    digest_items = sorted((k, v) for k, v in run.metrics.items() if "digest" in k.lower())
    if digest_items:
        lines.append("Determinism digests:")
        for k, v in digest_items:
            lines.append(f"- `{k}` = `{v:.6f}`")

    profilebias_items = sorted((k, v) for k, v in run.metrics.items() if "profilebias" in k.lower() and "delta" in k.lower())
    if profilebias_items:
        lines.append("Profilebias deltas:")
        for k, v in profilebias_items:
            lines.append(f"- `{k}` = `{v:.6f}`")

    module_keys = (
        "modules.avg_part_quality",
        "modules.avg_module_quality",
        "modules.avg_install_quality",
        "modules.provenance.orgA.avg_integration_quality",
        "modules.provenance.orgB.avg_integration_quality",
        "modules.provenance.integration_quality_delta",
    )
    found = [(k, run.metrics[k]) for k in module_keys if k in run.metrics]
    if found:
        lines.append("Module quality/provenance:")
        for k, v in found:
            lines.append(f"- `{k}` = `{v:.6f}`")

    return lines


def build_markdown(results_dir: Path, runs: List[RunRecord]) -> str:
    now = format_timestamp(dt.datetime.now(dt.timezone.utc))
    pass_count = sum(1 for r in runs if r.status == "PASS")
    fail_count = sum(1 for r in runs if r.status == "FAIL")
    unknown_count = sum(1 for r in runs if r.status == "UNKNOWN")

    lines: List[str] = []
    lines.append("# Headless Demo Report")
    lines.append(f"Generated: `{now}`")
    lines.append(f"Results directory: `{results_dir}`")
    lines.append("")
    lines.append("## Summary")
    lines.append(f"- Runs found: `{len(runs)}`")
    lines.append(f"- Required PASS: `{pass_count}`")
    lines.append(f"- Required FAIL: `{fail_count}`")
    lines.append(f"- Required UNKNOWN: `{unknown_count}`")
    lines.append("")
    lines.append("## Run Index")
    lines.append("| # | Timestamp | Task | Scenario | Required Status | Source |")
    lines.append("|---|---|---|---|---|---|")
    for i, run in enumerate(runs, start=1):
        lines.append(f"| {i} | {run.timestamp} | {run.task_name} | {run.scenario_name} | {run.status} | {run.source_path.name} |")

    for i, run in enumerate(runs, start=1):
        lines.append("")
        lines.append(f"## Run {i}: {run.task_name}")
        lines.append(f"- Timestamp: `{run.timestamp}`")
        lines.append(f"- Scenario: `{run.scenario_name}`")
        lines.append(f"- Required status: `{run.status}` (pass={run.required_pass}, fail={run.required_fail}, unknown={run.required_unknown})")
        if run.zip_path:
            lines.append(f"- Artifact zip: `{run.zip_path}`")
        lines.append(f"- Run path: `{run.source_path}`")
        lines.append(f"- headless_answers.json: `{run.answers_path or 'not found'}`")
        lines.append(f"- result.json: `{run.result_path or 'not found'}`")
        lines.append(f"- operator_report.json: `{run.operator_report_path or 'not found'}`")

        lines.append("")
        lines.append("### Questions")
        if not run.questions:
            lines.append("No headless questions found.")
        else:
            lines.append("| ID | Status | Required | UnknownReason |")
            lines.append("|---|---|---|---|")
            for q in run.questions:
                unknown_reason = q.unknown_reason if q.unknown_reason else ""
                lines.append(f"| {q.question_id} | {q.status} | {str(q.required).lower()} | {unknown_reason} |")

        metric_lines = collect_key_metric_lines(run)
        lines.append("")
        lines.append("### Key Metrics")
        if not metric_lines:
            lines.append("No key metrics found.")
        else:
            for item in metric_lines:
                lines.append(item)

    lines.append("")
    return "\n".join(lines)


def write_optional_html(markdown_text: str, html_output: Path) -> None:
    html_content = (
        "<!doctype html>\n"
        "<html><head><meta charset=\"utf-8\"><title>Headless Demo Report</title>"
        "<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;}pre{white-space:pre-wrap;word-wrap:break-word;}</style>"
        "</head><body>"
        "<h1>Headless Demo Report</h1>"
        "<pre>" + html.escape(markdown_text) + "</pre>"
        "</body></html>\n"
    )
    html_output.write_text(html_content, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Package headless run artifacts into a human-readable demo report.")
    parser.add_argument("--results_dir", required=True, help="Directory containing result zips and/or extracted run folders.")
    parser.add_argument("--output_md", default="", help="Output markdown path. Default: <results_dir>/demo_report.md")
    parser.add_argument("--html", action="store_true", help="Also emit demo_report.html")
    parser.add_argument("--output_html", default="", help="Output html path when --html is set. Default: <results_dir>/demo_report.html")
    args = parser.parse_args()

    results_dir = Path(args.results_dir).expanduser().resolve()
    if not results_dir.exists() or not results_dir.is_dir():
        raise SystemExit(f"--results_dir does not exist or is not a directory: {results_dir}")

    runs = discover_directory_runs(results_dir) + discover_zip_runs(results_dir)
    runs.sort(key=lambda r: (r.timestamp, r.task_name, r.scenario_name), reverse=True)

    markdown_text = build_markdown(results_dir, runs)
    md_output = Path(args.output_md).expanduser().resolve() if args.output_md else (results_dir / "demo_report.md")
    md_output.parent.mkdir(parents=True, exist_ok=True)
    md_output.write_text(markdown_text, encoding="utf-8")
    print(f"Wrote markdown report: {md_output}")

    if args.html:
        html_output = Path(args.output_html).expanduser().resolve() if args.output_html else (results_dir / "demo_report.html")
        html_output.parent.mkdir(parents=True, exist_ok=True)
        write_optional_html(markdown_text, html_output)
        print(f"Wrote html report: {html_output}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
