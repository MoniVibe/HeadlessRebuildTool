#!/usr/bin/env python3
import argparse
import json
import os
import re


QUESTION_ID_RE = re.compile(r"\"(space4x\\.q\\.[^\"]+)\"")


def load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def resolve_paths(repo_root, scenario_dir, registry_path):
    if scenario_dir:
        resolved_scenarios = scenario_dir
    else:
        candidates = [
            os.path.join(repo_root, "Assets", "Scenarios"),
            os.path.join(repo_root, "space4x", "Assets", "Scenarios")
        ]
        resolved_scenarios = next((p for p in candidates if os.path.isdir(p)), None)

    if registry_path:
        resolved_registry = registry_path
    else:
        candidates = [
            os.path.join(repo_root, "Assets", "Scripts", "Space4x", "Headless", "Space4XHeadlessQuestionRegistry.cs"),
            os.path.join(repo_root, "space4x", "Assets", "Scripts", "Space4x", "Headless", "Space4XHeadlessQuestionRegistry.cs")
        ]
        resolved_registry = next((p for p in candidates if os.path.isfile(p)), None)

    return resolved_scenarios, resolved_registry


def load_question_ids(registry_path, question_ids_path):
    if question_ids_path:
        data = load_json(question_ids_path)
        if isinstance(data, list):
            return set(str(item) for item in data)
        return set()
    if not registry_path:
        return set()
    with open(registry_path, "r", encoding="utf-8") as handle:
        contents = handle.read()
    return set(match.group(1) for match in QUESTION_ID_RE.finditer(contents))


def validate_scenario(path, question_ids):
    errors = []
    warnings = []
    try:
        data = load_json(path)
    except Exception as exc:
        return [f"{path}: invalid JSON ({exc})"], warnings

    for key in ("seed", "duration_s", "spawn"):
        if key not in data:
            errors.append(f"{path}: missing required field '{key}'")

    questions = []
    scenario_config = data.get("scenarioConfig") or {}
    if isinstance(scenario_config, dict):
        questions = scenario_config.get("headlessQuestions") or []

    seen = set()
    for idx, entry in enumerate(questions):
        if not isinstance(entry, dict):
            errors.append(f"{path}: headlessQuestions[{idx}] is not an object")
            continue
        qid = entry.get("id")
        required = entry.get("required")
        if not qid:
            errors.append(f"{path}: headlessQuestions[{idx}] missing id")
            continue
        if not isinstance(required, bool):
            errors.append(f"{path}: headlessQuestions[{idx}] missing required boolean")
        if qid in seen:
            errors.append(f"{path}: duplicate headless question id '{qid}'")
        seen.add(qid)
        if question_ids and qid not in question_ids:
            errors.append(f"{path}: unknown question id '{qid}'")

    meta_path = f"{path}.meta"
    if not os.path.isfile(meta_path):
        warnings.append(f"{path}: missing .meta file")

    return errors, warnings


def main():
    parser = argparse.ArgumentParser(description="Validate Space4X scenario JSONs and headless question packs.")
    parser.add_argument("--repo-root", default=os.getcwd(), help="Repo root (Tri or space4x).")
    parser.add_argument("--scenario-dir", default=None, help="Override scenario directory path.")
    parser.add_argument("--registry", default=None, help="Override question registry path.")
    parser.add_argument("--question-ids", default=None, help="JSON list of allowed question ids.")
    args = parser.parse_args()

    scenario_dir, registry_path = resolve_paths(args.repo_root, args.scenario_dir, args.registry)
    if not scenario_dir or not os.path.isdir(scenario_dir):
        raise SystemExit("Scenario directory not found. Use --scenario-dir or --repo-root.")

    question_ids = load_question_ids(registry_path, args.question_ids)

    errors = []
    warnings = []
    scenario_files = [
        os.path.join(scenario_dir, name)
        for name in os.listdir(scenario_dir)
        if name.lower().endswith(".json")
    ]

    for path in sorted(scenario_files):
        file_errors, file_warnings = validate_scenario(path, question_ids)
        errors.extend(file_errors)
        warnings.extend(file_warnings)

    print(f"Checked {len(scenario_files)} scenario files in {scenario_dir}")
    for entry in errors:
        print(f"ERROR: {entry}")
    for entry in warnings:
        print(f"WARN: {entry}")

    if errors:
        raise SystemExit(1)
    print("OK: no blocking errors detected.")


if __name__ == "__main__":
    main()
