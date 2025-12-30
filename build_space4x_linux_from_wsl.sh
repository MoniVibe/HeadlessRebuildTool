#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TRI_ROOT="${TRI_ROOT:-}"
if [ -z "$TRI_ROOT" ]; then
  for candidate in "/home/${USER}/Tri" "/home/oni/Tri"; do
    if [ -d "${candidate}/space4x" ]; then
      TRI_ROOT="$candidate"
      break
    fi
  done
fi

if [ -z "$TRI_ROOT" ]; then
  echo "TRI_ROOT not set and default Tri path not found. Set TRI_ROOT to your WSL Tri root (e.g., /home/oni/Tri)."
  exit 2
fi

TRI_WIN="${TRI_WIN:-C:\\dev\\Tri}"
UNITY_WIN="${UNITY_WIN:-C:\\Program Files\\Unity\\Hub\\Editor\\6000.3.1f1\\Editor\\Unity.exe}"
UNITY_LINUX="${UNITY_LINUX:-}"
FORCE_WINDOWS_UNITY="${FORCE_WINDOWS_UNITY:-1}"
FORCE_LINUX_UNITY="${FORCE_LINUX_UNITY:-0}"

resolve_git_hash() {
  local repo="$1"
  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$repo" rev-parse HEAD
  else
    echo "unknown"
  fi
}

log_git_head() {
  local repo="$1"
  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$repo" rev-parse HEAD
  else
    echo "git: n/a"
  fi
}

find_unity_linux() {
  local candidate=""
  if [ -n "$UNITY_LINUX" ] && [ -x "$UNITY_LINUX" ]; then
    echo "$UNITY_LINUX"
    return 0
  fi
  for candidate in \
    "$HOME/Unity/Hub/Editor/"*/Editor/Unity \
    "$HOME/.local/share/unityhub/Editor/"*/Editor/Unity \
    "$HOME/.local/share/UnityHub/Editor/"*/Editor/Unity; do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

UNITY_PATH=""
UNITY_MODE=""
PROJECT_DIR=""
PROJECT_DIR_WIN=""
TRI_WSL=""
LOG_PATH=""
LOG_PATH_WIN=""
BUILD_SRC=""

if [ "$FORCE_LINUX_UNITY" = "1" ]; then
  UNITY_PATH="$(find_unity_linux || true)"
  UNITY_MODE="linux"
else
  if command -v wslpath >/dev/null 2>&1; then
    UNITY_WSL="$(wslpath -a "$UNITY_WIN")"
    if [ -x "$UNITY_WSL" ]; then
      UNITY_PATH="$UNITY_WSL"
      UNITY_MODE="windows"
      TRI_WSL="$(wslpath -a "$TRI_WIN")"
      PROJECT_DIR="${TRI_WSL}/space4x"
      PROJECT_DIR_WIN="${TRI_WIN}\\space4x"
      LOG_PATH="${TRI_WSL}/space4x_headless_build.log"
      LOG_PATH_WIN="${TRI_WIN}\\space4x_headless_build.log"
      BUILD_SRC="${PROJECT_DIR}/Builds/Space4X_headless/Linux"
    fi
  fi
  if [ -z "$UNITY_PATH" ]; then
    if [ "$FORCE_WINDOWS_UNITY" = "1" ]; then
      echo "Windows Unity editor not found. Set UNITY_WIN/TRI_WIN or set FORCE_WINDOWS_UNITY=0 to allow Linux Unity."
      exit 2
    fi
    UNITY_PATH="$(find_unity_linux || true)"
    UNITY_MODE="linux"
  fi
fi

if [ -z "$UNITY_PATH" ]; then
  echo "Unity editor not found. Install Unity or set UNITY_LINUX/UNITY_WIN."
  exit 2
fi

if [ "$UNITY_MODE" = "linux" ]; then
  PROJECT_DIR="${TRI_ROOT}/space4x"
  LOG_PATH="${TRI_ROOT}/space4x_headless_build.log"
  BUILD_SRC="${PROJECT_DIR}/Builds/Space4X_headless/Linux"
fi

UNITY_VERSION="$(basename "$(dirname "$(dirname "$UNITY_PATH")")")"
if [ -z "$UNITY_VERSION" ]; then
  UNITY_VERSION="unknown"
fi

PUREDOTS_DIR="${TRI_ROOT}/puredots"
GODGAME_DIR="${TRI_ROOT}/godgame"
if [ "$UNITY_MODE" = "windows" ]; then
  PUREDOTS_DIR="${TRI_WSL}/puredots"
  GODGAME_DIR="${TRI_WSL}/godgame"
fi

BUILD_BIN="${BUILD_SRC}/Space4X_Headless.x86_64"
PUBLISH_ROOT="${PUBLISH_ROOT:-${TRI_ROOT}/Tools/builds/space4x}"
LATEST_DIR="${PUBLISH_ROOT}/Linux_latest"
STAMP_FILE="${LATEST_DIR}/build_stamp.txt"
SPACE4X_HASH="$(resolve_git_hash "${PROJECT_DIR}")"
PUREDOTS_HASH="$(resolve_git_hash "${PUREDOTS_DIR}")"
RUNBOOK_PATH="${PUREDOTS_DIR}/Docs/Headless/headless_runbook.md"
BANK_REV="unknown"
if [ -f "$RUNBOOK_PATH" ]; then
  BANK_REV="$(sha256sum "$RUNBOOK_PATH" | awk '{print $1}')"
fi
BUILD_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "BUILD_STAMP:project=Space4X sha=${SPACE4X_HASH} utc=${BUILD_UTC} unity=${UNITY_VERSION} platform=linux headless=1 bank_rev=${BANK_REV}"
echo "Unity: ${UNITY_PATH} (${UNITY_MODE})"

echo "pwd:"
pwd
echo "space4x HEAD:"
log_git_head "${PROJECT_DIR}"
echo "puredots HEAD:"
log_git_head "${PUREDOTS_DIR}"
echo "godgame HEAD:"
log_git_head "${GODGAME_DIR}"

if [ "$SPACE4X_HASH" != "unknown" ] && [ "$PUREDOTS_HASH" != "unknown" ] && [ -f "$STAMP_FILE" ] && [ -f "$BUILD_BIN" ]; then
  STAMP_SPACE4X="$(sed -n "s/^space4x_commit=//p" "$STAMP_FILE" | head -n 1)"
  STAMP_PUREDOTS="$(sed -n "s/^puredots_commit=//p" "$STAMP_FILE" | head -n 1)"
  if [ "$STAMP_SPACE4X" = "$SPACE4X_HASH" ] && [ "$STAMP_PUREDOTS" = "$PUREDOTS_HASH" ]; then
    echo "Build up-to-date for space4x=${SPACE4X_HASH} puredots=${PUREDOTS_HASH}; skipping rebuild."
    exit 0
  fi
fi

if [ "$UNITY_MODE" = "windows" ]; then
  "$UNITY_PATH" -batchmode -quit -nographics \
    -projectPath "$PROJECT_DIR_WIN" \
    -executeMethod Space4X.Headless.Editor.Space4XHeadlessBuilder.BuildLinuxHeadless \
    -logFile "$LOG_PATH_WIN"
else
  "$UNITY_PATH" -batchmode -quit -nographics \
    -projectPath "$PROJECT_DIR" \
    -executeMethod Space4X.Headless.Editor.Space4XHeadlessBuilder.BuildLinuxHeadless \
    -logFile "$LOG_PATH"
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
DST="${PUBLISH_ROOT}/Linux_${STAMP}"

if [ ! -d "$BUILD_SRC" ]; then
  echo "Build output missing: $BUILD_SRC"
  exit 2
fi

mkdir -p "$PUBLISH_ROOT"
cp -a "$BUILD_SRC" "$DST"
chmod +x "$DST/Space4X_Headless.x86_64" || true
rm -rf "$LATEST_DIR"
cp -a "$DST" "$LATEST_DIR"
LATEST_BIN="${LATEST_DIR}/Space4X_Headless.x86_64"
BIN_MTIME="$(stat -c %y "$LATEST_BIN" 2>/dev/null || true)"
cat > "$STAMP_FILE" <<EOF
space4x_commit=${SPACE4X_HASH}
puredots_commit=${PUREDOTS_HASH}
unity=${UNITY_VERSION}
timestamp=${STAMP}
binary_mtime=${BIN_MTIME}
build_log=${LOG_PATH_WIN:-$LOG_PATH}
EOF

echo "Built: $DST"
