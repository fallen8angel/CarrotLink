#!/usr/bin/env bash
set -euo pipefail

BASE="${CARROTLINK_SIDECAR_BASE:-/data/openpilot/selfdrive/carrot}"
PROFILE="${CARROTLINK_SIDECAR_PROFILE:-p1}"
HOST="${CARROTLINK_SIDECAR_HOST:-0.0.0.0}"
PORT="${CARROTLINK_SIDECAR_PORT:-7766}"

REPO="${CARROTLINK_OPENPILOT_REPO:-}"
if [ -z "${REPO}" ]; then
  for d in /data/openpilot /home/comma/openpilot; do
    if [ -d "${d}" ]; then
      REPO="${d}"
      break
    fi
  done
fi

if [ -z "${REPO}" ]; then
  echo "[sidecar] openpilot repo not found"
  exit 2
fi

if [ ! -f "${BASE}/carrot_linkview.py" ]; then
  echo "[sidecar] missing sidecar python file: ${BASE}/carrot_linkview.py"
  exit 3
fi

mkdir -p "${BASE}/logs"

export PYTHONPATH="${REPO}${PYTHONPATH:+:${PYTHONPATH}}"
export CARROTLINK_OPENPILOT_REPO="${REPO}"
export CARROTLINK_SIDECAR_BASE="${BASE}"
export CARROTLINK_SIDECAR_PROFILE="${PROFILE}"
export CARROTLINK_SIDECAR_HOST="${HOST}"
export CARROTLINK_SIDECAR_PORT="${PORT}"

exec python3 "${BASE}/carrot_linkview.py"
