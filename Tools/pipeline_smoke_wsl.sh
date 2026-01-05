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

timeout_s="${SMOKE_TIMEOUT_S:-1200}"
lock_file="${TRI_STATE_DIR}/ops/locks/build.lock"
state_file="${TRI_STATE_DIR}/ops/locks/build.state.json"

read_pointer_exe() {
  local project="$1"
  local pointer_path="${TRI_STATE_DIR}/builds/current_${project}.json"
  if [ ! -f "$pointer_path" ]; then
    return 0
  fi
  python3 - "$pointer_path" <<'PY'
import json,sys
path=sys.argv[1]
try:
    with open(path,"r",encoding="utf-8") as handle:
        data=json.load(handle)
    exe=data.get("executable","")
    print(exe if exe else "")
except Exception:
    print("")
PY
}

chmod_pointer_binaries() {
  local exe
  exe="$(read_pointer_exe space4x)"
  if [ -n "$exe" ]; then
    chmod +x "$exe" 2>/dev/null || true
  fi
  exe="$(read_pointer_exe godgame)"
  if [ -n "$exe" ]; then
    chmod +x "$exe" 2>/dev/null || true
  fi
}

is_locked() {
  if [ -f "$state_file" ]; then
    python3 - <<'PY' "$state_file"
import json,sys
path=sys.argv[1]
try:
    with open(path,"r",encoding="utf-8") as handle:
        data=json.load(handle)
    print("1" if data.get("state") == "locked" else "0")
except Exception:
    print("1")
PY
    return
  fi
  if [ -f "$lock_file" ]; then
    echo 1
  else
    echo 0
  fi
}
start_ts="$(date +%s)"
while [ ! -f "$result_path" ]; do
  now_ts="$(date +%s)"
  if [ $((now_ts - start_ts)) -ge "$timeout_s" ]; then
    echo "pipeline_smoke_wsl: timed out waiting for results ${result_path}" >&2
    exit 3
  fi
  sleep 10
done

status="$(python3 - "$result_path" <<'PY'
import json,sys
with open(sys.argv[1],"r",encoding="utf-8") as handle:
    data=json.load(handle)
print(data.get("status",""))
PY
)"

if [ "$status" != "ok" ]; then
  echo "pipeline_smoke_wsl: rebuild result not ok (status=${status})" >&2
  exit 4
fi

lock_start_ts="$(date +%s)"
while [ "$(is_locked)" = "1" ]; do
  now_ts="$(date +%s)"
  if [ $((now_ts - lock_start_ts)) -ge "$timeout_s" ]; then
    echo "pipeline_smoke_wsl: timed out waiting for build lock release" >&2
    exit 5
  fi
  sleep 5
done

chmod_pointer_binaries

python3 "$TOOL_ROOT/Tools/Headless/headlessctl.py" contract_check

extract_json_from_output() {
  python3 - <<'PY'
import json
import re
import sys

text = sys.stdin.read()
lines = [line.strip() for line in text.splitlines() if line.strip()]
for line in reversed(lines):
    if line.startswith("{") and line.endswith("}"):
        try:
            obj = json.loads(line)
            print(json.dumps(obj, sort_keys=True))
            raise SystemExit(0)
        except Exception:
            pass

for match in reversed(list(re.finditer(r"\{.*\}", text, flags=re.S))):
    cand = match.group(0)
    try:
        obj = json.loads(cand)
        print(json.dumps(obj, sort_keys=True))
        raise SystemExit(0)
    except Exception:
        pass

raise SystemExit(1)
PY
}

extract_run_id_from_output() {
  python3 - <<'PY'
import re
import sys

text = sys.stdin.read()
matches = re.findall(r"run_id=([0-9a-fA-F]+)", text)
print(matches[-1] if matches else "")
PY
}

find_latest_run_id() {
  python3 - "$TRI_STATE_DIR" "$1" <<'PY'
import os
import sys

state_dir = sys.argv[1]
since_ts = float(sys.argv[2]) if len(sys.argv) > 2 else 0
runs_dir = os.path.join(state_dir, "runs")
if not os.path.isdir(runs_dir):
    print("")
    raise SystemExit(0)

best = ""
best_mtime = 0.0
for name in os.listdir(runs_dir):
    path = os.path.join(runs_dir, name)
    if not os.path.isdir(path):
        continue
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        continue
    if mtime >= since_ts and mtime >= best_mtime:
        best_mtime = mtime
        best = name

print(best)
PY
}

read_result_ok() {
  python3 - "$1" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    print("1" if data.get("ok") else "0")
except Exception:
    print("0")
PY
}

run_task() {
  local task_id="$1"
  local output
  local start_ts
  start_ts="$(date +%s)"
  local exit_code
  set +e
  output="$(python3 "$TOOL_ROOT/Tools/Headless/headlessctl.py" run_task "$task_id" --pack nightly-default 2>&1)"
  exit_code=$?
  set -e
  if [ "$exit_code" -ne 0 ]; then
    echo "pipeline_smoke_wsl: headlessctl exit_code=${exit_code} for task ${task_id}" >&2
  fi
  local json_line
  json_line="$(extract_json_from_output <<<"$output" || true)"
  local run_id
  local ok
  if [ -z "$json_line" ]; then
    run_id="$(extract_run_id_from_output <<<"$output" || true)"
    if [ -z "$run_id" ]; then
      run_id="$(find_latest_run_id "$start_ts" || true)"
      if [ -z "$run_id" ]; then
        sleep 2
        run_id="$(find_latest_run_id 0 || true)"
      fi
    fi
    if [ -z "$run_id" ]; then
      echo "pipeline_smoke_wsl: could not parse JSON output for task ${task_id}" >&2
      echo "pipeline_smoke_wsl: run_task output length=${#output}" >&2
      echo "$output" >&2
      exit 5
    fi
    echo "pipeline_smoke_wsl: fallback run_id=${run_id} for task ${task_id}" >&2
    local result_path="${TRI_STATE_DIR}/runs/${run_id}/result.json"
    ok="$(read_result_ok "$result_path")"
  else
    ok="$(python3 - <<'PY'
import json,sys
data=json.loads(sys.stdin.read())
print("1" if data.get("ok") else "0")
PY
<<<"$json_line")"
    run_id="$(python3 - <<'PY'
import json,sys
data=json.loads(sys.stdin.read())
print(data.get("run_id",""))
PY
<<<"$json_line")"
  fi
  if [ "$ok" != "1" ]; then
    echo "pipeline_smoke_wsl: task failed: ${task_id}" >&2
    if [ -n "$json_line" ]; then
      echo "$json_line" >&2
    else
      echo "pipeline_smoke_wsl: result.json indicates failure for run_id=${run_id}" >&2
    fi
    exit 5
  fi
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
