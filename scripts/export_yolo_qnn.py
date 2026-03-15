#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _parse_args() -> argparse.Namespace:
  parser = argparse.ArgumentParser(
      description=(
          "Export Ultralytics YOLO weights into a QNN-lowered ExecuTorch .pte."
      )
  )
  parser.add_argument("--weights", required=True, help="Path to .pt YOLO weights.")
  parser.add_argument(
      "--output-dir",
      default="build/qnn_export",
      help="Directory where export artifacts are written.",
  )
  parser.add_argument(
      "--output-name",
      default="",
      help="Base filename for the generated .pte. Defaults to <weights>_qnn.",
  )
  parser.add_argument(
      "--soc",
      default="SM8750",
      help="Qualcomm SoC name, e.g. SM8750 for Snapdragon 8 Elite.",
  )
  parser.add_argument(
      "--imgsz",
      type=int,
      default=416,
      help="Square input size for export. Default: 416",
  )
  parser.add_argument(
      "--batch",
      type=int,
      default=1,
      help="Batch size for example input. Default: 1",
  )
  parser.add_argument(
      "--use-fp16",
      action="store_true",
      help="Lower for HTP FP16 instead of quantized HTP.",
  )
  return parser.parse_args()


def _fail(message: str, *, exit_code: int = 1) -> None:
  print(message, file=sys.stderr)
  raise SystemExit(exit_code)


def _load_runtime():
  try:
    import torch  # type: ignore
  except Exception as exc:
    _fail(f"[qnn-export] torch import failed: {exc!r}")

  try:
    from ultralytics import YOLO  # type: ignore
  except Exception as exc:
    _fail(f"[qnn-export] ultralytics import failed: {exc!r}")

  try:
    from executorch.backends.qualcomm.utils.utils import (  # type: ignore
        generate_htp_compiler_spec,
        generate_qnn_executorch_compiler_spec,
        get_soc_to_chipset_map,
        to_edge_transform_and_lower_to_qnn,
    )
    from executorch.exir.capture._config import ExecutorchBackendConfig  # type: ignore
    from executorch.extension.export_util.utils import save_pte_program  # type: ignore
  except Exception as exc:
    _fail(f"[qnn-export] executorch QNN imports failed: {exc!r}")

  try:
    from executorch.exir.backend.utils import format_delegated_graph  # type: ignore
  except Exception:
    format_delegated_graph = None

  return {
      "torch": torch,
      "YOLO": YOLO,
      "generate_htp_compiler_spec": generate_htp_compiler_spec,
      "generate_qnn_executorch_compiler_spec": generate_qnn_executorch_compiler_spec,
      "get_soc_to_chipset_map": get_soc_to_chipset_map,
      "to_edge_transform_and_lower_to_qnn": to_edge_transform_and_lower_to_qnn,
      "ExecutorchBackendConfig": ExecutorchBackendConfig,
      "save_pte_program": save_pte_program,
      "format_delegated_graph": format_delegated_graph,
  }


def _normalize_output(value):
  import torch

  if isinstance(value, torch.Tensor):
    return value
  if isinstance(value, tuple):
    return tuple(_normalize_output(item) for item in value)
  if isinstance(value, list):
    return tuple(_normalize_output(item) for item in value)
  if isinstance(value, dict):
    return tuple(_normalize_output(value[key]) for key in sorted(value.keys()))
  raise TypeError(f"Unsupported output type for export: {type(value)!r}")


def _apply_export_flags(module: torch.nn.Module) -> None:
  module.eval()
  if hasattr(module, "fuse"):
    try:
      module.fuse()
    except Exception:
      pass

  for submodule in module.modules():
    if hasattr(submodule, "export"):
      try:
        submodule.export = True
      except Exception:
        pass
    if hasattr(submodule, "dynamic"):
      try:
        submodule.dynamic = False
      except Exception:
        pass
    if hasattr(submodule, "format"):
      try:
        submodule.format = "executorch_qnn"
      except Exception:
        pass


def _resolve_ultralytics_module(weights_path: Path, yolo_cls) -> "torch.nn.Module":
  import torch

  yolo = yolo_cls(str(weights_path))
  candidate = getattr(yolo, "model", None)
  if not isinstance(candidate, torch.nn.Module):
    _fail(f"[qnn-export] ultralytics did not expose a torch module for {weights_path}")
  _apply_export_flags(candidate)
  return candidate


def _write_metadata(
    *,
    output_dir: Path,
    weights_path: Path,
    output_name: str,
    soc: str,
    use_fp16: bool,
    imgsz: int,
    batch: int,
) -> None:
  metadata = {
      "weights": str(weights_path),
      "output_name": output_name,
      "soc": soc,
      "use_fp16": use_fp16,
      "imgsz": imgsz,
      "batch": batch,
  }
  (output_dir / f"{output_name}.metadata.json").write_text(
      json.dumps(metadata, indent=2), encoding="utf-8"
  )


def main() -> int:
  args = _parse_args()
  runtime = _load_runtime()
  torch = runtime["torch"]
  yolo_cls = runtime["YOLO"]
  generate_htp_compiler_spec = runtime["generate_htp_compiler_spec"]
  generate_qnn_executorch_compiler_spec = runtime[
      "generate_qnn_executorch_compiler_spec"
  ]
  get_soc_to_chipset_map = runtime["get_soc_to_chipset_map"]
  to_edge_transform_and_lower_to_qnn = runtime["to_edge_transform_and_lower_to_qnn"]
  executorch_backend_config = runtime["ExecutorchBackendConfig"]
  save_pte_program = runtime["save_pte_program"]
  format_delegated_graph = runtime["format_delegated_graph"]

  weights_path = Path(args.weights).resolve()
  if not weights_path.is_file():
    _fail(f"[qnn-export] weights not found: {weights_path}")
  if weights_path.suffix.lower() != ".pt":
    _fail(f"[qnn-export] expected a .pt file: {weights_path}")

  soc_map = get_soc_to_chipset_map()
  if args.soc not in soc_map:
    _fail(
        "[qnn-export] unsupported soc. "
        f"expected one of {sorted(soc_map.keys())}, got {args.soc}"
    )

  output_dir = Path(args.output_dir).resolve()
  output_dir.mkdir(parents=True, exist_ok=True)
  output_name = args.output_name.strip() or f"{weights_path.stem}_qnn"

  print(f"[qnn-export] weights={weights_path}")
  print(f"[qnn-export] output_dir={output_dir}")
  print(f"[qnn-export] output_name={output_name}")
  print(f"[qnn-export] soc={args.soc} use_fp16={args.use_fp16}")

  module = _resolve_ultralytics_module(weights_path, yolo_cls)

  class ExportWrapper(torch.nn.Module):
    def __init__(self, inner_module: torch.nn.Module):
      super().__init__()
      self.inner_module = inner_module

    def forward(self, x: torch.Tensor):
      return _normalize_output(self.inner_module(x))

  wrapped_module = ExportWrapper(module).eval()
  example_inputs = (
      torch.randn(args.batch, 3, args.imgsz, args.imgsz, dtype=torch.float32),
  )

  backend_options = generate_htp_compiler_spec(use_fp16=args.use_fp16)
  compile_spec = generate_qnn_executorch_compiler_spec(
      soc_model=soc_map[args.soc],
      backend_options=backend_options,
  )

  delegated_program = to_edge_transform_and_lower_to_qnn(
      wrapped_module,
      example_inputs,
      compile_spec,
  )

  if format_delegated_graph is not None:
    delegated_graph = format_delegated_graph(
        delegated_program.exported_program().graph_module
    )
    (output_dir / f"{output_name}.delegated_graph.txt").write_text(
        delegated_graph, encoding="utf-8"
    )

  executorch_program = delegated_program.to_executorch(
      config=executorch_backend_config(extract_delegate_segments=False)
  )
  save_pte_program(executorch_program, output_name, str(output_dir))
  _write_metadata(
      output_dir=output_dir,
      weights_path=weights_path,
      output_name=output_name,
      soc=args.soc,
      use_fp16=args.use_fp16,
      imgsz=args.imgsz,
      batch=args.batch,
  )

  generated_pte = output_dir / f"{output_name}.pte"
  print(f"[qnn-export] generated={generated_pte}")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
