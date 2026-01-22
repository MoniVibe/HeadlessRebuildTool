#!/usr/bin/env bash
set -euo pipefail

INTEL_ROOT="${ANVILOOP_INTEL_ROOT:-/home/oni/anviloop_intel}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENV_DIR="${REPO_ROOT}/.venv"
LOG_FILE="${INTEL_ROOT}/logs/intel_daemon.log"

mkdir -p "${INTEL_ROOT}/logs"

if [ ! -d "${VENV_DIR}" ]; then
  python3 -m venv "${VENV_DIR}"
fi

source "${VENV_DIR}/bin/activate"

if ! pip show drain3 >/dev/null 2>&1; then
  if ! pip install -r "${REPO_ROOT}/Polish/Intel/requirements-wsl.txt"; then
    echo "WARN: pip install failed; continuing without optional deps."
  fi
fi

exec python3 "${REPO_ROOT}/Polish/Intel/anviloop_intel.py" daemon \
  --results-dir /mnt/c/polish/queue/results \
  --poll-sec 2 \
  >> "${LOG_FILE}" 2>&1
