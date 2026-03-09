#!/usr/bin/env bash
set -euo pipefail

BASE="${CARROTLINK_SIDECAR_BASE:-/data/media/0/carrotlink_sidecar}"
HOST="${CARROTLINK_HUD_HOST:-0.0.0.0}"
PORT="${CARROTLINK_HUD_PORT:-7767}"

REPO="${CARROTLINK_OPENPILOT_REPO:-}"
if [ -z "${REPO}" ]; then
  for d in /data/openpilot /home/comma/openpilot /data/media/0/openpilot /data/openpilot_source/openpilot; do
    if [ -d "${d}" ]; then
      REPO="${d}"
      break
    fi
  done
fi

if [ -z "${REPO}" ]; then
  echo "[linkhud] openpilot repo not found"
  exit 2
fi

if [ -f "${REPO}/launch_env.sh" ]; then
  HAD_NOUNSET=0
  case "$-" in
    *u*)
      HAD_NOUNSET=1
      set +u
      ;;
  esac
  # shellcheck disable=SC1090
  source "${REPO}/launch_env.sh"
  if [ "${HAD_NOUNSET}" = "1" ]; then
    set -u
  fi
fi

if [ ! -f "${BASE}/carrot_linkhud.py" ]; then
  echo "[linkhud] missing hud python file: ${BASE}/carrot_linkhud.py"
  exit 3
fi

mkdir -p "${BASE}/logs"

export PYTHONPATH="${REPO}${PYTHONPATH:+:${PYTHONPATH}}"
export PYTHONUNBUFFERED=1
export CARROTLINK_OPENPILOT_REPO="${REPO}"
export CARROTLINK_SIDECAR_BASE="${BASE}"
export CARROTLINK_HUD_HOST="${HOST}"
export CARROTLINK_HUD_PORT="${PORT}"

cd "${REPO}"
exec python3 "${BASE}/carrot_linkhud.py"
