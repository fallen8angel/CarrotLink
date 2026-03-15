#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <executorch-dir>" >&2
  exit 1
fi

EXECUTORCH_DIR="$(cd "$1" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
BUILD_DIR="${EXECUTORCH_BUILD_DIR:-$EXECUTORCH_DIR/cmake-out-qnn-host}"
QNN_SDK_ROOT="${QNN_SDK_ROOT:-${QNN_STAGING_DIR:-$EXECUTORCH_DIR/.qnn-staging}/sdk}"

if [[ ! -d "$EXECUTORCH_DIR" ]]; then
  echo "[qnn-host] executorch dir not found: $EXECUTORCH_DIR" >&2
  exit 1
fi

echo "[qnn-host] executorch_dir=$EXECUTORCH_DIR" >&2
echo "[qnn-host] build_dir=$BUILD_DIR" >&2
echo "[qnn-host] qnn_sdk_root=$QNN_SDK_ROOT" >&2

cd "$EXECUTORCH_DIR"
git submodule update --init --recursive

mkdir -p "$(dirname "$QNN_SDK_ROOT")"
if [[ -d "$QNN_SDK_ROOT/lib" ]]; then
  echo "[qnn-host] reusing cached QNN SDK at $QNN_SDK_ROOT" >&2
else
  "$PYTHON_BIN" backends/qualcomm/scripts/download_qnn_sdk.py \
    --dst-folder "$QNN_SDK_ROOT" \
    --print-sdk-path >/dev/null
fi

cmake -S "$EXECUTORCH_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$BUILD_DIR" \
  -DEXECUTORCH_BUILD_QNN=ON \
  -DEXECUTORCH_BUILD_DEVTOOLS=ON \
  -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON \
  -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON \
  -DEXECUTORCH_BUILD_EXTENSION_FLAT_TENSOR=ON \
  -DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON \
  -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON \
  -DEXECUTORCH_ENABLE_EVENT_TRACER=ON \
  -DQNN_SDK_ROOT="$QNN_SDK_ROOT" \
  -DPYTHON_EXECUTABLE="$PYTHON_BIN"

cmake --build "$BUILD_DIR" --target PyQnnManagerAdaptor -j"$(nproc)"

mapfile -t adaptor_files < <(find "$BUILD_DIR/backends/qualcomm" -maxdepth 1 -name 'PyQnnManagerAdaptor*.so' -print)
if [[ ${#adaptor_files[@]} -eq 0 ]]; then
  echo "[qnn-host] PyQnnManagerAdaptor build succeeded but no .so was found." >&2
  exit 1
fi

mkdir -p "$EXECUTORCH_DIR/backends/qualcomm/python"
for adaptor_file in "${adaptor_files[@]}"; do
  cp -f "$adaptor_file" "$EXECUTORCH_DIR/backends/qualcomm/python/"
done

cp -f "$EXECUTORCH_DIR/schema/program.fbs" "$EXECUTORCH_DIR/exir/_serialize/program.fbs"
cp -f "$EXECUTORCH_DIR/schema/scalar_type.fbs" "$EXECUTORCH_DIR/exir/_serialize/scalar_type.fbs"

echo "[qnn-host] adaptor copied to $EXECUTORCH_DIR/backends/qualcomm/python" >&2
echo "[qnn-host] ready with QNN_SDK_ROOT=$QNN_SDK_ROOT" >&2
