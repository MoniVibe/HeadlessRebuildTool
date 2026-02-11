#!/usr/bin/env bash
set -u
set -o pipefail

RUNNER_VERSION="wsl_runner/0.2"

EXIT_REASON_SUCCESS="SUCCESS"
EXIT_REASON_TEST_FAIL="TEST_FAIL"
EXIT_REASON_CRASH="CRASH"
EXIT_REASON_HANG="HANG_TIMEOUT"
EXIT_REASON_INFRA="INFRA_FAIL"

EXIT_CODE_SUCCESS=0
EXIT_CODE_TEST_FAIL=10
EXIT_CODE_INFRA_FAIL=20
EXIT_CODE_CRASH=30
EXIT_CODE_HANG=40

HAVE_JQ=0
HAVE_ZIP=0
HAVE_UNZIP=0
PYTHON_BIN=""
LAST_DIAG_START_UTC=""
LAST_DIAG_END_UTC=""
LAST_DIAG_REASON=""
CURRENT_STDOUT_LOG=""
CURRENT_STDERR_LOG=""
CURRENT_PLAYER_LOG=""
CURRENT_CORE_DUMP_PRESENT=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TRIAGE_SCRIPT="${TOOLS_ROOT}/Polish/Tools/extract_triage.py"
DEFAULT_REPORTS_DIR="/mnt/c/polish/queue/reports"
DEFAULT_TELEMETRY_MAX_BYTES=52428800
log() {
  echo "wsl_runner: $*" >&2
}

usage() {
  cat <<'USAGE'
Usage: wsl_runner.sh --queue <path> [--workdir <path>] [--once|--daemon]
                    [--heartbeat-interval <sec>] [--diag-timeout <sec>]
                    [--print-summary] [--requeue-stale-leases --ttl-sec <sec>]
                    [--emit-triage-on-fail] [--reports-dir <path>] [--telemetry-max-bytes <bytes>] [--self-test]

Options:
  --queue <path>              Queue root (required unless --self-test).
  --workdir <path>            Run root (default: ~/polish/runs).
  --once                      Process one job and exit (default).
  --daemon                    Poll forever.
  --heartbeat-interval <sec>  Heartbeat interval seconds (default: 2).
  --diag-timeout <sec>        Diagnostics timeout seconds (default: 15).
  --print-summary             Print summary line after each job.
  --emit-triage-on-fail        Emit triage summary JSON on failures (default).
  --reports-dir <path>         Triage reports directory (default: /mnt/c/polish/queue/reports).
  --telemetry-max-bytes <bytes> Telemetry output cap in bytes (default: 52428800).
  --requeue-stale-leases      Requeue stale leases (helper mode).
  --ttl-sec <sec>             TTL seconds for stale leases (default: 600).
  --self-test                 Run local self-test scenarios.
USAGE
}

iso_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "missing dependency: $cmd"
    return 1
  fi
  return 0
}

ensure_dependencies() {
  local missing=0
  local cmd

  for cmd in timeout sha256sum ps sed awk date; do
    if ! require_cmd "$cmd"; then
      missing=1
    fi
  done

  if command -v jq >/dev/null 2>&1; then
    HAVE_JQ=1
  fi
  if command -v zip >/dev/null 2>&1; then
    HAVE_ZIP=1
  fi
  if command -v unzip >/dev/null 2>&1; then
    HAVE_UNZIP=1
  fi

  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
  elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
  fi

  if [ -z "$PYTHON_BIN" ]; then
    log "missing dependency: python3 (or python)"
    missing=1
  fi

  if [ "$missing" -ne 0 ]; then
    exit 2
  fi
}

is_drive_mount_path() {
  case "$1" in
    /mnt/[a-zA-Z]/*|/mnt/[a-zA-Z]) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_workdir_ext4() {
  local workdir="$1"
  if is_drive_mount_path "$workdir"; then
    log "workdir must be on WSL ext4 (not a Windows drive mount): $workdir"
    return 1
  fi
  return 0
}

resolve_artifact_uri() {
  local uri="$1"
  if [ -z "$uri" ]; then
    echo ""
    return 0
  fi

  if [[ "${uri:1:1}" == ":" && ( "${uri:2:1}" == "\\" || "${uri:2:1}" == "/" ) ]]; then
    local drive="${uri:0:1}"
    local rest="${uri:2}"
    rest="${rest//\\//}"
    echo "/mnt/${drive,,}${rest}"
    return 0
  fi

  if [[ "$uri" == "\\\\?\\UNC\\"* ]]; then
    local trimmed="${uri#\\\\?\\UNC\\}"
    local server="${trimmed%%\\*}"
    local rest="${trimmed#*\\}"
    local share="${rest%%\\*}"
    local path_rest="${rest#*\\}"
    path_rest="${path_rest//\\//}"
    local unc_root="${UNC_ROOT:-/mnt/unc}"
    echo "${unc_root}/${server}/${share}/${path_rest}"
    return 0
  fi

  if [[ "${uri:0:2}" == "\\\\" ]]; then
    local trimmed="${uri:2}"
    local server="${trimmed%%\\*}"
    local rest="${trimmed#*\\}"
    if [[ "$server" == "wsl$" ]]; then
      local distro="${rest%%\\*}"
      local path_rest="${rest#*\\}"
      path_rest="${path_rest//\\//}"
      echo "/${path_rest}"
      return 0
    fi
    local share="${rest%%\\*}"
    local path_rest="${rest#*\\}"
    path_rest="${path_rest//\\//}"
    local unc_root="${UNC_ROOT:-/mnt/unc}"
    echo "${unc_root}/${server}/${share}/${path_rest}"
    return 0
  fi

  if [[ "$uri" == //wsl$/* ]]; then
    local trimmed="${uri#//wsl$/}"
    local distro="${trimmed%%/*}"
    local path_rest="${trimmed#*/}"
    echo "/${path_rest}"
    return 0
  fi

  if [[ "$uri" == //* ]]; then
    local trimmed="${uri#//}"
    local server="${trimmed%%/*}"
    local rest="${trimmed#*/}"
    local share="${rest%%/*}"
    local path_rest="${rest#*/}"
    local unc_root="${UNC_ROOT:-/mnt/unc}"
    echo "${unc_root}/${server}/${share}/${path_rest}"
    return 0
  fi

  echo "$uri"
}

json_valid() {
  local file="$1"
  if [ "$HAVE_JQ" -eq 1 ]; then
    jq -e . "$file" >/dev/null 2>&1
    return $?
  fi
  "$PYTHON_BIN" - "$file" <<'PY'
import json,sys
path=sys.argv[1]
try:
    with open(path,"r",encoding="utf-8") as handle:
        json.load(handle)
    raise SystemExit(0)
except Exception:
    raise SystemExit(1)
PY
}

json_get_string() {
  local file="$1"
  local field="$2"
  if [ "$HAVE_JQ" -eq 1 ]; then
    jq -r --arg field "$field" '.[$field] // empty' "$file" 2>/dev/null || true
    return 0
  fi
  "$PYTHON_BIN" - "$file" "$field" <<'PY'
import json,sys
path=sys.argv[1]
field=sys.argv[2]
try:
    with open(path,"r",encoding="utf-8") as handle:
        data=json.load(handle)
except Exception:
    data={}
val=data.get(field, "")
if val is None:
    val=""
if isinstance(val,(dict,list)):
    print("")
else:
    print(val)
PY
}

json_get_object_sorted() {
  local file="$1"
  local field="$2"
  if [ "$HAVE_JQ" -eq 1 ]; then
    jq -c --sort-keys --arg field "$field" '.[$field] // {}' "$file" 2>/dev/null || echo "{}"
    return 0
  fi
  "$PYTHON_BIN" - "$file" "$field" <<'PY'
import json,sys
path=sys.argv[1]
field=sys.argv[2]
try:
    with open(path,"r",encoding="utf-8") as handle:
        data=json.load(handle)
except Exception:
    data={}
val=data.get(field, {})
if not isinstance(val, dict):
    val={}
print(json.dumps(val, sort_keys=True, separators=(',', ':')))
PY
}

read_json_array_field() {
  local file="$1"
  local field="$2"
  if [ "$HAVE_JQ" -eq 1 ]; then
    jq -r --arg field "$field" '
      .[$field] |
      if type=="array" then .[]
      elif type=="string" then .
      else empty
      end
    ' "$file" 2>/dev/null || true
    return 0
  fi
  "$PYTHON_BIN" - "$file" "$field" <<'PY'
import json,sys
path=sys.argv[1]
field=sys.argv[2]
try:
    with open(path,"r",encoding="utf-8") as handle:
        data=json.load(handle)
except Exception:
    data={}
val=data.get(field)
if isinstance(val, list):
    for item in val:
        if item is None:
            continue
        print(item)
elif isinstance(val, str):
    if val:
        print(val)
PY
}

json_array_contains() {
  local file="$1"
  local field="$2"
  local value="$3"
  if [ "$HAVE_JQ" -eq 1 ]; then
    jq -e --arg field "$field" --arg value "$value" '.[$field] | index($value)' "$file" >/dev/null 2>&1
    return $?
  fi
  "$PYTHON_BIN" - "$file" "$field" "$value" <<'PY'
import json,sys
path=sys.argv[1]
field=sys.argv[2]
value=sys.argv[3]
try:
    with open(path,"r",encoding="utf-8") as handle:
        data=json.load(handle)
except Exception:
    data={}
arr=data.get(field)
if isinstance(arr, str):
    arr=[arr]
if not isinstance(arr, list):
    raise SystemExit(1)
raise SystemExit(0 if value in arr else 1)
PY
}

json_array_nonempty() {
  local file="$1"
  local field="$2"
  if [ "$HAVE_JQ" -eq 1 ]; then
    jq -e --arg field "$field" '(.[$field] | type=="array") and (.[$field] | length > 0)' "$file" >/dev/null 2>&1
    return $?
  fi
  "$PYTHON_BIN" - "$file" "$field" <<'PY'
import json,sys
path=sys.argv[1]
field=sys.argv[2]
try:
    with open(path,"r",encoding="utf-8") as handle:
        data=json.load(handle)
except Exception:
    raise SystemExit(1)
arr=data.get(field)
if isinstance(arr, list) and len(arr) > 0:
    raise SystemExit(0)
raise SystemExit(1)
PY
}

strip_logfile_args() {
  local -n in_args="$1"
  local -n out_args="$2"
  out_args=()
  local skip_next=0
  local arg
  for arg in "${in_args[@]}"; do
    if [ "$skip_next" -eq 1 ]; then
      skip_next=0
      continue
    fi
    case "$arg" in
      -logFile|-logfile)
        skip_next=1
        continue
        ;;
      -logFile=*|-logfile=*)
        continue
        ;;
    esac
    out_args+=("$arg")
  done
}

strip_diagnostic_args() {
  local -n in_args="$1"
  local -n out_args="$2"
  out_args=()
  local skip_next=0
  local arg
  for arg in "${in_args[@]}"; do
    if [ "$skip_next" -eq 1 ]; then
      skip_next=0
      continue
    fi
    case "$arg" in
      --outDir|--invariantsPath|--progressPath|--telemetryPath|--telemetryEnabled)
        skip_next=1
        continue
        ;;
      --outDir=*|--invariantsPath=*|--progressPath=*|--telemetryPath=*|--telemetryEnabled=*)
        continue
        ;;
    esac
    out_args+=("$arg")
  done
}

args_include_flag() {
  local flag="$1"
  shift
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "$flag" || "$arg" == "$flag="* ]]; then
      return 0
    fi
  done
  return 1
}

args_include_logfile() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -logFile|-logfile|-logFile=*|-logfile=*)
        return 0
        ;;
    esac
  done
  return 1
}

telemetry_disabled_in_args() {
  local arg
  local expect_value=0
  for arg in "$@"; do
    if [ "$expect_value" -eq 1 ]; then
      case "$arg" in
        0|false|False|FALSE)
          return 0
          ;;
      esac
      expect_value=0
      continue
    fi
    case "$arg" in
      --telemetryEnabled)
        expect_value=1
        ;;
      --telemetryEnabled=0|--telemetryEnabled=false|--telemetryEnabled=False|--telemetryEnabled=FALSE)
        return 0
        ;;
    esac
  done
  return 1
}

shell_quote() {
  printf '%q' "$1"
}

build_repro_command() {
  local entrypoint_path="$1"
  local param_json="$2"
  local feature_json="$3"
  shift 3
  local -a args=("$@")
  local -a parts=()
  if [ -n "$param_json" ]; then
    parts+=("TRI_PARAM_OVERRIDES=$(shell_quote "$param_json")")
  fi
  if [ -n "$feature_json" ]; then
    parts+=("TRI_FEATURE_FLAGS=$(shell_quote "$feature_json")")
  fi
  parts+=("$(shell_quote "$entrypoint_path")")
  local arg
  for arg in "${args[@]}"; do
    parts+=("$(shell_quote "$arg")")
  done
  local out="${parts[0]}"
  local part
  for part in "${parts[@]:1}"; do
    out+=" $part"
  done
  printf '%s' "$out"
}

tail_match() {
  local file="$1"
  local pattern="$2"
  if [ ! -f "$file" ]; then
    return 1
  fi
  tail -n 200 "$file" | grep -qiE "$pattern"
}

scenario_complete_marker_present() {
  local pattern='scenario (complete|completed)|ScenarioRunner.*completed'
  tail_match "$CURRENT_STDOUT_LOG" "$pattern" || tail_match "$CURRENT_STDERR_LOG" "$pattern"
}

crash_marker_present() {
  local pattern='segmentation fault|sigsegv|crash!!!|abort|sigabrt'
  tail_match "$CURRENT_STDOUT_LOG" "$pattern" || tail_match "$CURRENT_STDERR_LOG" "$pattern" || tail_match "$CURRENT_PLAYER_LOG" "$pattern"
}

test_fail_marker_present() {
  local pattern='assert fail|invariant fail|scenario failed|assertion failed'
  tail_match "$CURRENT_STDOUT_LOG" "$pattern" || tail_match "$CURRENT_STDERR_LOG" "$pattern"
}

scenario_file_not_found_present() {
  local pattern='scenario file not found'
  tail_match "$CURRENT_PLAYER_LOG" "$pattern" || tail_match "$CURRENT_STDOUT_LOG" "$pattern" || tail_match "$CURRENT_STDERR_LOG" "$pattern"
}

exit_by_signal() {
  local process_exit_code="$1"
  if [ "$process_exit_code" -ge 128 ]; then
    return 0
  fi
  return 1
}

classify_exit_reason() {
  local process_exit_code="$1"
  local timed_out="$2"
  if [ "$timed_out" -eq 1 ]; then
    echo "$EXIT_REASON_HANG"
    return 0
  fi
  if scenario_file_not_found_present; then
    echo "$EXIT_REASON_INFRA"
    return 0
  fi
  if [ "$process_exit_code" -eq 0 ]; then
    echo "$EXIT_REASON_SUCCESS"
    return 0
  fi
  if exit_by_signal "$process_exit_code"; then
    echo "$EXIT_REASON_CRASH"
    return 0
  fi
  if [ "$CURRENT_CORE_DUMP_PRESENT" -eq 1 ]; then
    echo "$EXIT_REASON_CRASH"
    return 0
  fi
  if crash_marker_present; then
    echo "$EXIT_REASON_CRASH"
    return 0
  fi
  if [ "$process_exit_code" -eq "$EXIT_CODE_TEST_FAIL" ]; then
    echo "$EXIT_REASON_TEST_FAIL"
    return 0
  fi
  if [ "$process_exit_code" -eq "$EXIT_CODE_INFRA_FAIL" ]; then
    echo "$EXIT_REASON_INFRA"
    return 0
  fi
  if test_fail_marker_present; then
    echo "$EXIT_REASON_TEST_FAIL"
    return 0
  fi
  echo "$EXIT_REASON_TEST_FAIL"
}

exit_code_for_reason() {
  local reason="$1"
  case "$reason" in
    "$EXIT_REASON_SUCCESS") echo "$EXIT_CODE_SUCCESS" ;;
    "$EXIT_REASON_TEST_FAIL") echo "$EXIT_CODE_TEST_FAIL" ;;
    "$EXIT_REASON_INFRA") echo "$EXIT_CODE_INFRA_FAIL" ;;
    "$EXIT_REASON_CRASH") echo "$EXIT_CODE_CRASH" ;;
    "$EXIT_REASON_HANG") echo "$EXIT_CODE_HANG" ;;
    *) echo "$EXIT_CODE_CRASH" ;;
  esac
}

extract_error_line() {
  local line=""
  local log
  for log in "$CURRENT_STDERR_LOG" "$CURRENT_STDOUT_LOG"; do
    if [ -f "$log" ]; then
      line=$(tail -n 200 "$log" | grep -iE 'segmentation fault|crash|exception|assert|invariant|error|fatal' | tail -n 1 | tr -d '\r')
      if [ -n "$line" ]; then
        echo "$line"
        return 0
      fi
    fi
  done
  for log in "$CURRENT_STDERR_LOG" "$CURRENT_STDOUT_LOG"; do
    if [ -f "$log" ]; then
      line=$(tail -n 50 "$log" | grep -v '^[[:space:]]*$' | tail -n 1 | tr -d '\r')
      if [ -n "$line" ]; then
        echo "$line"
        return 0
      fi
    fi
  done
  echo ""
}

normalize_signature() {
  local input="$1"
  printf '%s' "$input" | sed -E \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z?/<ts>/g' \
    -e 's/[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?/<ts>/g' \
    -e 's/0x[0-9a-fA-F]+/<hex>/g' \
    -e 's#[A-Za-z]:\\\\[^ ]+#<path>#g' \
    -e 's#/[^ ]+#<path>#g' \
    -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<uuid>/g'
}

hash_signature() {
  local input="$1"
  printf '%s' "$input" | sha256sum | awk '{print $1}'
}

run_diagnostics() {
  local diag_reason="$1"
  local out_dir="$2"
  local stdout_log="$3"
  local stderr_log="$4"
  local pid="$5"
  local pgid="$6"
  local entrypoint_name="$7"
  local diag_timeout="$8"

  LAST_DIAG_START_UTC="$(iso_utc)"
  LAST_DIAG_REASON="$diag_reason"

  DIAG_REASON="$diag_reason" OUT_DIR="$out_dir" STDOUT_LOG="$stdout_log" STDERR_LOG="$stderr_log" \
    PID="$pid" PGID="$pgid" ENTRYPOINT_NAME="$entrypoint_name" RUNNER_VERSION="$RUNNER_VERSION" \
    timeout "${diag_timeout}s" bash -c '
      mkdir -p "$OUT_DIR"
      tail -n 200 "$STDOUT_LOG" > "$OUT_DIR/diag_stdout_tail.txt" 2>/dev/null || true
      tail -n 200 "$STDERR_LOG" > "$OUT_DIR/diag_stderr_tail.txt" 2>/dev/null || true
      pattern=""
      if [ -n "$ENTRYPOINT_NAME" ]; then
        pattern="$ENTRYPOINT_NAME"
      fi
      if [ -n "$PID" ]; then
        pattern="${pattern:+$pattern|}$PID"
      fi
      if [ -n "$PGID" ]; then
        pattern="${pattern:+$pattern|}$PGID"
      fi
      if [ -n "$pattern" ]; then
        ps -eo pid,ppid,pgid,stat,etimes,cmd --forest | grep -E "$pattern" > "$OUT_DIR/ps_snapshot.txt" 2>/dev/null || true
      else
        ps -eo pid,ppid,pgid,stat,etimes,cmd --forest > "$OUT_DIR/ps_snapshot.txt" 2>/dev/null || true
      fi
      {
        echo "diag_reason=$DIAG_REASON"
        echo "uname=$(uname -a)"
        echo "proc_version=$(cat /proc/version 2>/dev/null || true)"
        echo "runner_version=$RUNNER_VERSION"
      } > "$OUT_DIR/system_snapshot.txt" 2>/dev/null || true
      if command -v gdb >/dev/null 2>&1 && [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        gdb -batch -ex "thread apply all bt" -p "$PID" > "$OUT_DIR/gdb_bt.txt" 2>/dev/null || true
      fi
    ' || true

  LAST_DIAG_END_UTC="$(iso_utc)"
}

write_watchdog_json() {
  local out_dir="$1"
  local job_id="$2"
  local exit_reason="$3"
  local process_exit_code="$4"
  local runner_exit_code="$5"
  local raw_signature="$6"

  "$PYTHON_BIN" - "$out_dir" "$job_id" "$exit_reason" "$process_exit_code" "$runner_exit_code" \
    "$raw_signature" "$LAST_DIAG_REASON" "$LAST_DIAG_START_UTC" "$LAST_DIAG_END_UTC" \
    "$RUNNER_VERSION" <<'PY'
import json,os,sys
out_dir=sys.argv[1]
job_id=sys.argv[2]
exit_reason=sys.argv[3]
process_exit_code=sys.argv[4]
runner_exit_code=sys.argv[5]
raw_signature=sys.argv[6]
diag_reason=sys.argv[7]
diag_start=sys.argv[8]
diag_end=sys.argv[9]
runner_version=sys.argv[10]

def read_lines(path):
    try:
        with open(path,"r",encoding="utf-8") as handle:
            return handle.read().splitlines()
    except Exception:
        return []

def read_text(path):
    try:
        with open(path,"r",encoding="utf-8") as handle:
            return handle.read()
    except Exception:
        return ""

stdout_tail=read_lines(os.path.join(out_dir,"diag_stdout_tail.txt"))
stderr_tail=read_lines(os.path.join(out_dir,"diag_stderr_tail.txt"))
ps_snapshot=read_text(os.path.join(out_dir,"ps_snapshot.txt"))
try:
    uname_line=" ".join(os.uname())
except Exception:
    uname_line=""
proc_version=read_text("/proc/version")

watchdog={
    "job_id": job_id,
    "exit_reason": exit_reason,
    "process_exit_code": int(process_exit_code) if process_exit_code not in ("", None) else None,
    "runner_exit_code": int(runner_exit_code) if runner_exit_code not in ("", None) else None,
    "raw_signature_string": raw_signature,
    "diag_reason": diag_reason,
    "diag_start_utc": diag_start,
    "diag_end_utc": diag_end,
    "stdout_tail": stdout_tail,
    "stderr_tail": stderr_tail,
    "ps_snapshot": ps_snapshot,
    "uname": uname_line.strip(),
    "proc_version": proc_version.strip(),
    "runner_version": runner_version,
    "gdb_bt_path": "out/gdb_bt.txt" if os.path.exists(os.path.join(out_dir,"gdb_bt.txt")) else None,
    "system_snapshot_path": "out/system_snapshot.txt" if os.path.exists(os.path.join(out_dir,"system_snapshot.txt")) else None,
    "core_dump_path": "out/core_dump_path.txt" if os.path.exists(os.path.join(out_dir,"core_dump_path.txt")) else None
}

path=os.path.join(out_dir,"watchdog.json")
with open(path,"w",encoding="utf-8") as handle:
    json.dump(watchdog, handle, indent=2, sort_keys=True)
PY
}

build_artifact_paths_json() {
  local out_dir="$1"
  "$PYTHON_BIN" - "$out_dir" <<'PY'
import json,os,sys
out_dir=sys.argv[1]
paths={}

def add(key, filename, rel):
    if os.path.exists(os.path.join(out_dir, filename)):
        paths[key]=rel

add("stdout_log","stdout.log","out/stdout.log")
add("stderr_log","stderr.log","out/stderr.log")
add("player_log","player.log","out/player.log")
add("watchdog","watchdog.json","out/watchdog.json")
add("repro","repro.txt","out/repro.txt")
add("progress_json","progress.json","out/progress.json")
add("invariants_json","invariants.json","out/invariants.json")
add("telemetry","telemetry.ndjson","out/telemetry.ndjson")
add("perf_telemetry","perf_telemetry.ndjson","out/perf_telemetry.ndjson")
add("diag_stdout_tail","diag_stdout_tail.txt","out/diag_stdout_tail.txt")
add("diag_stderr_tail","diag_stderr_tail.txt","out/diag_stderr_tail.txt")
add("system_snapshot","system_snapshot.txt","out/system_snapshot.txt")
add("ps_snapshot","ps_snapshot.txt","out/ps_snapshot.txt")
add("gdb_bt","gdb_bt.txt","out/gdb_bt.txt")
add("core_dump_path","core_dump_path.txt","out/core_dump_path.txt")

print(json.dumps(paths, sort_keys=True, separators=(',', ':')))
PY
}

write_meta_json() {
  local meta_path="$1"
  local job_id="$2"
  local build_id="$3"
  local commit="$4"
  local scenario_id="$5"
  local seed="$6"
  local start_utc="$7"
  local end_utc="$8"
  local duration_sec="$9"
  local exit_reason="${10}"
  local exit_code="${11}"
  local repro_command="${12}"
  local failure_signature="${13}"
  local artifact_paths_json="${14}"
  local runner_host="${15}"

  "$PYTHON_BIN" - "$meta_path" "$job_id" "$build_id" "$commit" "$scenario_id" "$seed" \
    "$start_utc" "$end_utc" "$duration_sec" "$exit_reason" "$exit_code" \
    "$repro_command" "$failure_signature" "$artifact_paths_json" "$runner_host" <<'PY'
import json,sys
meta_path=sys.argv[1]
job_id=sys.argv[2]
build_id=sys.argv[3]
commit=sys.argv[4]
scenario_id=sys.argv[5]
seed_raw=sys.argv[6]
start_utc=sys.argv[7]
end_utc=sys.argv[8]
duration_sec=sys.argv[9]
exit_reason=sys.argv[10]
exit_code=sys.argv[11]
repro_command=sys.argv[12]
failure_signature=sys.argv[13]
artifact_paths_json=sys.argv[14]
runner_host=sys.argv[15]

try:
    seed_val=int(seed_raw)
except Exception:
    seed_val=None
try:
    duration_val=int(duration_sec)
except Exception:
    duration_val=0
try:
    exit_code_val=int(exit_code)
except Exception:
    exit_code_val=1
try:
    artifact_paths=json.loads(artifact_paths_json) if artifact_paths_json else {}
except Exception:
    artifact_paths={}

meta={
    "job_id": job_id,
    "build_id": build_id,
    "commit": commit,
    "scenario_id": scenario_id,
    "seed": seed_val,
    "start_utc": start_utc,
    "end_utc": end_utc,
    "duration_sec": duration_val,
    "exit_reason": exit_reason,
    "exit_code": exit_code_val,
    "repro_command": repro_command,
    "failure_signature": failure_signature,
    "artifact_paths": artifact_paths,
    "runner_host": runner_host,
    "runner_env": "wsl"
}

with open(meta_path,"w",encoding="utf-8") as handle:
    json.dump(meta, handle, indent=2, sort_keys=True)
PY
}

run_ml_analyzer() {
  local meta_path="$1"
  local out_dir="$2"
  local analyzer="${SCRIPT_DIR}/../ML/analyze_run.py"

  if [ ! -f "$analyzer" ]; then
    log "WARN: analyzer not found: $analyzer"
    return 0
  fi
  if [ -z "$PYTHON_BIN" ]; then
    log "WARN: analyzer skipped (python missing)"
    return 0
  fi
  if ! "$PYTHON_BIN" "$analyzer" --meta "$meta_path" --outdir "$out_dir"; then
    log "WARN: analyze_run failed"
  fi
  return 0
}
extract_zip() {
  local zip_path="$1"
  local dest_dir="$2"
  if [ "$HAVE_UNZIP" -eq 1 ]; then
    unzip -q "$zip_path" -d "$dest_dir"
    return $?
  fi
  "$PYTHON_BIN" - "$zip_path" "$dest_dir" <<'PY'
import sys,zipfile,os
zip_path=sys.argv[1]
dest=sys.argv[2]
os.makedirs(dest, exist_ok=True)
with zipfile.ZipFile(zip_path,"r") as zf:
    zf.extractall(dest)
PY
}

create_zip() {
  local zip_path="$1"
  local run_dir="$2"
  if [ "$HAVE_ZIP" -eq 1 ]; then
    (cd "$run_dir" && zip -q -r "$zip_path" "meta.json" "out")
    return $?
  fi
  "$PYTHON_BIN" - "$zip_path" "$run_dir" <<'PY'
import os,sys,zipfile
zip_path=sys.argv[1]
run_dir=sys.argv[2]

items=[("meta.json", os.path.join(run_dir,"meta.json")), ("out", os.path.join(run_dir,"out"))]
with zipfile.ZipFile(zip_path,"w",compression=zipfile.ZIP_DEFLATED) as zf:
    for arcname, path in items:
        if os.path.isdir(path):
            for root, _, files in os.walk(path):
                for name in files:
                    full=os.path.join(root, name)
                    rel=os.path.relpath(full, run_dir)
                    zf.write(full, rel)
        elif os.path.exists(path):
            zf.write(path, arcname)
PY
}

create_zip_from_dir() {
  local zip_path="$1"
  local src_dir="$2"
  if [ "$HAVE_ZIP" -eq 1 ]; then
    (cd "$src_dir" && zip -q -r "$zip_path" .)
    return $?
  fi
  "$PYTHON_BIN" - "$zip_path" "$src_dir" <<'PY'
import os,sys,zipfile
zip_path=sys.argv[1]
src_dir=sys.argv[2]
with zipfile.ZipFile(zip_path,"w",compression=zipfile.ZIP_DEFLATED) as zf:
    for root, _, files in os.walk(src_dir):
        for name in files:
            full=os.path.join(root, name)
            rel=os.path.relpath(full, src_dir)
            zf.write(full, rel)
PY
}

publish_result_zip() {
  local run_dir="$1"
  local queue_dir="$2"
  local job_id="$3"

  local staging_zip="${run_dir}/result_${job_id}.zip"
  create_zip "$staging_zip" "$run_dir"
  mkdir -p "${queue_dir}/results/.tmp"
  local tmp_zip="${queue_dir}/results/.tmp/result_${job_id}.zip"
  local final_zip="${queue_dir}/results/result_${job_id}.zip"
  mv "$staging_zip" "$tmp_zip"
  mv "$tmp_zip" "$final_zip"
}

write_lease_meta() {
  local lease_meta_path="$1"
  local job_id="$2"
  local runner_host="$3"
  local lease_start_utc="$4"
  local pid="$5"

  "$PYTHON_BIN" - "$lease_meta_path" "$job_id" "$runner_host" "$lease_start_utc" "$pid" <<'PY'
import json,sys
path=sys.argv[1]
job_id=sys.argv[2]
runner_host=sys.argv[3]
lease_start=sys.argv[4]
pid_raw=sys.argv[5]
try:
    pid_val=int(pid_raw)
except Exception:
    pid_val=None

payload={
    "job_id": job_id,
    "runner_host": runner_host,
    "lease_start_utc": lease_start,
    "pid": pid_val
}
with open(path,"w",encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
}

archive_lease() {
  local lease_path="$1"
  local lease_meta_path="$2"
  local queue_dir="$3"
  local job_id="$4"
  local archive_dir="${queue_dir}/leases/archive"
  mkdir -p "$archive_dir"
  if [ -f "$lease_path" ]; then
    mv "$lease_path" "${archive_dir}/${job_id}.json" 2>/dev/null || rm -f "$lease_path"
  fi
  if [ -f "$lease_meta_path" ]; then
    mv "$lease_meta_path" "${archive_dir}/${job_id}.lease.json" 2>/dev/null || rm -f "$lease_meta_path"
  fi
}

claim_job() {
  local queue_dir="$1"
  local jobs_dir="${queue_dir}/jobs"
  local leases_dir="${queue_dir}/leases"
  local job_path
  shopt -s nullglob
  for job_path in "${jobs_dir}"/*.json; do
    local job_name
    job_name="$(basename "$job_path")"
    local lease_path="${leases_dir}/${job_name}"
    if mv "$job_path" "$lease_path" 2>/dev/null; then
      shopt -u nullglob
      echo "$lease_path"
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

ensure_queue_dirs() {
  local queue_dir="$1"
  mkdir -p "${queue_dir}/jobs" "${queue_dir}/leases" "${queue_dir}/results" "${queue_dir}/artifacts"
  mkdir -p "${queue_dir}/results/.tmp" "${queue_dir}/leases/archive"
}

find_core_dump() {
  local run_dir="$1"
  local build_dir="$2"
  local out_dir="$3"
  local core_path=""
  local candidate
  CURRENT_CORE_DUMP_PRESENT=0
  for candidate in "$run_dir"/core* "$build_dir"/core*; do
    if [ -f "$candidate" ]; then
      core_path="$candidate"
      break
    fi
  done
  if [ -n "$core_path" ]; then
    echo "$core_path" > "$out_dir/core_dump_path.txt"
    CURRENT_CORE_DUMP_PRESENT=1
  fi
}

print_summary_line() {
  local meta_path="$1"
  local out_dir="$2"
  local progress_path="${out_dir}/progress.json"
  local invariants_path="${out_dir}/invariants.json"
  local score_path="${out_dir}/polish_score_v0.json"

  "$PYTHON_BIN" - "$meta_path" "$progress_path" "$invariants_path" "$score_path" <<'PY'
import json,os,sys
meta_path=sys.argv[1]
progress_path=sys.argv[2]
invariants_path=sys.argv[3]
score_path=sys.argv[4]

def load(path):
    if not os.path.exists(path):
        return None
    try:
        with open(path,"r",encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return None

meta=load(meta_path) or {}
progress=load(progress_path)
inv=load(invariants_path)
score=load(score_path) or {}

progress_marker=""
if isinstance(progress, list) and progress:
    progress=progress[-1]
if isinstance(progress, dict):
    phase=progress.get("phase") or progress.get("stage") or progress.get("name") or progress.get("state") or ""
    checkpoint=progress.get("checkpoint") or progress.get("step") or progress.get("checkpoint_id") or progress.get("checkpointId") or ""
    tick=progress.get("tick") or progress.get("frame") or progress.get("sim_tick") or progress.get("time") or ""
    parts=[]
    if phase:
        parts.append(str(phase))
    if checkpoint:
        parts.append(str(checkpoint))
    marker="/".join(parts)
    if tick != "":
        progress_marker = f"{marker}@{tick}" if marker else f"@{tick}"
    else:
        progress_marker = marker

fail_ids=[]
det_hash=""
if isinstance(inv, dict):
    det_hash = inv.get("determinism_hash") or inv.get("determinismHash") or inv.get("hash") or ""
    candidates=None
    for key in ("failing_invariants","failed_invariants","invariant_failures","failures","failed","failing"):
        if key in inv:
            candidates=inv.get(key)
            break
    if candidates is None and isinstance(inv.get("invariants"), list):
        candidates=[item for item in inv.get("invariants", [])
                    if isinstance(item, dict) and (item.get("ok") is False or str(item.get("status","")).lower() in ("fail","failed","error"))]

    if isinstance(candidates, list):
        items=candidates
    elif isinstance(candidates, dict):
        items=[candidates]
    else:
        items=[]

    for item in items:
        if isinstance(item, str):
            fail_ids.append(item)
            continue
        if isinstance(item, dict):
            for key in ("id","name","key","code"):
                if key in item:
                    fail_ids.append(str(item[key]))
                    break

unique_ids=[]
for item in fail_ids:
    if item not in unique_ids:
        unique_ids.append(item)

parts=[]
job_id=meta.get("job_id") or ""
if job_id:
    parts.append(job_id)
parts.append(f"exit_reason={meta.get('exit_reason','')}")
parts.append(f"exit_code={meta.get('exit_code','')}")
parts.append(f"failure_signature={meta.get('failure_signature','')}")
if progress_marker:
    parts.append(f"progress={progress_marker}")
if det_hash:
    parts.append(f"determinism_hash={det_hash}")
if unique_ids:
    parts.append(f"failing_invariants={','.join(unique_ids[:3])}")
if isinstance(score, dict):
    total_loss=score.get("total_loss")
    grade=score.get("grade")
    if total_loss is not None:
        parts.append(f"total_loss={total_loss}")
    if grade:
        parts.append(f"grade={grade}")

print(" ".join([p for p in parts if p]))
PY
}

requeue_stale_leases() {
  local queue_dir="$1"
  local ttl_sec="$2"
  local now
  now="$(date -u +%s)"
  local leases_dir="${queue_dir}/leases"
  local jobs_dir="${queue_dir}/jobs"
  mkdir -p "$jobs_dir"

  shopt -s nullglob
  local lease_path
  for lease_path in "${leases_dir}"/*.json; do
    case "$lease_path" in
      *.lease.json) continue ;;
    esac
    local job_id
    job_id="$(basename "$lease_path" .json)"
    if json_valid "$lease_path"; then
      local json_job_id
      json_job_id="$(json_get_string "$lease_path" "job_id")"
      if [ -n "$json_job_id" ]; then
        job_id="$json_job_id"
      fi
    fi
    local meta_path="${leases_dir}/${job_id}.lease.json"
    local mtime_path="$lease_path"
    if [ -f "$meta_path" ]; then
      mtime_path="$meta_path"
    fi
    local mtime
    mtime="$(stat -c %Y "$mtime_path" 2>/dev/null || echo 0)"
    if [ "$mtime" -le 0 ]; then
      continue
    fi
    if [ $((now - mtime)) -lt "$ttl_sec" ]; then
      continue
    fi
    local result_zip="${queue_dir}/results/result_${job_id}.zip"
    if [ -f "$result_zip" ]; then
      continue
    fi
    local dest="${jobs_dir}/${job_id}.json"
    mv "$lease_path" "$dest" 2>/dev/null || true
    rm -f "$meta_path" 2>/dev/null || true
    log "requeued stale lease: ${job_id}"
  done
  shopt -u nullglob
}

run_job() {
  local lease_path="$1"
  local queue_dir="$2"
  local workdir="$3"
  local heartbeat_interval="$4"
  local diag_timeout="$5"
  local print_summary="$6"
  local emit_triage_on_fail="$7"
  local reports_dir="$8"
  local telemetry_max_bytes="$9"

  local job_basename
  job_basename="$(basename "$lease_path")"
  local job_id="${job_basename%.json}"
  if json_valid "$lease_path"; then
    local json_job_id
    json_job_id="$(json_get_string "$lease_path" "job_id")"
    if [ -n "$json_job_id" ]; then
      job_id="$json_job_id"
    fi
  fi

  local run_dir="${workdir}/${job_id}"
  local build_dir="${run_dir}/build"
  local out_dir="${run_dir}/out"
  mkdir -p "$build_dir" "$out_dir"

  local stdout_log="${out_dir}/stdout.log"
  local stderr_log="${out_dir}/stderr.log"
  local player_log="${out_dir}/player.log"
  : > "$stdout_log"
  : > "$stderr_log"
  : > "$player_log"

  local start_utc
  start_utc="$(iso_utc)"
  local start_epoch
  start_epoch="$(date -u +%s)"
  local end_utc=""
  local duration_sec=0

  local commit=""
  local build_id=""
  local scenario_id=""
  local seed=""
  local timeout_sec=""
  local artifact_uri=""
  local param_overrides_json="{}"
  local feature_flags_json="{}"

  local error_context=""
  local repro_command=""
  local process_exit_code=""
  local exit_reason="$EXIT_REASON_INFRA"
  local runner_exit_code="$EXIT_CODE_INFRA_FAIL"

  if ! json_valid "$lease_path"; then
    error_context="job_json_invalid"
  else
    commit="$(json_get_string "$lease_path" "commit")"
    build_id="$(json_get_string "$lease_path" "build_id")"
    scenario_id="$(json_get_string "$lease_path" "scenario_id")"
    seed="$(json_get_string "$lease_path" "seed")"
    timeout_sec="$(json_get_string "$lease_path" "timeout_sec")"
    artifact_uri="$(json_get_string "$lease_path" "artifact_uri")"
    param_overrides_json="$(json_get_object_sorted "$lease_path" "param_overrides")"
    feature_flags_json="$(json_get_object_sorted "$lease_path" "feature_flags")"
  fi

  if [ -z "$error_context" ] && [ -z "$scenario_id" ]; then
    error_context="scenario_id_missing"
  fi
  if [ -z "$error_context" ] && [ -z "$seed" ]; then
    error_context="seed_missing"
  fi
  if [ -z "$error_context" ]; then
    if [ -z "$timeout_sec" ] || ! [[ "$timeout_sec" =~ ^[0-9]+$ ]] || [ "$timeout_sec" -le 0 ]; then
      timeout_sec=600
    fi
  fi
  if [ -z "$error_context" ] && [ -z "$artifact_uri" ]; then
    error_context="artifact_uri_missing"
  fi

  local lease_meta_path="${queue_dir}/leases/${job_id}.lease.json"
  local runner_host
  runner_host="$(hostname 2>/dev/null || uname -n 2>/dev/null || echo "unknown")"
  write_lease_meta "$lease_meta_path" "$job_id" "$runner_host" "$start_utc" ""

  local entrypoint_path=""
  local entrypoint_name=""
  local -a final_args=()

  if [ -z "$error_context" ]; then
    local resolved_artifact
    resolved_artifact="$(resolve_artifact_uri "$artifact_uri")"
    if [[ "$resolved_artifact" != /* ]]; then
      resolved_artifact="${queue_dir}/${resolved_artifact}"
    fi
    if [ ! -r "$resolved_artifact" ]; then
      error_context="artifact_unreadable:${resolved_artifact}"
    else
      cp -f "$resolved_artifact" "${run_dir}/artifact.zip" 2>/dev/null || error_context="artifact_copy_failed"
    fi
  fi

  if [ -z "$error_context" ]; then
    extract_zip "${run_dir}/artifact.zip" "$build_dir" 2>/dev/null || error_context="artifact_unzip_failed"
  fi

  local manifest_path="${build_dir}/build_manifest.json"
  if [ -z "$error_context" ]; then
    if [ ! -f "$manifest_path" ]; then
      error_context="build_manifest_missing"
    fi
  fi

  if [ -z "$error_context" ]; then
    local entrypoint
    entrypoint="$(json_get_string "$manifest_path" "entrypoint")"
    if [ -z "$entrypoint" ]; then
      error_context="entrypoint_missing"
    else
      if [[ "$entrypoint" = /* ]]; then
        entrypoint_path="$entrypoint"
      else
        entrypoint_path="${build_dir}/${entrypoint}"
      fi
    fi
  fi

  if [ -z "$error_context" ]; then
    if [ ! -f "$entrypoint_path" ]; then
      error_context="entrypoint_not_found:${entrypoint_path}"
    else
      if [ ! -x "$entrypoint_path" ]; then
        chmod +x "$entrypoint_path" 2>/dev/null || true
      fi
      if [ ! -x "$entrypoint_path" ]; then
        error_context="entrypoint_not_executable:${entrypoint_path}"
      fi
    fi
  fi

  if [ -z "$error_context" ]; then
    local entrypoint_real=""
    entrypoint_real="$(readlink -f "$entrypoint_path" 2>/dev/null || true)"
    if [ -n "$entrypoint_real" ]; then
      case "$entrypoint_real" in
        "$build_dir"/*) ;;
        *) error_context="entrypoint_outside_build:${entrypoint_real}" ;;
      esac
    fi
  fi

  if [ -z "$error_context" ] && json_array_nonempty "$manifest_path" "scenarios_supported"; then
    if ! json_array_contains "$manifest_path" "scenarios_supported" "$scenario_id"; then
      error_context="scenario_not_supported:${scenario_id}"
    fi
  fi

  if [ -z "$error_context" ]; then
    local -a default_args=()
    local -a job_args=()
    local -a default_args_stripped=()
    local -a job_args_stripped=()
    mapfile -t default_args < <(read_json_array_field "$manifest_path" "default_args")
    mapfile -t job_args < <(read_json_array_field "$lease_path" "args")
    strip_logfile_args default_args default_args_stripped
    strip_diagnostic_args default_args_stripped default_args_stripped
    strip_diagnostic_args job_args job_args_stripped

    local logfile_override=0
    if args_include_logfile "${job_args[@]}"; then
      logfile_override=1
    fi

    local telemetry_enabled=1
    if telemetry_disabled_in_args "${job_args[@]}"; then
      telemetry_enabled=0
    fi
    local telemetry_max_env=""
    if [ "$telemetry_enabled" -eq 1 ] && [ -n "$telemetry_max_bytes" ] && [ "$telemetry_max_bytes" -gt 0 ]; then
      telemetry_max_env="$telemetry_max_bytes"
    fi
    local perf_telemetry_env=""
    if [ -z "${PUREDOTS_PERF_TELEMETRY_PATH:-}" ]; then
      perf_telemetry_env="${out_dir}/perf_telemetry.ndjson"
    fi

    final_args=("${default_args_stripped[@]}" "${job_args_stripped[@]}")
    if ! args_include_flag "--scenario" "${final_args[@]}"; then
      final_args+=("--scenario" "$scenario_id")
    fi
    if ! args_include_flag "--seed" "${final_args[@]}"; then
      final_args+=("--seed" "$seed")
    fi

    final_args+=("--outDir" "$out_dir")
    final_args+=("--invariantsPath" "${out_dir}/invariants.json")
    final_args+=("--progressPath" "${out_dir}/progress.json")
    final_args+=("--telemetryPath" "${out_dir}/telemetry.ndjson")
    final_args+=("--telemetryEnabled" "$telemetry_enabled")

    if [ "$logfile_override" -eq 0 ]; then
      final_args+=("-logFile" "$player_log")
    fi

    repro_command="$(build_repro_command "$entrypoint_path" "$param_overrides_json" "$feature_flags_json" "${final_args[@]}")"
  fi

  local diag_ran=0
  local timed_out=0

  if [ -n "$error_context" ]; then
    exit_reason="$EXIT_REASON_INFRA"
    runner_exit_code="$EXIT_CODE_INFRA_FAIL"
  else
    entrypoint_name="$(basename "$entrypoint_path")"
    local orig_dir
    orig_dir="$(pwd)"
    cd "$build_dir" || true
    setsid -- env \
      TRI_PARAM_OVERRIDES="$param_overrides_json" \
      TRI_FEATURE_FLAGS="$feature_flags_json" \
      ${telemetry_max_env:+PUREDOTS_TELEMETRY_MAX_BYTES=$telemetry_max_env} \
      ${perf_telemetry_env:+PUREDOTS_PERF_TELEMETRY_PATH=$perf_telemetry_env} \
      "$entrypoint_path" "${final_args[@]}" >"$stdout_log" 2>"$stderr_log" &
    local pid=$!
    local pgid
    pgid="$(ps -o pgid= "$pid" 2>/dev/null | tr -d ' ' || true)"
    if [ -z "$pgid" ]; then
      pgid="$pid"
    fi
    write_lease_meta "$lease_meta_path" "$job_id" "$runner_host" "$start_utc" "$pid"
    local heartbeat_path="${run_dir}/heartbeat"
    local deadline=$((start_epoch + timeout_sec))
    local next_heartbeat=$start_epoch
    while kill -0 "$pid" 2>/dev/null; do
      local now
      now="$(date -u +%s)"
      if [ "$now" -ge "$deadline" ]; then
        timed_out=1
        run_diagnostics "timeout" "$out_dir" "$stdout_log" "$stderr_log" "$pid" "$pgid" "$entrypoint_name" "$diag_timeout"
        diag_ran=1
        kill -TERM -- "-$pgid" 2>/dev/null || true
        sleep 2
        kill -KILL -- "-$pgid" 2>/dev/null || true
        break
      fi
      if [ "$now" -ge "$next_heartbeat" ]; then
        touch "$heartbeat_path" 2>/dev/null || true
        touch "$lease_meta_path" 2>/dev/null || true
        touch "$lease_path" 2>/dev/null || true
        next_heartbeat=$((now + heartbeat_interval))
      fi
      sleep 1
    done
    wait "$pid" 2>/dev/null
    process_exit_code="$?"
    cd "$orig_dir" || true

    CURRENT_STDOUT_LOG="$stdout_log"
    CURRENT_STDERR_LOG="$stderr_log"
    CURRENT_PLAYER_LOG="$player_log"
    CURRENT_CORE_DUMP_PRESENT=0
    find_core_dump "$run_dir" "$build_dir" "$out_dir"
    if [ "$timed_out" -eq 1 ]; then
      exit_reason="$EXIT_REASON_HANG"
    else
      exit_reason="$(classify_exit_reason "$process_exit_code" "$timed_out")"
    fi
    runner_exit_code="$(exit_code_for_reason "$exit_reason")"
  fi

  if [ "$diag_ran" -eq 0 ]; then
    local diag_reason="post_exit"
    if [ -n "$error_context" ]; then
      diag_reason="infra"
    fi
    run_diagnostics "$diag_reason" "$out_dir" "$stdout_log" "$stderr_log" "" "" "$entrypoint_name" "$diag_timeout"
    diag_ran=1
  fi

  local error_line=""
  if [ -n "$error_context" ]; then
    error_line="$error_context"
  else
    error_line="$(extract_error_line)"
  fi
  local raw_signature
  raw_signature="$(normalize_signature "${exit_reason}|${scenario_id}|${error_line}|exit_code=${runner_exit_code}")"
  local failure_signature
  failure_signature="$(hash_signature "$raw_signature")"

  if [ -z "$repro_command" ]; then
    if [ -n "$error_context" ]; then
      repro_command="N/A: ${error_context}"
    else
      repro_command="N/A"
    fi
  fi
  printf '%s\n' "$repro_command" > "${out_dir}/repro.txt"

  write_watchdog_json "$out_dir" "$job_id" "$exit_reason" "$process_exit_code" "$runner_exit_code" "$raw_signature"

  end_utc="$(iso_utc)"
  local end_epoch
  end_epoch="$(date -u +%s)"
  duration_sec=$((end_epoch - start_epoch))

  local artifact_paths_json
  artifact_paths_json="$(build_artifact_paths_json "$out_dir")"
  write_meta_json "${run_dir}/meta.json" "$job_id" "$build_id" "$commit" "$scenario_id" "$seed" \
    "$start_utc" "$end_utc" "$duration_sec" "$exit_reason" "$runner_exit_code" \
    "$repro_command" "$failure_signature" "$artifact_paths_json" "$runner_host"

  run_ml_analyzer "${run_dir}/meta.json" "$out_dir"

  publish_result_zip "$run_dir" "$queue_dir" "$job_id"
  local triage_path=""
  if [ "$emit_triage_on_fail" -eq 1 ] && [ "$exit_reason" != "$EXIT_REASON_SUCCESS" ]; then
    local result_zip="${queue_dir}/results/result_${job_id}.zip"
    mkdir -p "$reports_dir"
    triage_path="${reports_dir}/triage_${job_id}.json"
    if [ -f "$TRIAGE_SCRIPT" ]; then
      "$PYTHON_BIN" "$TRIAGE_SCRIPT" --result-zip "$result_zip" --outdir "$reports_dir" >/dev/null 2>&1 || triage_path="triage_failed"
    else
      triage_path="triage_missing"
    fi
  fi
  if [ "$print_summary" -eq 1 ]; then
    if [ "$exit_reason" = "$EXIT_REASON_SUCCESS" ]; then
      print_summary_line "${run_dir}/meta.json" "$out_dir"
    else
      if [ -n "$triage_path" ]; then
        echo "${job_id} exit_reason=${exit_reason} exit_code=${runner_exit_code} failure_signature=${failure_signature} triage=${triage_path}"
      else
        echo "${job_id} exit_reason=${exit_reason} exit_code=${runner_exit_code} failure_signature=${failure_signature}"
      fi
    fi
  fi
  archive_lease "$lease_path" "$lease_meta_path" "$queue_dir" "$job_id"
}

run_once() {
  local queue_dir="$1"
  local workdir="$2"
  local heartbeat_interval="$3"
  local diag_timeout="$4"
  local print_summary="$5"
  local emit_triage_on_fail="$6"
  local reports_dir="$7"
  local telemetry_max_bytes="$8"
  local lease_path
  lease_path="$(claim_job "$queue_dir" || true)"
  if [ -z "$lease_path" ]; then
    return 1
  fi
  run_job "$lease_path" "$queue_dir" "$workdir" "$heartbeat_interval" "$diag_timeout" "$print_summary" "$emit_triage_on_fail" "$reports_dir" "$telemetry_max_bytes"
  return 0
}

daemon_loop() {
  local queue_dir="$1"
  local workdir="$2"
  local heartbeat_interval="$3"
  local diag_timeout="$4"
  local print_summary="$5"
  local emit_triage_on_fail="$6"
  local reports_dir="$7"
  local telemetry_max_bytes="$8"
  while true; do
    if ! run_once "$queue_dir" "$workdir" "$heartbeat_interval" "$diag_timeout" "$print_summary" "$emit_triage_on_fail" "$reports_dir" "$telemetry_max_bytes"; then
      sleep 2
    fi
  done
}

self_test() {
  local print_summary="$1"
  local emit_triage_on_fail="$2"
  local reports_dir="$3"
  local telemetry_max_bytes="$4"
  local tmp_root
  tmp_root="$(mktemp -d)"
  local queue_dir="${tmp_root}/queue"
  local workdir="${tmp_root}/runs"
  ensure_queue_dirs "$queue_dir"
  mkdir -p "$workdir"

  cat > "${queue_dir}/jobs/selftest_missing.json" <<'JSON'
{
  "job_id": "selftest_missing",
  "commit": "selftest",
  "build_id": "selftest_build",
  "scenario_id": "selftest_missing",
  "seed": 1,
  "timeout_sec": 3,
  "args": [],
  "param_overrides": {},
  "feature_flags": {},
  "artifact_uri": "/nonexistent/path/selftest_missing.zip"
}
JSON

  local artifact_root="${tmp_root}/artifact_build"
  mkdir -p "$artifact_root"
  cat > "${artifact_root}/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
exec /bin/sleep 9999
EOF
  chmod +x "${artifact_root}/entrypoint.sh"
  cat > "${artifact_root}/build_manifest.json" <<'JSON'
{
  "entrypoint": "entrypoint.sh",
  "default_args": [],
  "scenarios_supported": ["selftest_hang"]
}
JSON
  create_zip_from_dir "${tmp_root}/selftest_hang.zip" "$artifact_root"

  cat > "${queue_dir}/jobs/selftest_hang.json" <<JSON
{
  "job_id": "selftest_hang",
  "commit": "selftest",
  "build_id": "selftest_build",
  "scenario_id": "selftest_hang",
  "seed": 2,
  "timeout_sec": 2,
  "args": [],
  "param_overrides": {},
  "feature_flags": {},
  "artifact_uri": "${tmp_root}/selftest_hang.zip"
}
JSON

  run_once "$queue_dir" "$workdir" 1 5 "$print_summary" "$emit_triage_on_fail" "$reports_dir" "$telemetry_max_bytes" || true
  run_once "$queue_dir" "$workdir" 1 5 "$print_summary" "$emit_triage_on_fail" "$reports_dir" "$telemetry_max_bytes" || true

  local meta_missing="${workdir}/selftest_missing/meta.json"
  local meta_hang="${workdir}/selftest_hang/meta.json"
  if [ ! -f "$meta_missing" ] || [ ! -f "$meta_hang" ]; then
    log "self-test failed: missing meta.json"
    return 1
  fi
  local reason_missing
  local reason_hang
  reason_missing="$(json_get_string "$meta_missing" "exit_reason")"
  reason_hang="$(json_get_string "$meta_hang" "exit_reason")"
  if [ "$reason_missing" != "$EXIT_REASON_INFRA" ]; then
    log "self-test failed: expected INFRA_FAIL, got $reason_missing"
    return 1
  fi
  if [ "$reason_hang" != "$EXIT_REASON_HANG" ]; then
    log "self-test failed: expected HANG_TIMEOUT, got $reason_hang"
    return 1
  fi
  local zip_missing="${queue_dir}/results/result_selftest_missing.zip"
  local zip_hang="${queue_dir}/results/result_selftest_hang.zip"
  if [ ! -f "$zip_missing" ] || [ ! -f "$zip_hang" ]; then
    log "self-test failed: missing result zip"
    return 1
  fi
  log "self-test ok: results under ${queue_dir}/results"
  return 0
}

main() {
  local queue_dir=""
  local workdir="${HOME}/polish/runs"
  local mode="once"
  local heartbeat_interval=2
  local diag_timeout=15
  local print_summary=0
  local run_self_test=0
  local requeue_mode=0
  local ttl_sec=600
  local emit_triage_on_fail=1
  local reports_dir="$DEFAULT_REPORTS_DIR"
  local telemetry_max_bytes="$DEFAULT_TELEMETRY_MAX_BYTES"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --queue)
        queue_dir="$2"
        shift 2
        ;;
      --workdir)
        workdir="$2"
        shift 2
        ;;
      --once)
        mode="once"
        shift
        ;;
      --daemon)
        mode="daemon"
        shift
        ;;
      --heartbeat-interval)
        heartbeat_interval="$2"
        shift 2
        ;;
      --diag-timeout)
        diag_timeout="$2"
        shift 2
        ;;
      --print-summary)
        print_summary=1
        shift
        ;;
      --emit-triage-on-fail)
        emit_triage_on_fail=1
        shift
        ;;
      --reports-dir)
        reports_dir="$2"
        shift 2
        ;;
      --telemetry-max-bytes)
        telemetry_max_bytes="$2"
        shift 2
        ;;
      --requeue-stale-leases)
        requeue_mode=1
        shift
        ;;
      --ttl-sec)
        ttl_sec="$2"
        shift 2
        ;;
      --self-test)
        run_self_test=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log "unknown argument: $1"
        usage
        exit 2
        ;;
    esac
  done

  ensure_dependencies

  if [ "$run_self_test" -eq 1 ]; then
    self_test "$print_summary" "$emit_triage_on_fail" "$reports_dir" "$telemetry_max_bytes"
    exit $?
  fi

  if [ -z "$queue_dir" ]; then
    log "--queue is required"
    usage
    exit 2
  fi

  if [[ "$queue_dir" != /* ]]; then
    queue_dir="$(pwd)/${queue_dir}"
  fi
  if [[ "$workdir" != /* ]]; then
    workdir="$(pwd)/${workdir}"
  fi
  if [[ "$reports_dir" != /* ]]; then
    reports_dir="$(pwd)/${reports_dir}"
  fi

  if [ -z "$heartbeat_interval" ] || ! [[ "$heartbeat_interval" =~ ^[0-9]+$ ]] || [ "$heartbeat_interval" -le 0 ]; then
    heartbeat_interval=2
  fi
  if [ -z "$diag_timeout" ] || ! [[ "$diag_timeout" =~ ^[0-9]+$ ]] || [ "$diag_timeout" -le 0 ]; then
    diag_timeout=15
  fi
  if [ -z "$ttl_sec" ] || ! [[ "$ttl_sec" =~ ^[0-9]+$ ]] || [ "$ttl_sec" -le 0 ]; then
    ttl_sec=600
  fi
  if [ -z "$telemetry_max_bytes" ] || ! [[ "$telemetry_max_bytes" =~ ^[0-9]+$ ]] || [ "$telemetry_max_bytes" -le 0 ]; then
    telemetry_max_bytes="$DEFAULT_TELEMETRY_MAX_BYTES"
  fi

  ensure_queue_dirs "$queue_dir"

  if [ "$requeue_mode" -eq 1 ]; then
    requeue_stale_leases "$queue_dir" "$ttl_sec"
    exit 0
  fi

  if ! ensure_workdir_ext4 "$workdir"; then
    exit 2
  fi
  mkdir -p "$workdir"

  if [ "$mode" = "daemon" ]; then
    daemon_loop "$queue_dir" "$workdir" "$heartbeat_interval" "$diag_timeout" "$print_summary" "$emit_triage_on_fail" "$reports_dir" "$telemetry_max_bytes"
  else
    run_once "$queue_dir" "$workdir" "$heartbeat_interval" "$diag_timeout" "$print_summary" "$emit_triage_on_fail" "$reports_dir" "$telemetry_max_bytes" || true
  fi
}

main "$@"
