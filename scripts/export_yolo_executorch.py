#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import shutil
import sys
from pathlib import Path


def _parse_args() -> argparse.Namespace:
  parser = argparse.ArgumentParser(
      description=(
          "Export local Ultralytics YOLO .pt weights to ExecuTorch .pte and "
          "optionally copy the result into CarrotLink assets/models."
      )
  )
  parser.add_argument(
      "models",
      nargs="+",
      help="Input .pt model paths, e.g. scripts/yolo26n.pt scripts/yolo26s.pt",
  )
  parser.add_argument(
      "--imgsz",
      type=int,
      default=416,
      help="Square export image size. Default: 416",
  )
  parser.add_argument(
      "--batch",
      type=int,
      default=1,
      help="Batch size for export. Default: 1",
  )
  parser.add_argument(
      "--device",
      default="cpu",
      help="Ultralytics export device. Default: cpu",
  )
  parser.add_argument(
      "--project",
      default="build/yolo_export",
      help="Export project directory. Default: build/yolo_export",
  )
  parser.add_argument(
      "--asset-dir",
      default="assets/models",
      help="Directory to copy generated .pte files into. Default: assets/models",
  )
  parser.add_argument(
      "--skip-copy",
      action="store_true",
      help="Do not copy the generated .pte into the asset directory.",
  )
  parser.add_argument(
      "--flatc",
      default="",
      help=(
          "Optional path to flatc.exe. If omitted, the script tries "
          "FLATC_EXECUTABLE, tools/flatbuffers/flatc.exe, then PATH."
      ),
  )
  return parser.parse_args()


def _fail(message: str, *, exit_code: int = 1) -> None:
  print(message, file=sys.stderr)
  raise SystemExit(exit_code)


def _import_or_fail() -> tuple[object, object]:
  try:
    import torch  # type: ignore
  except Exception as exc:
    _fail(f"[export] torch import failed: {exc!r}")

  try:
    import executorch  # type: ignore  # noqa: F401
  except Exception as exc:
    _fail(
        "[export] Python executorch package is missing.\n"
        "  Install the export environment first, e.g.:\n"
        "  pip install \"torch>=2.9.0\" executorch==1.0.0 flatbuffers setuptools<71.0.0 \"ultralytics[export]\"\n"
        f"  Import error: {exc!r}"
    )

  try:
    from ultralytics import YOLO  # type: ignore
  except Exception as exc:
    _fail(f"[export] ultralytics import failed: {exc!r}")

  torch_version = getattr(torch, "__version__", "0.0.0")
  torch_version_key = tuple(int(part) for part in torch_version.split("+", 1)[0].split(".")[:3])
  if torch_version_key < (2, 9, 0):
    _fail(
        "[export] Ultralytics ExecuTorch export requires torch>=2.9.0.\n"
        f"  Current torch: {torch_version}\n"
        "  Use a dedicated export venv rather than changing the app runtime Python in place."
    )

  return torch, YOLO


def _resolve_exported_pte(export_result: object, model_path: Path) -> Path:
  export_path = Path(str(export_result))
  if export_path.is_file() and export_path.suffix.lower() == ".pte":
    return export_path

  candidates = []
  if export_path.exists():
    if export_path.is_dir():
      candidates.extend(sorted(export_path.rglob("*.pte")))
    elif export_path.suffix.lower() == ".pt":
      sibling_dir = export_path.with_suffix("")
      if sibling_dir.is_dir():
        candidates.extend(sorted(sibling_dir.rglob("*.pte")))

  fallback_dir = model_path.with_suffix("")
  if fallback_dir.is_dir():
    candidates.extend(sorted(fallback_dir.rglob("*.pte")))

  expected_dir = Path(f"{model_path.with_suffix('')}_executorch_model")
  if expected_dir.is_dir():
    candidates.extend(sorted(expected_dir.rglob("*.pte")))

  unique_candidates = []
  seen = set()
  for candidate in candidates:
    key = str(candidate.resolve())
    if key in seen:
      continue
    seen.add(key)
    unique_candidates.append(candidate)

  if not unique_candidates:
    _fail(
        "[export] export finished but no .pte file was found.\n"
        f"  export_result={export_result}\n"
        f"  checked model={model_path}"
    )

  return unique_candidates[0]


def _copy_to_assets(source: Path, asset_dir: Path) -> Path:
  asset_dir.mkdir(parents=True, exist_ok=True)
  target = asset_dir / source.name
  shutil.copy2(source, target)
  return target


def _resolve_flatc_path(raw_value: str) -> Path | None:
  candidates: list[Path] = []
  if raw_value.strip():
    candidates.append(Path(raw_value).expanduser())
  env_value = os.environ.get("FLATC_EXECUTABLE", "").strip()
  if env_value:
    candidates.append(Path(env_value).expanduser())

  repo_root = Path(__file__).resolve().parent.parent
  candidates.extend(
      (
          repo_root / "tools" / "flatbuffers" / "flatc.exe",
          repo_root / "tools" / "flatc.exe",
          repo_root / "scripts" / "tools" / "flatbuffers" / "flatc.exe",
      )
  )

  for candidate in candidates:
    resolved = candidate.resolve()
    if resolved.is_file():
      return resolved
  return None


def main() -> int:
  args = _parse_args()
  flatc_path = _resolve_flatc_path(args.flatc)
  if flatc_path != None:
    os.environ["FLATC_EXECUTABLE"] = str(flatc_path)
    print(f"[export] flatc={flatc_path}")
  _, yolo_cls = _import_or_fail()

  project_dir = Path(args.project).resolve()
  asset_dir = Path(args.asset_dir).resolve()
  project_dir.mkdir(parents=True, exist_ok=True)

  print(f"[export] project={project_dir}")
  print(f"[export] asset_dir={asset_dir}")

  for raw_model in args.models:
    model_path = Path(raw_model).resolve()
    if not model_path.is_file():
      _fail(f"[export] model not found: {model_path}")
    if model_path.suffix.lower() != ".pt":
      _fail(f"[export] only .pt input is supported right now: {model_path}")

    print(f"[export] starting model={model_path.name} imgsz={args.imgsz} batch={args.batch}")
    model = yolo_cls(str(model_path))
    export_result = model.export(
        format="executorch",
        imgsz=args.imgsz,
        batch=args.batch,
        device=args.device,
        project=str(project_dir),
        name=model_path.stem,
    )
    exported_pte = _resolve_exported_pte(export_result, model_path)
    print(f"[export] generated={exported_pte}")

    if not args.skip_copy:
      copied = _copy_to_assets(exported_pte, asset_dir)
      print(f"[export] copied_to_assets={copied}")

  return 0


if __name__ == "__main__":
  raise SystemExit(main())
