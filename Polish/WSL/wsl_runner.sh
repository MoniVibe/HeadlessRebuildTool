#!/usr/bin/env bash
set -u
set -o pipefail

RUNNER_VERSION="wsl_runner/0.1"

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

LAST_DIAG_START_UTC=""
LAST_DIAG_END_UTC=""
LAST_DIAG_REASON=""
CURRENT_STDOUT_LOG=""
CURRENT_STDERR_LOG=""

log() {
  echo "wsl_runner: $*" >&2
}

usage() {
  cat <<'EOF'
Usage: wsl_runner.sh --queue <path> [--workdir <path>] [--once|--daemon]
                    [--heartbeat-interval <sec>] [--diag-timeout <sec>] [--self-test]

Options:
  --queue <path>              Queue root (required unless --self-test).
  --workdir <path>            Run root (default: ~/polish/runs).
  --once                      Process one job and exit (default).
  --daemon                    Poll forever.
  --heartbeat-interval <sec>  Heartbeat interval seconds (default: 2).
  --diag-timeout <sec>        Diagnostics timeout seconds (default: 15).
  --self-test                 Run local self-test scenarios.
EOF
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
  for cmd in jq unzip zip timeout sha256sum ps sed awk date; do
    if ! require_cmd "$cmd"; then
      missing=1
    fi
  done
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

read_json_array_field() {
  local file="$1"
  local field="$2"
  jq -r --arg field "$field" '
    .[$field] |
    if type=="array" then .[]
    elif type=="string" then .
    else empty
    end
  ' "$file" 2>/dev/null || true
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
  local pattern='segmentation fault|sigsegv|signal 11|crash!!!|unityplayer\.so|fatal error'
  tail_match "$CURRENT_STDOUT_LOG" "$pattern" || tail_match "$CURRENT_STDERR_LOG" "$pattern"
}

test_fail_marker_present() {
  local pattern='assert fail|invariant fail|scenario failed|assertion failed'
  tail_match "$CURRENT_STDOUT_LOG" "$pattern" || tail_match "$CURRENT_STDERR_LOG" "$pattern"
}

classify_exit_reason() {
  local process_exit_code="$1"
  local timed_out="$2"
  if [ "$timed_out" -eq 1 ]; then
    echo "$EXIT_REASON_HANG"
    return 0
  fi
  if [ "$process_exit_code" -eq 0 ]; then
    if scenario_complete_marker_present; then
      echo "$EXIT_REASON_SUCCESS"
    else
      echo "$EXIT_REASON_CRASH"
    fi
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
  if [ "$process_exit_code" -eq "$EXIT_CODE_CRASH" ]; then
    echo "$EXIT_REASON_CRASH"
    return 0
  fi
  if crash_marker_present; then
    echo "$EXIT_REASON_CRASH"
    return 0
  fi
  if test_fail_marker_present; then
    echo "$EXIT_REASON_TEST_FAIL"
    return 0
  fi
  if ! scenario_complete_marker_present; then
    echo "$EXIT_REASON_CRASH"
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

  local stdout_tail_json
  local stderr_tail_json
  stdout_tail_json=$(jq -R -s -c 'split("\n") | if length>0 and .[-1]=="" then .[:-1] else . end' < "$out_dir/diag_stdout_tail.txt" 2>/dev/null || echo "[]")
  stderr_tail_json=$(jq -R -s -c 'split("\n") | if length>0 and .[-1]=="" then .[:-1] else . end' < "$out_dir/diag_stderr_tail.txt" 2>/dev/null || echo "[]")
  local ps_snapshot
  ps_snapshot="$(cat "$out_dir/ps_snapshot.txt" 2>/dev/null || true)"
  local uname_line
  uname_line="$(uname -a 2>/dev/null || true)"
  local proc_version
  proc_version="$(cat /proc/version 2>/dev/null || true)"
  local gdb_bt_path=""
  local system_snapshot_path=""
  local core_dump_path=""
  if [ -f "$out_dir/gdb_bt.txt" ]; then
    gdb_bt_path="out/gdb_bt.txt"
  fi
  if [ -f "$out_dir/system_snapshot.txt" ]; then
    system_snapshot_path="out/system_snapshot.txt"
  fi
  if [ -f "$out_dir/core_dump_path.txt" ]; then
    core_dump_path="out/core_dump_path.txt"
  fi
  jq -n \
    --arg job_id "$job_id" \
    --arg exit_reason "$exit_reason" \
    --arg process_exit_code "$process_exit_code" \
    --arg runner_exit_code "$runner_exit_code" \
    --arg raw_signature_string "$raw_signature" \
    --arg diag_reason "$LAST_DIAG_REASON" \
    --arg diag_start_utc "$LAST_DIAG_START_UTC" \
    --arg diag_end_utc "$LAST_DIAG_END_UTC" \
    --argjson stdout_tail "$stdout_tail_json" \
    --argjson stderr_tail "$stderr_tail_json" \
    --arg ps_snapshot "$ps_snapshot" \
    --arg uname "$uname_line" \
    --arg proc_version "$proc_version" \
    --arg runner_version "$RUNNER_VERSION" \
    --arg gdb_bt_path "$gdb_bt_path" \
    --arg system_snapshot_path "$system_snapshot_path" \
    --arg core_dump_path "$core_dump_path" \
    '{
      job_id: $job_id,
      exit_reason: $exit_reason,
      process_exit_code: (if $process_exit_code == "" then null else ($process_exit_code | tonumber?) end),
      runner_exit_code: (if $runner_exit_code == "" then null else ($runner_exit_code | tonumber?) end),
      raw_signature_string: $raw_signature_string,
      diag_reason: $diag_reason,
      diag_start_utc: $diag_start_utc,
      diag_end_utc: $diag_end_utc,
      stdout_tail: $stdout_tail,
      stderr_tail: $stderr_tail,
      ps_snapshot: $ps_snapshot,
      uname: $uname,
      proc_version: $proc_version,
      runner_version: $runner_version,
      gdb_bt_path: (if $gdb_bt_path == "" then null else $gdb_bt_path end),
      system_snapshot_path: (if $system_snapshot_path == "" then null else $system_snapshot_path end),
      core_dump_path: (if $core_dump_path == "" then null else $core_dump_path end)
    }' > "$out_dir/watchdog.json"
}

build_artifact_paths_json() {
  local out_dir="$1"
  local stdout_rel="out/stdout.log"
  local stderr_rel="out/stderr.log"
  local player_rel="out/player.log"
  local watchdog_rel="out/watchdog.json"
  local repro_rel="out/repro.txt"
  local diag_stdout_rel="out/diag_stdout_tail.txt"
  local diag_stderr_rel="out/diag_stderr_tail.txt"
  local system_snapshot_rel="out/system_snapshot.txt"
  local ps_snapshot_rel="out/ps_snapshot.txt"
  local gdb_rel="out/gdb_bt.txt"
  local core_rel="out/core_dump_path.txt"

  [ -f "$out_dir/stdout.log" ] || stdout_rel=""
  [ -f "$out_dir/stderr.log" ] || stderr_rel=""
  [ -f "$out_dir/player.log" ] || player_rel=""
  [ -f "$out_dir/watchdog.json" ] || watchdog_rel=""
  [ -f "$out_dir/repro.txt" ] || repro_rel=""
  [ -f "$out_dir/diag_stdout_tail.txt" ] || diag_stdout_rel=""
  [ -f "$out_dir/diag_stderr_tail.txt" ] || diag_stderr_rel=""
  [ -f "$out_dir/system_snapshot.txt" ] || system_snapshot_rel=""
  [ -f "$out_dir/ps_snapshot.txt" ] || ps_snapshot_rel=""
  [ -f "$out_dir/gdb_bt.txt" ] || gdb_rel=""
  [ -f "$out_dir/core_dump_path.txt" ] || core_rel=""

  jq -n \
    --arg stdout_log "$stdout_rel" \
    --arg stderr_log "$stderr_rel" \
    --arg player_log "$player_rel" \
    --arg watchdog "$watchdog_rel" \
    --arg repro "$repro_rel" \
    --arg diag_stdout "$diag_stdout_rel" \
    --arg diag_stderr "$diag_stderr_rel" \
    --arg system_snapshot "$system_snapshot_rel" \
    --arg ps_snapshot "$ps_snapshot_rel" \
    --arg gdb_bt "$gdb_rel" \
    --arg core_dump "$core_rel" \
    'def add(key; val): if val == "" then . else . + { (key): val } end;
     {} |
     add("stdout_log"; $stdout_log) |
     add("stderr_log"; $stderr_log) |
     add("player_log"; $player_log) |
     add("watchdog"; $watchdog) |
     add("repro"; $repro) |
     add("diag_stdout_tail"; $diag_stdout) |
     add("diag_stderr_tail"; $diag_stderr) |
     add("system_snapshot"; $system_snapshot) |
     add("ps_snapshot"; $ps_snapshot) |
     add("gdb_bt"; $gdb_bt) |
     add("core_dump_path"; $core_dump)'
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

  jq -n \
    --arg job_id "$job_id" \
    --arg build_id "$build_id" \
    --arg commit "$commit" \
    --arg scenario_id "$scenario_id" \
    --arg seed "$seed" \
    --arg start_utc "$start_utc" \
    --arg end_utc "$end_utc" \
    --argjson duration_sec "$duration_sec" \
    --arg exit_reason "$exit_reason" \
    --argjson exit_code "$exit_code" \
    --arg repro_command "$repro_command" \
    --arg failure_signature "$failure_signature" \
    --arg runner_host "$runner_host" \
    --arg runner_env "wsl" \
    --argjson artifact_paths "$artifact_paths_json" \
    '{
      job_id: $job_id,
      build_id: $build_id,
      commit: $commit,
      scenario_id: $scenario_id,
      seed: (if $seed == "" then null else ($seed | tonumber?) end),
      start_utc: $start_utc,
      end_utc: $end_utc,
      duration_sec: $duration_sec,
      exit_reason: $exit_reason,
      exit_code: $exit_code,
      repro_command: $repro_command,
      failure_signature: $failure_signature,
      artifact_paths: $artifact_paths,
      runner_host: $runner_host,
      runner_env: $runner_env
    }' > "$meta_path"
}

publish_result_zip() {
  local run_dir="$1"
  local queue_dir="$2"
  local job_id="$3"

  local staging_zip="${run_dir}/result_${job_id}.zip"
  (cd "$run_dir" && zip -q -r "$staging_zip" "meta.json" "out")
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
  jq -n \
    --arg job_id "$job_id" \
    --arg runner_host "$runner_host" \
    --arg lease_start_utc "$lease_start_utc" \
    '{job_id: $job_id, runner_host: $runner_host, lease_start_utc: $lease_start_utc}' > "$lease_meta_path"
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
  for candidate in "$run_dir"/core* "$build_dir"/core*; do
    if [ -f "$candidate" ]; then
      core_path="$candidate"
      break
    fi
  done
  if [ -n "$core_path" ]; then
    echo "$core_path" > "$out_dir/core_dump_path.txt"
  fi
}

run_job() {
  local lease_path="$1"
  local queue_dir="$2"
  local workdir="$3"
  local heartbeat_interval="$4"
  local diag_timeout="$5"

  local job_basename
  job_basename="$(basename "$lease_path")"
  local job_id="${job_basename%.json}"
  if jq -e . "$lease_path" >/dev/null 2>&1; then
    local json_job_id
    json_job_id="$(jq -r '.job_id // empty' "$lease_path" 2>/dev/null || true)"
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

  if ! jq -e . "$lease_path" >/dev/null 2>&1; then
    error_context="job_json_invalid"
  else
    commit="$(jq -r '.commit // empty' "$lease_path" 2>/dev/null || true)"
    build_id="$(jq -r '.build_id // empty' "$lease_path" 2>/dev/null || true)"
    scenario_id="$(jq -r '.scenario_id // empty' "$lease_path" 2>/dev/null || true)"
    seed="$(jq -r '.seed // empty' "$lease_path" 2>/dev/null || true)"
    timeout_sec="$(jq -r '.timeout_sec // empty' "$lease_path" 2>/dev/null || true)"
    artifact_uri="$(jq -r '.artifact_uri // empty' "$lease_path" 2>/dev/null || true)"
    param_overrides_json="$(jq -c --sort-keys '.param_overrides // {}' "$lease_path" 2>/dev/null || echo "{}")"
    feature_flags_json="$(jq -c --sort-keys '.feature_flags // {}' "$lease_path" 2>/dev/null || echo "{}")"
  fi

  if [ -z "$error_context" ]; then
    if [ -z "$scenario_id" ]; then
      error_context="scenario_id_missing"
    fi
  fi
  if [ -z "$error_context" ]; then
    if [ -z "$seed" ]; then
      error_context="seed_missing"
    fi
  fi
  if [ -z "$error_context" ]; then
    if [ -z "$timeout_sec" ] || ! [[ "$timeout_sec" =~ ^[0-9]+$ ]] || [ "$timeout_sec" -le 0 ]; then
      timeout_sec=600
    fi
  fi
  if [ -z "$error_context" ]; then
    if [ -z "$artifact_uri" ]; then
      error_context="artifact_uri_missing"
    fi
  fi

  local lease_meta_path="${queue_dir}/leases/${job_id}.lease.json"
  local runner_host
  runner_host="$(hostname 2>/dev/null || uname -n 2>/dev/null || echo "unknown")"
  write_lease_meta "$lease_meta_path" "$job_id" "$runner_host" "$start_utc"

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
    unzip -q "${run_dir}/artifact.zip" -d "$build_dir" 2>/dev/null || error_context="artifact_unzip_failed"
  fi

  local manifest_path="${build_dir}/build_manifest.json"
  if [ -z "$error_context" ]; then
    if [ ! -f "$manifest_path" ]; then
      error_context="build_manifest_missing"
    fi
  fi

  if [ -z "$error_context" ]; then
    local entrypoint
    entrypoint="$(jq -r '.entrypoint // empty' "$manifest_path" 2>/dev/null || true)"
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

  if [ -z "$error_context" ]; then
    if jq -e '.scenarios_supported and (.scenarios_supported | length > 0)' "$manifest_path" >/dev/null 2>&1; then
      if ! jq -e --arg scenario "$scenario_id" '.scenarios_supported | index($scenario)' "$manifest_path" >/dev/null 2>&1; then
        error_context="scenario_not_supported:${scenario_id}"
      fi
    fi
  fi

  if [ -z "$error_context" ]; then
    local -a default_args=()
    local -a job_args=()
    local -a default_args_stripped=()
    mapfile -t default_args < <(read_json_array_field "$manifest_path" "default_args")
    mapfile -t job_args < <(read_json_array_field "$lease_path" "args")
    strip_logfile_args default_args default_args_stripped

    local logfile_override=0
    if args_include_logfile "${job_args[@]}"; then
      logfile_override=1
    fi

    final_args=("${default_args_stripped[@]}" "${job_args[@]}")
    if ! args_include_flag "--scenario" "${final_args[@]}"; then
      final_args+=("--scenario" "$scenario_id")
    fi
    if ! args_include_flag "--seed" "${final_args[@]}"; then
      final_args+=("--seed" "$seed")
    fi
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
      "$entrypoint_path" "${final_args[@]}" >"$stdout_log" 2>"$stderr_log" &
    local pid=$!
    local pgid
    pgid="$(ps -o pgid= "$pid" 2>/dev/null | tr -d ' ' || true)"
    if [ -z "$pgid" ]; then
      pgid="$pid"
    fi
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
        next_heartbeat=$((now + heartbeat_interval))
      fi
      sleep 1
    done
    wait "$pid" 2>/dev/null
    process_exit_code="$?"
    cd "$orig_dir" || true

    CURRENT_STDOUT_LOG="$stdout_log"
    CURRENT_STDERR_LOG="$stderr_log"
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

  if [ "$exit_reason" != "$EXIT_REASON_SUCCESS" ]; then
    find_core_dump "$run_dir" "$build_dir" "$out_dir"
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

  publish_result_zip "$run_dir" "$queue_dir" "$job_id"
  archive_lease "$lease_path" "$lease_meta_path" "$queue_dir" "$job_id"
}

run_once() {
  local queue_dir="$1"
  local workdir="$2"
  local heartbeat_interval="$3"
  local diag_timeout="$4"
  local lease_path
  lease_path="$(claim_job "$queue_dir" || true)"
  if [ -z "$lease_path" ]; then
    return 1
  fi
  run_job "$lease_path" "$queue_dir" "$workdir" "$heartbeat_interval" "$diag_timeout"
  return 0
}

daemon_loop() {
  local queue_dir="$1"
  local workdir="$2"
  local heartbeat_interval="$3"
  local diag_timeout="$4"
  while true; do
    if ! run_once "$queue_dir" "$workdir" "$heartbeat_interval" "$diag_timeout"; then
      sleep 2
    fi
  done
}

self_test() {
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
  (cd "$artifact_root" && zip -q -r "${tmp_root}/selftest_hang.zip" .)

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

  run_once "$queue_dir" "$workdir" 1 5 || true
  run_once "$queue_dir" "$workdir" 1 5 || true

  local meta_missing="${workdir}/selftest_missing/meta.json"
  local meta_hang="${workdir}/selftest_hang/meta.json"
  if [ ! -f "$meta_missing" ] || [ ! -f "$meta_hang" ]; then
    log "self-test failed: missing meta.json"
    return 1
  fi
  local reason_missing
  local reason_hang
  reason_missing="$(jq -r '.exit_reason // empty' "$meta_missing")"
  reason_hang="$(jq -r '.exit_reason // empty' "$meta_hang")"
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
  local run_self_test=0

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

  if [ "$run_self_test" -eq 1 ]; then
    ensure_dependencies
    self_test
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

  if ! ensure_workdir_ext4 "$workdir"; then
    exit 2
  fi

  if [ -z "$heartbeat_interval" ] || ! [[ "$heartbeat_interval" =~ ^[0-9]+$ ]] || [ "$heartbeat_interval" -le 0 ]; then
    heartbeat_interval=2
  fi
  if [ -z "$diag_timeout" ] || ! [[ "$diag_timeout" =~ ^[0-9]+$ ]] || [ "$diag_timeout" -le 0 ]; then
    diag_timeout=15
  fi

  ensure_dependencies
  ensure_queue_dirs "$queue_dir"
  mkdir -p "$workdir"

  if [ "$mode" = "daemon" ]; then
    daemon_loop "$queue_dir" "$workdir" "$heartbeat_interval" "$diag_timeout"
  else
    run_once "$queue_dir" "$workdir" "$heartbeat_interval" "$diag_timeout" || true
  fi
}

main "$@"
