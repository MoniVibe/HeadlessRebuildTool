#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except Exception as exc:
        return None, str(exc)


def scan_scenarios(root):
    scenarios_dir = Path(root) / "Assets" / "Scenarios"
    if not scenarios_dir.exists():
        return []

    results = []
    for path in scenarios_dir.rglob("*.json"):
        if "Templates" in path.parts:
            continue
        if path.name.lower() in ("readme.json",):
            continue
        data, error = load_json(path)
        scenario_id = None
        if data:
            scenario_id = data.get("scenarioId") or data.get("scenario_id")
        results.append({
            "path": str(path),
            "scenarioId": scenario_id,
            "error": error,
        })

    return sorted(results, key=lambda item: (item["scenarioId"] or "", item["path"]))


def main():
    parser = argparse.ArgumentParser(description="List scenario JSON files and scenarioId values.")
    parser.add_argument("--root", default=".", help="Repo root (defaults to cwd)")
    parser.add_argument("--json", action="store_true", help="Output JSON")
    args = parser.parse_args()

    results = scan_scenarios(args.root)

    if args.json:
        print(json.dumps(results, indent=2))
        return

    if not results:
        print("No scenarios found.")
        return

    print(f"Found {len(results)} scenario files:\n")
    for item in results:
        scenario_id = item["scenarioId"] or "(missing scenarioId)"
        if item["error"]:
            scenario_id = f"(parse error: {item['error']})"
        print(f"- {scenario_id} :: {item['path']}")


if __name__ == "__main__":
    main()
