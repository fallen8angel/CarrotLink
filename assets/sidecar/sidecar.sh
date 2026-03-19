#!/usr/bin/env bash
set -euo pipefail

BASE="${CARROTLINK_SIDECAR_BASE:-/data/media/0/carrotlink_sidecar}"
PROFILE="${CARROTLINK_SIDECAR_PROFILE:-p2d}"
VARIANT="${CARROTLINK_SIDECAR_VARIANT:-default}"
HOST="${CARROTLINK_SIDECAR_HOST:-0.0.0.0}"
PORT="${CARROTLINK_SIDECAR_PORT:-7766}"
CAMERA_QUALITY_MODE="${CARROTLINK_CAMERA_QUALITY_MODE:-stable}"

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
  echo "[sidecar] openpilot repo not found"
  exit 2
fi

if [ -f "${REPO}/launch_env.sh" ]; then
  # Match openpilot's runtime environment as closely as possible.
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

if [ ! -f "${BASE}/sidecar.py" ]; then
  echo "[sidecar] missing sidecar python file: ${BASE}/sidecar.py"
  exit 3
fi

mkdir -p "${BASE}/logs" "${BASE}/pydeps"

export PYTHONPATH="${BASE}/pydeps:${REPO}${PYTHONPATH:+:${PYTHONPATH}}"
export PYTHONUNBUFFERED=1
export CARROTLINK_OPENPILOT_REPO="${REPO}"
export CARROTLINK_SIDECAR_BASE="${BASE}"
export CARROTLINK_SIDECAR_PROFILE="${PROFILE}"
export CARROTLINK_SIDECAR_VARIANT="${VARIANT}"
export CARROTLINK_SIDECAR_HOST="${HOST}"
export CARROTLINK_SIDECAR_PORT="${PORT}"
export CARROTLINK_CAMERA_QUALITY_MODE="${CAMERA_QUALITY_MODE}"

cd "${REPO}"
exec python3 "${BASE}/sidecar.py"
