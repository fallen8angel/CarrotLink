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
  parser.add_argument(
      "--online-prepare",
      action="store_true",
      help=(
          "Export with QNN online_prepare so the graph is composed on-device "
          "instead of relying on a serialized precompiled context binary."
      ),
  )
  return parser.parse_args()


def _fail(message: str, *, exit_code: int = 1) -> None:
  print(message, file=sys.stderr)
  raise SystemExit(exit_code)


def _patch_qnn_floor_divide_scalar_bug(torch_module) -> None:
  try:
    from executorch.backends.qualcomm._passes.decompose_floor_divide import (  # type: ignore
        DecomposeFloorDivide,
        FloorDivide,
    )
    from executorch.backends.qualcomm._passes.utils import merge_decomposed_graph  # type: ignore
    from executorch.exir.pass_base import PassResult  # type: ignore
  except Exception:
    return

  if getattr(DecomposeFloorDivide, "_carrotlink_scalar_patch", False):
    return

  def _meta_value(arg):
    if hasattr(arg, "meta") and isinstance(getattr(arg, "meta"), dict):
      return arg.meta.get("val", arg)
    return arg

  def _as_tensor(value, *, reference=None):
    if isinstance(value, torch_module.Tensor):
      return value
    kwargs = {}
    if isinstance(reference, torch_module.Tensor):
      kwargs["dtype"] = reference.dtype
      kwargs["device"] = reference.device
    return torch_module.tensor(value, **kwargs)

  def _patched_call(self, graph_module):
    graph = graph_module.graph
    changed = False
    for node in list(graph.nodes):
      if (
          torch_module.ops.aten.floor_divide.default != node.target
          or torch_module.is_floating_point(node.meta["val"])
      ):
        continue

      lhs_value = _meta_value(node.args[0])
      rhs_value = _meta_value(node.args[1])
      lhs_tensor = _as_tensor(lhs_value)
      rhs_tensor = _as_tensor(rhs_value, reference=lhs_tensor)
      decomposed_module = torch_module.export.export(
          FloorDivide(),
          (lhs_tensor, rhs_tensor),
          strict=True,
      ).module()
      with graph.inserting_before(node):
        remap = {"x": node.args[0], "y": node.args[1]}
        merge_decomposed_graph(
            remap=remap,
            target_node=node,
            target_graph=graph,
            decomposed_graph_module=decomposed_module,
        )
        graph.erase_node(node)
        changed = True

    if changed:
      graph.eliminate_dead_code()
      graph_module.recompile()
    return PassResult(graph_module, changed)

  DecomposeFloorDivide.call = _patched_call
  DecomposeFloorDivide._carrotlink_scalar_patch = True


def _patch_qnn_partitioner_missing_visitors() -> None:
  try:
    from executorch.backends.qualcomm.partition.qnn_partitioner import (  # type: ignore
        QnnOperatorSupport,
    )
  except Exception:
    return

  if getattr(QnnOperatorSupport, "_carrotlink_missing_visitor_patch", False):
    return

  original_is_node_supported = QnnOperatorSupport.is_node_supported

  def _patched_is_node_supported(self, submodules, node):
    try:
      return original_is_node_supported(self, submodules, node)
    except KeyError:
      self.nodes_to_wrappers.clear()
      target_name = getattr(node.target, "__name__", str(node.target))
      print(
          "[qnn-export] missing QNN visitor, falling back to CPU: "
          f"{target_name}"
      )
      return False

  QnnOperatorSupport.is_node_supported = _patched_is_node_supported
  QnnOperatorSupport._carrotlink_missing_visitor_patch = True


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

  _patch_qnn_floor_divide_scalar_bug(torch)
  _patch_qnn_partitioner_missing_visitors()

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


def _prime_ultralytics_detect_cache(
    module: "torch.nn.Module", example_inputs, torch_module
) -> None:
  """Warm up Detect anchors/shape so export sees a static inference path."""
  with torch_module.no_grad():
    primed = module(*example_inputs)
  if not isinstance(primed, torch_module.Tensor):
    normalized = _normalize_output(primed)
    if not isinstance(normalized, tuple) or not normalized:
      _fail(
          "[qnn-export] Ultralytics warm-up did not produce an exportable output."
      )


def _write_metadata(
    *,
    output_dir: Path,
    weights_path: Path,
    output_name: str,
    soc: str,
    use_fp16: bool,
    online_prepare: bool,
    imgsz: int,
    batch: int,
) -> None:
  metadata = {
      "weights": str(weights_path),
      "output_name": output_name,
      "soc": soc,
      "use_fp16": use_fp16,
      "online_prepare": online_prepare,
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
  print(
      f"[qnn-export] soc={args.soc} use_fp16={args.use_fp16} "
      f"online_prepare={args.online_prepare}"
  )

  module = _resolve_ultralytics_module(weights_path, yolo_cls)
  example_inputs = (
      torch.randn(args.batch, 3, args.imgsz, args.imgsz, dtype=torch.float32),
  )
  _prime_ultralytics_detect_cache(module, example_inputs, torch)

  module = module.eval()

  backend_options = generate_htp_compiler_spec(use_fp16=args.use_fp16)
  compile_spec = generate_qnn_executorch_compiler_spec(
      soc_model=soc_map[args.soc],
      backend_options=backend_options,
      online_prepare=args.online_prepare,
  )

  delegated_program = to_edge_transform_and_lower_to_qnn(
      module,
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
      online_prepare=args.online_prepare,
      imgsz=args.imgsz,
      batch=args.batch,
  )

  generated_pte = output_dir / f"{output_name}.pte"
  print(f"[qnn-export] generated={generated_pte}")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
