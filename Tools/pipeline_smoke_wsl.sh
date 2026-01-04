#!/usr/bin/env bash
set -euo pipefail

resolve_tri_root() {
  local candidate
  candidate="/home/${USER}/Tri"
  if [ -d "$candidate" ] && [ -d "$candidate/godgame" ] && [ -d "$candidate/space4x" ] && [ -d "$candidate/puredots" ] && [ -d "$candidate/Tools" ]; then
    echo "$candidate"
    return 0
  fi
  candidate="/home/oni/Tri"
  if [ -d "$candidate" ] && [ -d "$candidate/godgame" ] && [ -d "$candidate/space4x" ] && [ -d "$candidate/puredots" ] && [ -d "$candidate/Tools" ]; then
    echo "$candidate"
    return 0
  fi
  return 1
}

TRI_ROOT="$(resolve_tri_root || true)"
if [ -z "${TRI_ROOT}" ]; then
  echo "pipeline_smoke_wsl: TRI_ROOT not found under /home/${USER}/Tri or /home/oni/Tri" >&2
  exit 2
fi

export TRI_ROOT
export TRI_STATE_DIR="${TRI_ROOT}/.tri/state"
mkdir -p "$TRI_STATE_DIR"

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export HEADLESS_REBUILD_TOOL_ROOT="$TOOL_ROOT"

python3 "$TRI_ROOT/puredots/Tools/Ops/tri_ops.py" --state-dir "$TRI_STATE_DIR" init

notes_arg=()
if git -C "$TRI_ROOT/puredots" rev-parse HEAD >/dev/null 2>&1; then
  puredots_sha="$(git -C "$TRI_ROOT/puredots" rev-parse HEAD)"
  notes_arg=(--notes "puredots_ref=${puredots_sha}")
fi

req_id="$(python3 "$TRI_ROOT/puredots/Tools/Ops/tri_ops.py" \
  --state-dir "$TRI_STATE_DIR" \
  request_rebuild \
  --requested-by wsl \
  --projects space4x,godgame \
  --reason "pipeline_smoke" \
  --priority high \
  --desired-build-commit origin/main \
  "${notes_arg[@]}")"

results_dir="${TRI_STATE_DIR}/ops/results"
result_path="${results_dir}/${req_id}.json"

timeout_s=1200
start_ts="$(date +%s)"
while [ ! -f "$result_path" ]; do
  now_ts="$(date +%s)"
  if [ $((now_ts - start_ts)) -ge "$timeout_s" ]; then
    echo "pipeline_smoke_wsl: timed out waiting for results ${result_path}" >&2
    exit 3
  fi
  sleep 10
done

status="$(python3 - <<'PY'
import json,sys
with open(sys.argv[1],"r",encoding="utf-8") as handle:
    data=json.load(handle)
print(data.get("status",""))
PY
"$result_path")"

if [ "$status" != "ok" ]; then
  echo "pipeline_smoke_wsl: rebuild result not ok (status=${status})" >&2
  exit 4
fi

python3 "$TOOL_ROOT/Tools/Headless/headlessctl.py" contract_check

run_task() {
  local task_id="$1"
  local output
  output="$(python3 "$TOOL_ROOT/Tools/Headless/headlessctl.py" run_task "$task_id" --pack nightly-default)"
  local ok
  ok="$(python3 - <<'PY'
import json,sys
data=json.loads(sys.stdin.read())
print("1" if data.get("ok") else "0")
PY
<<<"$output")"
  if [ "$ok" != "1" ]; then
    echo "pipeline_smoke_wsl: task failed: ${task_id}" >&2
    echo "$output" >&2
    exit 5
  fi
  local run_id
  run_id="$(python3 - <<'PY'
import json,sys
data=json.loads(sys.stdin.read())
print(data.get("run_id",""))
PY
<<<"$output")"
  if [ -z "$run_id" ]; then
    echo "pipeline_smoke_wsl: missing run_id for task ${task_id}" >&2
    exit 6
  fi
  local telemetry_path="${TRI_STATE_DIR}/runs/${run_id}/telemetry.ndjson"
  if [ ! -f "$telemetry_path" ]; then
    echo "pipeline_smoke_wsl: telemetry missing for ${task_id}: ${telemetry_path}" >&2
    exit 7
  fi
}

run_task P0.TIME_REWIND_MICRO
run_task S0.SPACE4X_COLLISION_MICRO
run_task G0.GODGAME_COLLISION_MICRO

echo "pipeline_smoke_wsl: ok"
