#!/usr/bin/env python3
import asyncio
import json
import math
import os
import struct
import sys
import time
import zlib
from typing import Any

from aiohttp import web


def _detect_repo() -> str:
  candidates = []
  env_repo = os.environ.get("CARROTLINK_OPENPILOT_REPO", "").strip()
  if env_repo:
    candidates.append(env_repo)
  candidates.extend(("/data/openpilot", "/home/comma/openpilot"))
  for path in candidates:
    if os.path.isdir(path):
      return path
  return ""


def _ensure_pythonpath(repo: str) -> None:
  if repo and repo not in sys.path:
    sys.path.insert(0, repo)
  if repo:
    os.environ["PYTHONPATH"] = (
      f"{repo}:{os.environ.get('PYTHONPATH', '')}".rstrip(":")
    )


def _safe_float(v: Any) -> float | None:
  if isinstance(v, (int, float)):
    return float(v)
  try:
    return float(v)
  except Exception:
    return None


def _safe_int(v: Any) -> int | None:
  if isinstance(v, bool):
    return int(v)
  if isinstance(v, int):
    return v
  if isinstance(v, float):
    return int(v)
  try:
    return int(v)
  except Exception:
    return None


def _downsample(values: list[float], max_points: int = 24) -> list[float]:
  if len(values) <= max_points:
    return values
  if max_points <= 1:
    return [values[0]]
  step = (len(values) - 1) / float(max_points - 1)
  out = []
  for i in range(max_points):
    idx = int(round(i * step))
    out.append(values[idx])
  return out


_BASE_SOURCE_W = 1928.0
_BASE_SOURCE_H = 1208.0
_CLIP_MARGIN = 500.0
_VIEW_FROM_DEVICE = (
  (0.0, 1.0, 0.0),
  (0.0, 0.0, 1.0),
  (1.0, 0.0, 0.0),
)


def _as_double_list(v: Any) -> list[float]:
  if not isinstance(v, list):
    return []
  out: list[float] = []
  for e in v:
    d = _safe_float(e)
    if d is not None and math.isfinite(d):
      out.append(float(d))
  return out


def _as_bool(v: Any) -> bool:
  if isinstance(v, bool):
    return v
  if isinstance(v, (int, float)):
    return v != 0
  if isinstance(v, str):
    return v.strip().lower() in ("1", "true", "yes", "on")
  return False


def _clamp(v: float, vmin: float, vmax: float) -> float:
  if v < vmin:
    return vmin
  if v > vmax:
    return vmax
  return v


def _max_finite(values: list[float]) -> float:
  out = 0.0
  for v in values:
    if math.isfinite(v) and v > out:
      out = v
  return out


def _m3_identity() -> tuple[tuple[float, float, float], tuple[float, float, float], tuple[float, float, float]]:
  return (
    (1.0, 0.0, 0.0),
    (0.0, 1.0, 0.0),
    (0.0, 0.0, 1.0),
  )


def _m3_mul(
  a: tuple[tuple[float, float, float], tuple[float, float, float], tuple[float, float, float]],
  b: tuple[tuple[float, float, float], tuple[float, float, float], tuple[float, float, float]],
) -> tuple[tuple[float, float, float], tuple[float, float, float], tuple[float, float, float]]:
  return (
    (
      a[0][0] * b[0][0] + a[0][1] * b[1][0] + a[0][2] * b[2][0],
      a[0][0] * b[0][1] + a[0][1] * b[1][1] + a[0][2] * b[2][1],
      a[0][0] * b[0][2] + a[0][1] * b[1][2] + a[0][2] * b[2][2],
    ),
    (
      a[1][0] * b[0][0] + a[1][1] * b[1][0] + a[1][2] * b[2][0],
      a[1][0] * b[0][1] + a[1][1] * b[1][1] + a[1][2] * b[2][1],
      a[1][0] * b[0][2] + a[1][1] * b[1][2] + a[1][2] * b[2][2],
    ),
    (
      a[2][0] * b[0][0] + a[2][1] * b[1][0] + a[2][2] * b[2][0],
      a[2][0] * b[0][1] + a[2][1] * b[1][1] + a[2][2] * b[2][1],
      a[2][0] * b[0][2] + a[2][1] * b[1][2] + a[2][2] * b[2][2],
    ),
  )


def _m3_transform(
  m: tuple[tuple[float, float, float], tuple[float, float, float], tuple[float, float, float]],
  x: float,
  y: float,
  z: float,
) -> tuple[float, float, float]:
  return (
    m[0][0] * x + m[0][1] * y + m[0][2] * z,
    m[1][0] * x + m[1][1] * y + m[1][2] * z,
    m[2][0] * x + m[2][1] * y + m[2][2] * z,
  )


def _rotation_from_euler(
  rpy: list[float],
) -> tuple[tuple[float, float, float], tuple[float, float, float], tuple[float, float, float]]:
  if len(rpy) < 3:
    return _m3_identity()
  roll, pitch, yaw = rpy[0], rpy[1], rpy[2]
  cr, sr = math.cos(roll), math.sin(roll)
  cp, sp = math.cos(pitch), math.sin(pitch)
  cy, sy = math.cos(yaw), math.sin(yaw)
  rx = (
    (1.0, 0.0, 0.0),
    (0.0, cr, -sr),
    (0.0, sr, cr),
  )
  ry = (
    (cp, 0.0, sp),
    (0.0, 1.0, 0.0),
    (-sp, 0.0, cp),
  )
  rz = (
    (cy, -sy, 0.0),
    (sy, cy, 0.0),
    (0.0, 0.0, 1.0),
  )
  return _m3_mul(_m3_mul(rz, ry), rx)


def _intrinsic_for_source(
  source_w: float,
  source_h: float,
  wide_cam: bool,
) -> tuple[tuple[float, float, float], tuple[float, float, float], tuple[float, float, float]]:
  sx = source_w / _BASE_SOURCE_W
  sy = source_h / _BASE_SOURCE_H
  focal = 567.0 if wide_cam else 2648.0
  return (
    (focal * sx, 0.0, 964.0 * sx),
    (0.0, focal * sy, 604.0 * sy),
    (0.0, 0.0, 1.0),
  )


def _build_car_space_transform(
  source_w: float,
  source_h: float,
  wide_cam: bool,
  calibration_rpy: list[float],
  wide_euler: list[float],
) -> tuple[tuple[float, float, float], tuple[float, float, float], tuple[float, float, float]]:
  intrinsic = _intrinsic_for_source(source_w, source_h, wide_cam)
  device_from_calib = _rotation_from_euler(calibration_rpy)
  wide_from_device = _rotation_from_euler(wide_euler) if wide_cam else _m3_identity()
  if wide_cam:
    view_from_calib = _m3_mul(_VIEW_FROM_DEVICE, _m3_mul(wide_from_device, device_from_calib))
  else:
    view_from_calib = _m3_mul(_VIEW_FROM_DEVICE, device_from_calib)
  return _m3_mul(intrinsic, view_from_calib)


def _map_to_source(
  transform: tuple[tuple[float, float, float], tuple[float, float, float], tuple[float, float, float]],
  source_w: float,
  source_h: float,
  in_x: float,
  in_y: float,
  in_z: float,
) -> tuple[float, float] | None:
  px, py, pz = _m3_transform(transform, in_x, in_y, in_z)
  if (not math.isfinite(pz)) or pz <= 1e-3:
    return None
  sx = px / pz
  sy = py / pz
  if (not math.isfinite(sx)) or (not math.isfinite(sy)):
    return None
  if sx < -_CLIP_MARGIN or sy < -_CLIP_MARGIN:
    return None
  if sx > (source_w + _CLIP_MARGIN) or sy > (source_h + _CLIP_MARGIN):
    return None
  return (sx, sy)


def _monotonic_x(src: list[float]) -> list[float]:
  if not src:
    return []
  out = [src[0]]
  prev = src[0]
  for v in src[1:]:
    if v < prev:
      out.append(prev)
    else:
      out.append(v)
      prev = v
  return out


def _interp1d(x: float, xp: list[float], fp: list[float]) -> float:
  if not xp or not fp:
    return 0.0
  n = min(len(xp), len(fp))
  if n <= 1:
    return fp[0]
  if x <= xp[0]:
    return fp[0]
  if x >= xp[n - 1]:
    return fp[n - 1]
  for i in range(1, n):
    x0 = xp[i - 1]
    x1 = xp[i]
    if x <= x1:
      span = x1 - x0
      if abs(span) < 1e-9:
        return fp[i]
      t = (x - x0) / span
      return fp[i - 1] + (fp[i] - fp[i - 1]) * t
  return fp[n - 1]


def _get_path_length_idx(line_x: list[float], path_height: float) -> int:
  max_idx = 0
  i = 1
  while i < len(line_x) and line_x[i] <= path_height:
    max_idx = i
    i += 1
  return max_idx


def _flatten_points(points: list[tuple[float, float]]) -> list[float]:
  out: list[float] = []
  for x, y in points:
    out.append(float(x))
    out.append(float(y))
  return out


def _decode_xyz_series(raw: Any) -> tuple[list[float], list[float], list[float]]:
  if not isinstance(raw, dict):
    return ([], [], [])
  x = _as_double_list(raw.get("x"))
  y = _as_double_list(raw.get("y"))
  z = _as_double_list(raw.get("z"))
  return (x, y, z)


def _map_line_to_polygon_points(
  transform: tuple[tuple[float, float, float], tuple[float, float, float], tuple[float, float, float]],
  source_w: float,
  source_h: float,
  line_x: list[float],
  line_y: list[float],
  line_z: list[float],
  y_off: float,
  z_off: float,
  max_idx: int,
  allow_invert: bool = True,
  line_center_shift: float = 0.0,
) -> list[tuple[float, float]] | None:
  count = min(len(line_x), len(line_y), len(line_z))
  if count < 2:
    return None
  end = min(max_idx, count - 1)
  left: list[tuple[float, float]] = []
  right: list[tuple[float, float]] = []
  for i in range(end + 1):
    lx = line_x[i]
    if (not math.isfinite(lx)) or lx < 0.0:
      continue
    ly = line_y[i] + line_center_shift
    lz = line_z[i]
    lp = _map_to_source(transform, source_w, source_h, lx, ly - y_off, lz + z_off)
    rp = _map_to_source(transform, source_w, source_h, lx, ly + y_off, lz + z_off)
    if lp is None or rp is None:
      continue
    if (not allow_invert) and left and lp[1] > left[-1][1]:
      continue
    left.append(lp)
    right.insert(0, rp)
  if len(left) < 2 or len(right) < 2:
    return None
  return left + right


def _map_line_to_track_vertices_dist(
  transform: tuple[tuple[float, float, float], tuple[float, float, float], tuple[float, float, float]],
  source_w: float,
  source_h: float,
  line_x: list[float],
  line_y: list[float],
  line_z: list[float],
  width_apply: float,
  z_off_start: float,
  z_off_end: float,
  max_distance: float,
  start_distance: float = 2.0,
  allow_invert: bool = True,
) -> list[tuple[float, float]] | None:
  n = min(len(line_x), len(line_y), len(line_z))
  if n < 2:
    return None
  xs = _monotonic_x(line_x[:n])
  ys = line_y[:n]
  zs = line_z[:n]
  if not xs:
    return None
  idxs = [float(i) for i in range(n)]
  left: list[tuple[float, float]] = []
  right: list[tuple[float, float]] = []
  dist = start_distance
  done = False
  while not done:
    if dist >= max_distance:
      dist = max_distance
      done = True
    z_off = _interp1d(dist, [0.0, 100.0], [z_off_start, z_off_end])
    y_scale = _interp1d(z_off, [-3.0, 0.0, 3.0], [1.5, 0.5, 1.5])
    y_off = y_scale * width_apply
    idx = _interp1d(dist, xs, idxs)
    if idx >= (n - 1):
      break
    line_y_val = _interp1d(idx, idxs, ys)
    line_z_val = _interp1d(idx, idxs, zs)
    lp = _map_to_source(
      transform,
      source_w,
      source_h,
      dist,
      line_y_val - y_off,
      line_z_val + z_off,
    )
    rp = _map_to_source(
      transform,
      source_w,
      source_h,
      dist,
      line_y_val + y_off,
      line_z_val + z_off,
    )
    if lp is not None and rp is not None:
      if (not allow_invert) and left and lp[1] > left[-1][1]:
        dist += dist * 0.15
        continue
      left.append(lp)
      right.insert(0, rp)
    dist += dist * 0.15
  if len(left) < 2 or len(right) < 2:
    return None
  return left + right


def _build_overlay2d(payload: dict[str, Any]) -> dict[str, Any] | None:
  car_state = payload.get("carState") if isinstance(payload.get("carState"), dict) else {}
  selfdrive_state = payload.get("selfdriveState") if isinstance(payload.get("selfdriveState"), dict) else {}
  controls_state = payload.get("controlsState") if isinstance(payload.get("controlsState"), dict) else {}
  long_plan = payload.get("longitudinalPlan") if isinstance(payload.get("longitudinalPlan"), dict) else {}
  lateral_plan = payload.get("lateralPlan") if isinstance(payload.get("lateralPlan"), dict) else {}
  radar_state = payload.get("radarState") if isinstance(payload.get("radarState"), dict) else {}
  path_style = payload.get("pathStyle") if isinstance(payload.get("pathStyle"), dict) else {}
  live_calib = payload.get("liveCalibration") if isinstance(payload.get("liveCalibration"), dict) else {}
  cached_calib = payload.get("cachedCalibration") if isinstance(payload.get("cachedCalibration"), dict) else {}
  model_v2 = payload.get("modelV2") if isinstance(payload.get("modelV2"), dict) else {}
  road_state = payload.get("roadCameraState") if isinstance(payload.get("roadCameraState"), dict) else {}
  wide_state = payload.get("wideRoadCameraState") if isinstance(payload.get("wideRoadCameraState"), dict) else {}

  speed_mps = _safe_float(car_state.get("vEgo")) or 0.0
  brake_lights = _as_bool(car_state.get("brakeLights"))
  use_lane_line_speed = _safe_int(car_state.get("useLaneLineSpeed")) or 0
  left_lane_line = _safe_int(car_state.get("leftLaneLine")) or 0
  right_lane_line = _safe_int(car_state.get("rightLaneLine")) or 0

  active = _as_bool(selfdrive_state.get("active"))
  active_lane_line = _as_bool(controls_state.get("activeLaneLine"))
  accel0 = _safe_float(long_plan.get("accel0")) or 0.0
  lead_one = radar_state.get("leadOne") if isinstance(radar_state.get("leadOne"), dict) else {}
  lead_detected = _as_bool(lead_one.get("status"))

  model_frame_id = _safe_int(model_v2.get("frameId"))
  model_path_x = _as_double_list(model_v2.get("pathX"))
  model_path_y = _as_double_list(model_v2.get("pathY"))
  model_path_z = _as_double_list(model_v2.get("pathZ"))

  lane_probs = _as_double_list(model_v2.get("laneLineProbs"))
  lane_stds = _as_double_list(model_v2.get("laneLineStds"))
  lane_lines_raw = model_v2.get("laneLines") if isinstance(model_v2.get("laneLines"), list) else []
  lane_lines: list[dict[str, Any]] = []
  for i, item in enumerate(lane_lines_raw):
    x, y, z = _decode_xyz_series(item)
    count = min(len(x), len(y), len(z))
    if count < 2:
      continue
    lane_lines.append(
      {
        "index": i,
        "x": x[:count],
        "y": y[:count],
        "z": z[:count],
        "probability": float(_clamp(lane_probs[i], 0.0, 1.0)) if i < len(lane_probs) else 0.5,
        "std": float(_clamp(lane_stds[i], 0.0, 2.0)) if i < len(lane_stds) else 1.0,
      }
    )

  road_edges_raw = model_v2.get("roadEdges") if isinstance(model_v2.get("roadEdges"), list) else []
  road_edge_stds = _as_double_list(model_v2.get("roadEdgeStds"))
  road_edges: list[dict[str, Any]] = []
  for i, item in enumerate(road_edges_raw):
    x, y, z = _decode_xyz_series(item)
    count = min(len(x), len(y), len(z))
    if count < 2:
      continue
    road_edges.append(
      {
        "x": x[:count],
        "y": y[:count],
        "z": z[:count],
        "std": float(_clamp(road_edge_stds[i], 0.0, 2.0)) if i < len(road_edge_stds) else 1.0,
      }
    )

  lateral_x: list[float] = []
  lateral_y: list[float] = []
  lateral_z: list[float] = []
  pos = lateral_plan.get("position") if isinstance(lateral_plan.get("position"), dict) else {}
  if pos:
    lx = _as_double_list(pos.get("x"))
    ly = _as_double_list(pos.get("y"))
    lz = _as_double_list(pos.get("z"))
    count = min(len(lx), len(ly), len(lz))
    if count >= 2:
      lateral_x = lx[:count]
      lateral_y = ly[:count]
      lateral_z = lz[:count]

  calibration_rpy: list[float] = []
  wide_from_device_euler: list[float] = []
  path_offset_z = 1.22

  def _apply_calibration(raw: dict[str, Any]) -> None:
    nonlocal calibration_rpy, wide_from_device_euler, path_offset_z
    rpy = _as_double_list(raw.get("rpyCalib"))
    if len(rpy) >= 3:
      calibration_rpy = rpy[:3]
    wide_euler = _as_double_list(raw.get("wideFromDeviceEuler"))
    if len(wide_euler) >= 3:
      wide_from_device_euler = wide_euler[:3]
    h = _safe_float(raw.get("height"))
    if h is not None and math.isfinite(h) and 0.3 < h < 4.0:
      path_offset_z = float(h)

  if live_calib:
    _apply_calibration(live_calib)
  if len(calibration_rpy) < 3 or len(wide_from_device_euler) < 3:
    if cached_calib:
      _apply_calibration(cached_calib)

  model_path_x_max = _max_finite(model_path_x)
  lateral_path_x_max = _max_finite(lateral_x)
  can_use_lateral_primary = (
    active_lane_line
    and len(lateral_x) >= 2
    and lateral_path_x_max >= 8.0
    and (model_path_x_max <= 0.0 or lateral_path_x_max >= (model_path_x_max * 0.35))
  )
  # Keep path visible in low-speed/static scenes when model path collapses.
  can_use_lateral_fallback = (
    (not active_lane_line)
    and len(lateral_x) >= 2
    and lateral_path_x_max >= 8.0
    and model_path_x_max > 0.0
    and model_path_x_max < 8.0
  )
  using_lateral_path = can_use_lateral_primary or can_use_lateral_fallback
  if using_lateral_path:
    path_x, path_y, path_z = lateral_x, lateral_y, lateral_z
  else:
    count = min(len(model_path_x), len(model_path_y), len(model_path_z))
    path_x, path_y, path_z = model_path_x[:count], model_path_y[:count], model_path_z[:count]

  show_path_mode_normal = _safe_int(path_style.get("showPathMode")) or 0
  show_path_color_normal = _safe_int(path_style.get("showPathColor")) or 3
  show_path_mode_lane = _safe_int(path_style.get("showPathModeLane")) or 0
  show_path_color_lane = _safe_int(path_style.get("showPathColorLane")) or 3
  show_path_color_off = _safe_int(path_style.get("showPathColorCruiseOff")) or 3
  show_path_width = _safe_int(path_style.get("showPathWidth")) or 100
  path_width_ratio = _clamp(float(show_path_width) / 100.0, 0.1, 3.0)
  path_mode = show_path_mode_lane if active_lane_line else show_path_mode_normal
  path_color = show_path_color_lane if active_lane_line else show_path_color_normal
  if not active:
    path_color = show_path_color_off
  if path_color >= 20:
    if active:
      path_color = 13
      if lead_detected:
        if abs(accel0) < 0.5:
          path_color = 12
        elif accel0 >= 0.5:
          path_color = 11
        else:
          path_color = 10
    else:
      path_color = 19
  if use_lane_line_speed > 0 and (not active_lane_line):
    path_mode = show_path_mode_lane

  source_w = _BASE_SOURCE_W
  source_h = _BASE_SOURCE_H
  path_model_max = _max_finite(path_x)
  max_distance = _clamp(path_model_max, 10.0, 100.0)
  lane_base_x = lane_lines[0]["x"] if lane_lines else path_x
  lane_max_idx = _get_path_length_idx(lane_base_x, max_distance) if lane_base_x else 0

  camera_inputs = (
    ("road", False, _safe_int(road_state.get("frameId"))),
    ("wideRoad", True, _safe_int(wide_state.get("frameId"))),
  )
  cameras: dict[str, Any] = {}
  for camera_name, is_wide, camera_frame_id in camera_inputs:
    transform = _build_car_space_transform(
      source_w,
      source_h,
      is_wide,
      calibration_rpy,
      wide_from_device_euler,
    )
    lane_polys: list[dict[str, Any]] = []
    for lane in lane_lines:
      line_width = 0.025
      lane_idx = _safe_int(lane.get("index")) or 0
      if lane_idx == 1 and left_lane_line >= 20:
        line_width = 0.05
      poly = _map_line_to_polygon_points(
        transform,
        source_w,
        source_h,
        lane["x"],
        lane["y"],
        lane["z"],
        line_width,
        0.0,
        lane_max_idx,
        allow_invert=True,
        line_center_shift=0.0,
      )
      if poly is None:
        continue
      lane_polys.append(
        {
          "index": lane_idx,
          "probability": lane.get("probability", 0.5),
          "std": lane.get("std", 1.0),
          "points": _flatten_points(poly),
        }
      )
      if lane_idx == 1 and (left_lane_line % 10) == 4:
        poly2 = _map_line_to_polygon_points(
          transform,
          source_w,
          source_h,
          lane["x"],
          lane["y"],
          lane["z"],
          line_width,
          0.0,
          lane_max_idx,
          allow_invert=True,
          line_center_shift=-0.3,
        )
        if poly2 is not None:
          lane_polys.append(
            {
              "index": lane_idx,
              "probability": lane.get("probability", 0.5),
              "std": lane.get("std", 1.0),
              "points": _flatten_points(poly2),
            }
          )

    edge_polys: list[dict[str, Any]] = []
    for edge in road_edges:
      poly = _map_line_to_polygon_points(
        transform,
        source_w,
        source_h,
        edge["x"],
        edge["y"],
        edge["z"],
        0.025,
        0.0,
        lane_max_idx,
        allow_invert=True,
        line_center_shift=0.0,
      )
      if poly is None:
        continue
      edge_polys.append(
        {
          "std": edge.get("std", 1.0),
          "points": _flatten_points(poly),
        }
      )

    track_vertices = _map_line_to_track_vertices_dist(
      transform,
      source_w,
      source_h,
      path_x,
      path_y,
      path_z,
      path_width_ratio,
      path_offset_z,
      path_offset_z,
      max_distance,
      start_distance=2.0 if active else 3.5,
      allow_invert=False,
    )

    cameras[camera_name] = {
      "camera": camera_name,
      "sourceWidth": source_w,
      "sourceHeight": source_h,
      "modelFrameId": model_frame_id,
      "cameraFrameId": camera_frame_id,
      "pathMode": path_mode,
      "pathColor": path_color,
      "pathTrackVertices": _flatten_points(track_vertices) if track_vertices is not None else [],
      "lanePolygons": lane_polys,
      "roadEdgePolygons": edge_polys,
      "meta": {
        "usingLateralPath": using_lateral_path,
        "modelPathXMax": model_path_x_max,
        "lateralPathXMax": lateral_path_x_max,
        "brakeLights": brake_lights,
      },
    }

  return {
    "version": 1,
    "source": "sidecar_projected",
    "cameras": cameras,
  }


def _is_h264_keyframe(payload: bytes) -> bool:
  n = len(payload)
  i = 0
  while i + 4 < n:
    if payload[i] != 0 or payload[i + 1] != 0:
      i += 1
      continue
    if payload[i + 2] == 1:
      nal_start = i + 3
    elif payload[i + 2] == 0 and payload[i + 3] == 1:
      nal_start = i + 4
    else:
      i += 1
      continue
    if nal_start < n:
      nal_type = payload[nal_start] & 0x1F
      if nal_type == 5:
        return True
    i = nal_start
  return False


def _extract_h264_codec(payload: bytes) -> str | None:
  n = len(payload)
  i = 0
  while i + 6 < n:
    if payload[i] != 0 or payload[i + 1] != 0:
      i += 1
      continue
    if payload[i + 2] == 1:
      nal_start = i + 3
    elif payload[i + 2] == 0 and payload[i + 3] == 1:
      nal_start = i + 4
    else:
      i += 1
      continue

    if nal_start + 3 < n:
      nal_type = payload[nal_start] & 0x1F
      if nal_type == 7:
        profile = payload[nal_start + 1]
        constraints = payload[nal_start + 2]
        level = payload[nal_start + 3]
        return f"avc1.{profile:02X}{constraints:02X}{level:02X}"
    i = nal_start
  return None


class CameraRelayHub:
  CAMERA_TO_SERVICE = {
    "road": "livestreamRoadEncodeData",
    "wideRoad": "livestreamWideRoadEncodeData",
    "driver": "livestreamDriverEncodeData",
  }

  def __init__(self, messaging: Any):
    self.messaging = messaging
    self.clients: dict[str, set[web.WebSocketResponse]] = {
      cam: set() for cam in self.CAMERA_TO_SERVICE.keys()
    }
    self._tasks: dict[str, asyncio.Task] = {}
    self._sockets: dict[str, Any] = {}
    self._frame_count: dict[str, int] = {
      cam: 0 for cam in self.CAMERA_TO_SERVICE.keys()
    }
    self._drop_count: dict[str, int] = {
      cam: 0 for cam in self.CAMERA_TO_SERVICE.keys()
    }
    self._last_codec: dict[str, str] = {
      cam: "" for cam in self.CAMERA_TO_SERVICE.keys()
    }
    self._lock = asyncio.Lock()

  def _pack_frame(self, camera: str, frame: Any) -> bytes:
    header = getattr(frame, "header", b"") or b""
    data = getattr(frame, "data", b"") or b""
    payload = bytes(header) + bytes(data)

    frame_id = _safe_int(getattr(frame, "frameId", None))
    sof = _safe_int(getattr(frame, "timestampSof", None))
    eof = _safe_int(getattr(frame, "timestampEof", None))
    width = _safe_int(getattr(frame, "width", None))
    height = _safe_int(getattr(frame, "height", None))
    flags = None
    encode_id = None
    segment_id = None
    frame_type = None
    try:
      idx = getattr(frame, "idx", None)
      if idx is not None:
        flags = _safe_int(getattr(idx, "flags", None))
        encode_id = _safe_int(getattr(idx, "encodeId", None))
        segment_id = _safe_int(getattr(idx, "segmentId", None))
        frame_type = str(getattr(idx, "type", ""))
    except Exception:
      pass
    # loggerd uses V4L2_BUF_FLAG_KEYFRAME(0x8) in EncodeIndex.flags
    is_key = bool(flags is not None and (flags & 0x8))
    if not is_key:
      is_key = _is_h264_keyframe(payload)

    codec = _extract_h264_codec(payload)
    if codec:
      self._last_codec[camera] = codec
    elif self._last_codec[camera]:
      codec = self._last_codec[camera]

    meta = {
      "camera": camera,
      "codec": codec or "avc1.640028",
      "frameId": frame_id,
      "width": width,
      "height": height,
      "flags": flags,
      "encodeId": encode_id,
      "segmentId": segment_id,
      "frameType": frame_type,
      "timestampSof": sof,
      "timestampEof": eof,
      "keyFrame": is_key,
      "size": len(payload),
      "ts": time.time(),
    }
    meta_bytes = json.dumps(meta, separators=(",", ":"), ensure_ascii=False).encode(
      "utf-8"
    )
    return struct.pack(">I", len(meta_bytes)) + meta_bytes + payload

  async def _camera_loop(self, camera: str) -> None:
    service = self.CAMERA_TO_SERVICE[camera]
    if self.messaging is None:
      return
    if camera not in self._sockets:
      self._sockets[camera] = self.messaging.sub_sock(service, conflate=True)

    sock = self._sockets[camera]
    while True:
      try:
        if not self.clients.get(camera):
          await asyncio.sleep(0.06)
          continue

        msg = self.messaging.recv_one_or_none(sock)
        if msg is None:
          await asyncio.sleep(0.004)
          continue

        which = ""
        try:
          which = msg.which()
        except Exception:
          await asyncio.sleep(0.001)
          continue
        if not which:
          await asyncio.sleep(0.001)
          continue

        frame = getattr(msg, which, None)
        if frame is None:
          await asyncio.sleep(0.001)
          continue

        packet = self._pack_frame(camera, frame)
        stale: list[web.WebSocketResponse] = []
        for ws in list(self.clients.get(camera, set())):
          try:
            await asyncio.wait_for(ws.send_bytes(packet), timeout=0.04)
          except Exception:
            stale.append(ws)
            self._drop_count[camera] += 1
        for ws in stale:
          self.clients[camera].discard(ws)
        self._frame_count[camera] += 1
      except asyncio.CancelledError:
        break
      except Exception:
        await asyncio.sleep(0.02)

  async def ensure_camera_task(self, camera: str) -> None:
    async with self._lock:
      task = self._tasks.get(camera)
      if task and not task.done():
        return
      self._tasks[camera] = asyncio.create_task(self._camera_loop(camera))

  async def stop_all(self) -> None:
    async with self._lock:
      tasks = list(self._tasks.values())
      self._tasks = {}
    for task in tasks:
      task.cancel()
      try:
        await task
      except Exception:
        pass

  async def ws_camera(self, request: web.Request) -> web.WebSocketResponse:
    camera = request.match_info.get("camera", "").strip()
    if camera not in self.CAMERA_TO_SERVICE:
      raise web.HTTPNotFound(text=f"unknown camera: {camera}")
    if self.messaging is None:
      raise web.HTTPServiceUnavailable(text="messaging unavailable")

    ws = web.WebSocketResponse(heartbeat=20, max_msg_size=2 * 1024 * 1024)
    await ws.prepare(request)
    self.clients[camera].add(ws)
    await self.ensure_camera_task(camera)

    try:
      await ws.send_str(
        json.dumps(
          {
            "type": "hello",
            "camera": camera,
            "mode": "direct-encode-relay",
          },
          separators=(",", ":"),
        )
      )
      async for _ in ws:
        pass
    finally:
      self.clients[camera].discard(ws)
      try:
        await ws.close()
      except Exception:
        pass
    return ws

  def status(self) -> dict[str, Any]:
    cameras: dict[str, Any] = {}
    for camera in self.CAMERA_TO_SERVICE.keys():
      cameras[camera] = {
        "clients": len(self.clients.get(camera, set())),
        "frames": self._frame_count.get(camera, 0),
        "drops": self._drop_count.get(camera, 0),
        "codec": self._last_codec.get(camera, ""),
      }
    return {
      "mode": "single_sub_fanout",
      "cameras": cameras,
    }


class SidecarApp:
  PROFILE_SERVICES = {
    "p0": ["carState", "deviceState", "selfdriveState"],
    "p1": ["carState", "deviceState", "selfdriveState", "liveCalibration"],
    "p2": [
      "carState",
      "deviceState",
      "selfdriveState",
      "controlsState",
      "longitudinalPlan",
      "lateralPlan",
      "liveCalibration",
      "modelV2",
      "radarState",
      "roadCameraState",
      "wideRoadCameraState",
    ],
    "p3": [
      "carState",
      "deviceState",
      "selfdriveState",
      "controlsState",
      "longitudinalPlan",
      "lateralPlan",
      "liveCalibration",
      "modelV2",
      "radarState",
      "roadCameraState",
      "wideRoadCameraState",
    ],
  }

  PROFILE_INTERVAL = {
    "p0": 0.16,
    "p1": 0.12,
    "p2": 0.04,
    "p3": 0.04,
  }

  def __init__(self, profile: str):
    self.profile = profile if profile in self.PROFILE_SERVICES else "p1"
    self.clients: dict[web.WebSocketResponse, str] = {}
    self.repo = _detect_repo()
    self.realdata_root = (
      os.environ.get("CARROTLINK_REALDATA_ROOT", "/data/media/0/realdata").strip()
      or "/data/media/0/realdata"
    )
    self.messaging = None
    self.sm = None
    self.last_error = ""

    self._camera_hub: CameraRelayHub | None = None
    self._logreader_cls = None
    self.replay_active = False
    self.replay_finished = False
    self.replay_route = ""
    self.replay_segment = -1
    self.replay_log_path = ""
    self.replay_error = ""
    self.replay_speed = 1.0
    self._replay_reader = None
    self._replay_iter = None
    self._replay_cache: dict[str, Any] = {}
    self._replay_timeline_cache: dict[tuple[str, int, str], dict[str, Any]] = {}
    self._params = None
    self._path_style_last_read = 0.0
    self._path_style_cache: dict[str, Any] = {
      "showPathMode": 13,
      "showPathColor": 14,
      "showPathModeLane": 13,
      "showPathColorLane": 14,
      "showPathColorCruiseOff": 14,
    }
    self._cached_calibration_last_read = 0.0
    self._cached_calibration_cache: dict[str, Any] | None = None

    self._init_messaging()
    self._init_logreader()
    self._init_params()

  def _init_messaging(self) -> None:
    try:
      _ensure_pythonpath(self.repo)
      from cereal import messaging  # type: ignore

      self.messaging = messaging
      self.sm = messaging.SubMaster(self.PROFILE_SERVICES[self.profile])
      self._camera_hub = CameraRelayHub(messaging)
      self.last_error = ""
      print(f"[sidecar] messaging ready profile={self.profile}")
    except Exception as e:
      self.messaging = None
      self.sm = None
      self._camera_hub = None
      self.last_error = f"messaging init failed: {e}"
      print(f"[sidecar] {self.last_error}")

  def _init_logreader(self) -> None:
    try:
      _ensure_pythonpath(self.repo)
      from tools.lib.logreader import LogReader  # type: ignore

      self._logreader_cls = LogReader
      print("[sidecar] logreader ready")
    except Exception as e:
      self._logreader_cls = None
      print(f"[sidecar] logreader unavailable: {e}")

  def _init_params(self) -> None:
    try:
      _ensure_pythonpath(self.repo)
      try:
        from common.params import Params  # type: ignore
      except Exception:
        from openpilot.common.params import Params  # type: ignore
      self._params = Params()
      print("[sidecar] params ready")
    except Exception as e:
      self._params = None
      print(f"[sidecar] params unavailable: {e}")

  def _read_path_style(self) -> dict[str, Any]:
    now = time.monotonic()
    if now - self._path_style_last_read < 1.0:
      return dict(self._path_style_cache)
    self._path_style_last_read = now
    if self._params is None:
      return dict(self._path_style_cache)
    try:
      self._path_style_cache = {
        "showPathMode": int(self._params.get_int("ShowPathMode")),
        "showPathColor": int(self._params.get_int("ShowPathColor")),
        "showPathModeLane": int(self._params.get_int("ShowPathModeLane")),
        "showPathColorLane": int(self._params.get_int("ShowPathColorLane")),
        "showPathColorCruiseOff": int(self._params.get_int("ShowPathColorCruiseOff")),
        "showPathWidth": int(self._params.get_int("ShowPathWidth")),
      }
    except Exception:
      pass
    return dict(self._path_style_cache)

  def _read_cached_calibration(self) -> dict[str, Any] | None:
    now = time.monotonic()
    if now - self._cached_calibration_last_read < 1.0:
      return (
        dict(self._cached_calibration_cache)
        if self._cached_calibration_cache is not None
        else None
      )
    self._cached_calibration_last_read = now
    if self._params is None:
      self._cached_calibration_cache = None
      return None
    try:
      calib_bytes = self._params.get("CalibrationParams")
      if not calib_bytes:
        self._cached_calibration_cache = None
        return None
      _ensure_pythonpath(self.repo)
      from cereal import log  # type: ignore

      with log.Event.from_bytes(calib_bytes) as msg:
        lc = msg.liveCalibration
        out: dict[str, Any] = {
          "calStatus": _safe_int(getattr(lc, "calStatus", None)),
          "rpyCalib": [float(v) for v in list(getattr(lc, "rpyCalib", []))[:3]],
          "wideFromDeviceEuler": [
            float(v) for v in list(getattr(lc, "wideFromDeviceEuler", []))[:3]
          ],
        }
        try:
          h = getattr(lc, "height", None)
          if isinstance(h, (list, tuple)):
            out["height"] = _safe_float(h[0]) if len(h) > 0 else None
          else:
            out["height"] = _safe_float(h)
        except Exception:
          pass
      self._cached_calibration_cache = out
    except Exception:
      # Keep previous cached value only if it was valid before.
      if self._cached_calibration_cache is None:
        return None
    return (
      dict(self._cached_calibration_cache)
      if self._cached_calibration_cache is not None
      else None
    )

  def _payload_car_state(self, cs: Any) -> dict[str, Any]:
    return {
      "vEgo": _safe_float(getattr(cs, "vEgo", None)),
      "aEgo": _safe_float(getattr(cs, "aEgo", None)),
      "vEgoCluster": _safe_float(getattr(cs, "vEgoCluster", None)),
      "vCruiseCluster": _safe_float(getattr(cs, "vCruiseCluster", None)),
      "steeringAngleDeg": _safe_float(getattr(cs, "steeringAngleDeg", None)),
      "brakeLights": bool(getattr(cs, "brakeLights", False)),
      "useLaneLineSpeed": _safe_int(getattr(cs, "useLaneLineSpeed", None)),
      "leftLaneLine": _safe_int(getattr(cs, "leftLaneLine", None)),
      "rightLaneLine": _safe_int(getattr(cs, "rightLaneLine", None)),
      "leftBlinker": bool(getattr(cs, "leftBlinker", False)),
      "rightBlinker": bool(getattr(cs, "rightBlinker", False)),
      "leftBlindspot": bool(getattr(cs, "leftBlindspot", False)),
      "rightBlindspot": bool(getattr(cs, "rightBlindspot", False)),
      "gearShifter": str(getattr(cs, "gearShifter", "")),
    }

  def _payload_device_state(self, ds: Any) -> dict[str, Any]:
    cpu_list = getattr(ds, "cpuTempC", None)
    cpu_temp = None
    if isinstance(cpu_list, (list, tuple)) and len(cpu_list) > 0:
      try:
        cpu_temp = max(float(v) for v in cpu_list)
      except Exception:
        cpu_temp = None
    mem_pct = _safe_float(getattr(ds, "memoryUsagePercent", None))
    free_pct = _safe_float(getattr(ds, "freeSpacePercent", None))
    disk_pct = (100.0 - free_pct) if free_pct is not None else None
    return {
      "cpuTempC": cpu_temp,
      "memPct": mem_pct,
      "diskPct": disk_pct,
      "thermalStatus": str(getattr(ds, "thermalStatus", "")),
    }

  def _payload_selfdrive_state(self, ss: Any) -> dict[str, Any]:
    return {
      "enabled": bool(getattr(ss, "enabled", False)),
      "active": bool(getattr(ss, "active", False)),
      "engageable": bool(getattr(ss, "engageable", False)),
      "state": str(getattr(ss, "state", "")),
      "alertText1": str(getattr(ss, "alertText1", "")),
      "alertText2": str(getattr(ss, "alertText2", "")),
    }

  def _payload_controls_state(self, cs: Any) -> dict[str, Any]:
    return {
      "activeLaneLine": bool(getattr(cs, "activeLaneLine", False)),
    }

  def _payload_longitudinal_plan(self, lp: Any) -> dict[str, Any]:
    out = {
      "xState": _safe_int(getattr(lp, "xState", None)),
    }
    try:
      accels = list(getattr(lp, "accels", []))
      out["accel0"] = _safe_float(accels[0]) if len(accels) > 0 else None
    except Exception:
      pass
    return out

  def _payload_lateral_plan(self, lp: Any) -> dict[str, Any]:
    out: dict[str, Any] = {}
    try:
      pos = getattr(lp, "position", None)
      if pos is not None:
        out["position"] = {
          "x": _downsample([float(v) for v in list(getattr(pos, "x", []))], 33),
          "y": _downsample([float(v) for v in list(getattr(pos, "y", []))], 33),
          "z": _downsample([float(v) for v in list(getattr(pos, "z", []))], 33),
        }
    except Exception:
      pass
    return out

  def _payload_live_calibration(self, lc: Any) -> dict[str, Any]:
    out = {
      "calStatus": int(getattr(lc, "calStatus", 0)),
      "rpyCalib": [float(v) for v in list(getattr(lc, "rpyCalib", []))[:3]],
    }
    try:
      h = getattr(lc, "height", None)
      if isinstance(h, (list, tuple)):
        out["height"] = _safe_float(h[0]) if len(h) > 0 else None
      else:
        out["height"] = _safe_float(h)
    except Exception:
      pass
    try:
      out["wideFromDeviceEuler"] = [
        float(v) for v in list(getattr(lc, "wideFromDeviceEuler", []))[:3]
      ]
    except Exception:
      pass
    return out

  def _payload_road_camera_state(self, rcs: Any) -> dict[str, Any]:
    out: dict[str, Any] = {
      "frameId": _safe_int(getattr(rcs, "frameId", None)),
      "timestampSof": _safe_int(getattr(rcs, "timestampSof", None)),
      "timestampEof": _safe_int(getattr(rcs, "timestampEof", None)),
      "gain": _safe_float(getattr(rcs, "gain", None)),
      "integLines": _safe_int(getattr(rcs, "integLines", None)),
      "sensor": str(getattr(rcs, "sensor", "")),
    }
    try:
      out["exposureValPercent"] = _safe_float(getattr(rcs, "exposureValPercent", None))
    except Exception:
      pass
    return out

  def _payload_wide_road_camera_state(self, rcs: Any) -> dict[str, Any]:
    return self._payload_road_camera_state(rcs)

  def _payload_model_v2(self, mv2: Any) -> dict[str, Any]:
    out: dict[str, Any] = {}
    try:
      out["frameId"] = _safe_int(getattr(mv2, "frameId", None))
      out["frameIdExtra"] = _safe_int(getattr(mv2, "frameIdExtra", None))
      out["frameDropPerc"] = _safe_float(getattr(mv2, "frameDropPerc", None))
    except Exception:
      pass

    try:
      pos = getattr(mv2, "position", None)
      if pos is not None:
        out["pathX"] = _downsample([float(v) for v in list(getattr(pos, "x", []))], 33)
        out["pathY"] = _downsample([float(v) for v in list(getattr(pos, "y", []))], 33)
        out["pathZ"] = _downsample([float(v) for v in list(getattr(pos, "z", []))], 33)
    except Exception:
      pass

    try:
      lane_probs = [float(v) for v in list(getattr(mv2, "laneLineProbs", []))]
      out["laneLineProbs"] = lane_probs[:4]
    except Exception:
      pass

    try:
      lane_stds = [float(v) for v in list(getattr(mv2, "laneLineStds", []))]
      out["laneLineStds"] = lane_stds[:4]
    except Exception:
      pass

    try:
      lane_lines = list(getattr(mv2, "laneLines", []))
      packed = []
      for ln in lane_lines[:4]:
        packed.append(
          {
            "x": _downsample([float(v) for v in list(getattr(ln, "x", []))], 33),
            "y": _downsample([float(v) for v in list(getattr(ln, "y", []))], 33),
            "z": _downsample([float(v) for v in list(getattr(ln, "z", []))], 33),
          }
        )
      out["laneLines"] = packed
    except Exception:
      pass

    try:
      edges = list(getattr(mv2, "roadEdges", []))
      packed_edges = []
      for edge in edges[:2]:
        packed_edges.append(
          {
            "x": _downsample([float(v) for v in list(getattr(edge, "x", []))], 33),
            "y": _downsample([float(v) for v in list(getattr(edge, "y", []))], 33),
            "z": _downsample([float(v) for v in list(getattr(edge, "z", []))], 33),
          }
        )
      out["roadEdges"] = packed_edges
    except Exception:
      pass

    try:
      edge_stds = [float(v) for v in list(getattr(mv2, "roadEdgeStds", []))]
      out["roadEdgeStds"] = edge_stds[:2]
    except Exception:
      pass

    return out

  def _payload_radar_state(self, rs: Any) -> dict[str, Any]:
    out: dict[str, Any] = {}
    try:
      lead = getattr(rs, "leadOne", None)
      if lead is not None:
        out["leadOne"] = {
          "status": bool(getattr(lead, "status", False)),
          "dRel": _safe_float(getattr(lead, "dRel", None)),
          "vRel": _safe_float(getattr(lead, "vRel", None)),
          "aRel": _safe_float(getattr(lead, "aRel", None)),
        }
    except Exception:
      pass
    return out

  def _build_live_payload(self) -> dict[str, Any]:
    payload: dict[str, Any] = {
      "ts": time.time(),
      "profile": self.profile,
      "repo": self.repo,
      "source": "live",
    }
    if self.sm is None:
      payload["error"] = self.last_error or "messaging unavailable"
      return payload

    self.sm.update(0)
    try:
      if self.sm.alive.get("carState", False):
        payload["carState"] = self._payload_car_state(self.sm["carState"])
    except Exception:
      pass
    try:
      if self.sm.alive.get("deviceState", False):
        payload["deviceState"] = self._payload_device_state(self.sm["deviceState"])
    except Exception:
      pass
    try:
      if self.sm.alive.get("selfdriveState", False):
        payload["selfdriveState"] = self._payload_selfdrive_state(self.sm["selfdriveState"])
    except Exception:
      pass
    try:
      if self.sm.alive.get("controlsState", False):
        payload["controlsState"] = self._payload_controls_state(self.sm["controlsState"])
    except Exception:
      pass
    try:
      if self.sm.alive.get("longitudinalPlan", False):
        payload["longitudinalPlan"] = self._payload_longitudinal_plan(self.sm["longitudinalPlan"])
    except Exception:
      pass
    try:
      if self.sm.alive.get("lateralPlan", False):
        payload["lateralPlan"] = self._payload_lateral_plan(self.sm["lateralPlan"])
    except Exception:
      pass
    try:
      if self.sm.alive.get("liveCalibration", False):
        payload["liveCalibration"] = self._payload_live_calibration(self.sm["liveCalibration"])
    except Exception:
      pass
    try:
      if self.sm.alive.get("roadCameraState", False):
        payload["roadCameraState"] = self._payload_road_camera_state(self.sm["roadCameraState"])
    except Exception:
      pass
    try:
      if self.sm.alive.get("wideRoadCameraState", False):
        payload["wideRoadCameraState"] = self._payload_wide_road_camera_state(
          self.sm["wideRoadCameraState"]
        )
    except Exception:
      pass
    if self.profile in ("p2", "p3"):
      try:
        if self.sm.alive.get("modelV2", False):
          payload["modelV2"] = self._payload_model_v2(self.sm["modelV2"])
      except Exception:
        pass
    if self.profile in ("p2", "p3"):
      try:
        if self.sm.alive.get("radarState", False):
          payload["radarState"] = self._payload_radar_state(self.sm["radarState"])
      except Exception:
        pass
    if self.profile == "p3":
      pass
    cached_calib = self._read_cached_calibration()
    if cached_calib is not None:
      payload["cachedCalibration"] = cached_calib
    payload["pathStyle"] = self._read_path_style()
    return payload

  def _list_replay_routes(self, limit: int = 200) -> list[dict[str, Any]]:
    root = self.realdata_root
    if not os.path.isdir(root):
      return []

    grouped: dict[str, dict[str, Any]] = {}
    try:
      names = os.listdir(root)
    except Exception:
      return []
    for name in names:
      full = os.path.join(root, name)
      if not os.path.isdir(full):
        continue
      if "--" not in name:
        continue
      base, seg_str = name.rsplit("--", 1)
      try:
        seg = int(seg_str)
      except Exception:
        continue
      latest = int(os.path.getmtime(full))
      entry = grouped.get(base)
      if entry is None:
        entry = {
          "route": base,
          "segments": [],
          "latestModifiedEpoch": latest,
        }
        grouped[base] = entry
      entry["segments"].append(seg)
      if latest > entry["latestModifiedEpoch"]:
        entry["latestModifiedEpoch"] = latest

    items = []
    for value in grouped.values():
      segs = sorted(set(value["segments"]))
      items.append(
        {
          "route": value["route"],
          "segments": segs,
          "latestModifiedEpoch": value["latestModifiedEpoch"],
        }
      )
    items.sort(
      key=lambda x: (int(x["latestModifiedEpoch"]), str(x["route"])),
      reverse=True,
    )
    return items[: max(1, limit)]

  def _resolve_replay_log(self, route: str, segment: int) -> tuple[str | None, str]:
    route = route.strip()
    if not route:
      return None, "route is empty"
    if segment < 0:
      return None, "segment must be >= 0"
    folder = f"{route}--{segment}"
    base = os.path.join(self.realdata_root, folder)
    if not os.path.isdir(base):
      return None, f"segment folder not found: {base}"

    candidates = [
      "rlog.zst",
      "rlog.bz2",
      "rlog",
      "qlog.zst",
      "qlog.bz2",
      "qlog",
    ]
    for name in candidates:
      path = os.path.join(base, name)
      if os.path.isfile(path):
        return path, ""

    try:
      dynamic = sorted(os.listdir(base))
    except Exception:
      dynamic = []
    for name in dynamic:
      lower = name.lower()
      if lower.startswith("rlog") or lower.startswith("qlog"):
        path = os.path.join(base, name)
        if os.path.isfile(path):
          return path, ""
    return None, f"no rlog/qlog file in {base}"

  def _estimate_fps(self, times_sec: list[float]) -> float | None:
    if len(times_sec) < 3:
      return None
    deltas: list[float] = []
    for i in range(1, len(times_sec)):
      dt = times_sec[i] - times_sec[i - 1]
      if dt > 1e-6:
        deltas.append(dt)
    if not deltas:
      return None
    deltas.sort()
    median_dt = deltas[len(deltas) // 2]
    if median_dt <= 1e-6:
      return None
    return 1.0 / median_dt

  def _build_replay_camera_timeline(self, route: str, segment: int) -> tuple[dict[str, Any] | None, str]:
    if self._logreader_cls is None:
      return None, "logreader unavailable (tools.lib.logreader)"

    path, error = self._resolve_replay_log(route, segment)
    if path is None:
      return None, error

    try:
      st = os.stat(path)
      mtime_ns = int(getattr(st, "st_mtime_ns", int(st.st_mtime * 1e9)))
      size_b = int(st.st_size)
    except Exception:
      mtime_ns = 0
      size_b = 0
    cache_key = (route, int(segment), f"{path}:{mtime_ns}:{size_b}")
    cached = self._replay_timeline_cache.get(cache_key)
    if cached is not None:
      return cached, ""

    try:
      reader = self._logreader_cls(path)
      iterator = iter(reader)
    except Exception as e:
      return None, f"failed to open log: {e}"

    road_ids: list[int] = []
    road_ts: list[int] = []
    wide_ids: list[int] = []
    wide_ts: list[int] = []

    for msg in iterator:
      try:
        which = msg.which()
      except Exception:
        continue
      if which != "roadCameraState" and which != "wideRoadCameraState":
        continue
      try:
        item = getattr(msg, which)
      except Exception:
        continue
      frame_id = _safe_int(getattr(item, "frameId", None))
      ts_eof = _safe_int(getattr(item, "timestampEof", None))
      if frame_id is None or ts_eof is None:
        continue
      if which == "roadCameraState":
        if road_ids and frame_id <= road_ids[-1]:
          continue
        if road_ts and ts_eof <= road_ts[-1]:
          continue
        road_ids.append(frame_id)
        road_ts.append(ts_eof)
      else:
        if wide_ids and frame_id <= wide_ids[-1]:
          continue
        if wide_ts and ts_eof <= wide_ts[-1]:
          continue
        wide_ids.append(frame_id)
        wide_ts.append(ts_eof)

    def _pack(ids: list[int], ts: list[int]) -> dict[str, Any]:
      if not ids or not ts:
        return {
          "frameIds": [],
          "tSec": [],
          "fps": None,
          "startFrameId": None,
          "endFrameId": None,
          "durationSec": 0.0,
        }
      base_ts = ts[0]
      t_sec = [max(0.0, (t - base_ts) / 1e9) for t in ts]
      fps = self._estimate_fps(t_sec)
      duration = t_sec[-1] if t_sec else 0.0
      return {
        "frameIds": ids,
        "tSec": t_sec,
        "fps": fps,
        "startFrameId": ids[0],
        "endFrameId": ids[-1],
        "durationSec": duration,
      }

    road = _pack(road_ids, road_ts)
    wide = _pack(wide_ids, wide_ts)
    preferred = "road"
    if not road["frameIds"] and wide["frameIds"]:
      preferred = "wideRoad"

    timeline: dict[str, Any] = {
      "ok": True,
      "route": route,
      "segment": int(segment),
      "logPath": path,
      "preferredCamera": preferred,
      "streams": {
        "road": road,
        "wideRoad": wide,
      },
    }
    self._replay_timeline_cache[cache_key] = timeline
    return timeline, ""

  def _stop_replay(self) -> None:
    self.replay_active = False
    self.replay_finished = False
    self.replay_route = ""
    self.replay_segment = -1
    self.replay_log_path = ""
    self.replay_error = ""
    self.replay_speed = 1.0
    self._replay_reader = None
    self._replay_iter = None
    self._replay_cache = {}

  def _start_replay(self, route: str, segment: int, speed: float = 1.0) -> tuple[bool, str]:
    if self._logreader_cls is None:
      return False, "logreader unavailable (tools.lib.logreader)"

    path, error = self._resolve_replay_log(route, segment)
    if path is None:
      return False, error

    self._stop_replay()
    try:
      self._replay_reader = self._logreader_cls(path)
      self._replay_iter = iter(self._replay_reader)
    except Exception as e:
      self._stop_replay()
      return False, f"failed to open log: {e}"

    self.replay_active = True
    self.replay_finished = False
    self.replay_route = route.strip()
    self.replay_segment = int(segment)
    self.replay_log_path = path
    self.replay_speed = max(0.25, min(float(speed), 8.0))
    return True, "replay started"

  def _apply_replay_message(self, which: str, item: Any) -> None:
    if which == "carState":
      self._replay_cache["carState"] = self._payload_car_state(item)
      return
    if which == "deviceState":
      self._replay_cache["deviceState"] = self._payload_device_state(item)
      return
    if which == "selfdriveState":
      self._replay_cache["selfdriveState"] = self._payload_selfdrive_state(item)
      return
    if which == "controlsState":
      self._replay_cache["controlsState"] = self._payload_controls_state(item)
      return
    if which == "longitudinalPlan":
      self._replay_cache["longitudinalPlan"] = self._payload_longitudinal_plan(item)
      return
    if which == "lateralPlan":
      self._replay_cache["lateralPlan"] = self._payload_lateral_plan(item)
      return
    if which == "liveCalibration":
      self._replay_cache["liveCalibration"] = self._payload_live_calibration(item)
      return
    if which == "roadCameraState":
      self._replay_cache["roadCameraState"] = self._payload_road_camera_state(item)
      return
    if which == "wideRoadCameraState":
      self._replay_cache["wideRoadCameraState"] = self._payload_wide_road_camera_state(item)
      return
    if which == "modelV2":
      self._replay_cache["modelV2"] = self._payload_model_v2(item)
      return
    if which == "radarState":
      self._replay_cache["radarState"] = self._payload_radar_state(item)
      return

  def _build_replay_payload(self) -> dict[str, Any]:
    payload: dict[str, Any] = {
      "ts": time.time(),
      "profile": self.profile,
      "repo": self.repo,
      "source": "replay",
      "replay": {
        "active": self.replay_active,
        "finished": self.replay_finished,
        "route": self.replay_route,
        "segment": self.replay_segment,
        "speed": self.replay_speed,
      },
    }
    cached_calib = self._read_cached_calibration()
    if cached_calib is not None:
      payload["cachedCalibration"] = cached_calib
    payload["pathStyle"] = self._read_path_style()

    if not self.replay_active or self._replay_iter is None:
      payload["error"] = self.replay_error or "replay not active"
      return payload

    model_needed = self.profile in ("p2", "p3")
    message_budget = int(220 * self.replay_speed)
    message_budget = min(max(message_budget, 80), 1200)

    got_model = False
    target_model_frame: int | None = None
    best_road: dict[str, Any] | None = None
    best_road_gap: int | None = None
    best_wide: dict[str, Any] | None = None
    best_wide_gap: int | None = None
    post_model_scan_budget = 140 if model_needed else 0
    post_model_scan_count = 0

    def _update_best_camera(which: str) -> None:
      nonlocal best_road, best_road_gap, best_wide, best_wide_gap
      if target_model_frame is None:
        return
      if which == "roadCameraState":
        candidate = self._replay_cache.get("roadCameraState")
        if not isinstance(candidate, dict):
          return
        frame_id = _safe_int(candidate.get("frameId"))
        if frame_id is None:
          return
        gap = abs(frame_id - target_model_frame)
        if best_road_gap is None or gap < best_road_gap:
          best_road_gap = gap
          best_road = dict(candidate)
        return
      if which == "wideRoadCameraState":
        candidate = self._replay_cache.get("wideRoadCameraState")
        if not isinstance(candidate, dict):
          return
        frame_id = _safe_int(candidate.get("frameId"))
        if frame_id is None:
          return
        gap = abs(frame_id - target_model_frame)
        if best_wide_gap is None or gap < best_wide_gap:
          best_wide_gap = gap
          best_wide = dict(candidate)
        return

    for _ in range(message_budget):
      try:
        msg = next(self._replay_iter)
      except StopIteration:
        self.replay_active = False
        self.replay_finished = True
        break
      except Exception as e:
        self.replay_active = False
        self.replay_error = f"replay read failed: {e}"
        break

      try:
        which = msg.which()
      except Exception:
        continue
      if which not in self.PROFILE_SERVICES.get(self.profile, []):
        continue
      try:
        item = getattr(msg, which)
      except Exception:
        continue
      self._apply_replay_message(which, item)
      if which == "modelV2":
        got_model = True
        model = self._replay_cache.get("modelV2")
        if isinstance(model, dict):
          target_model_frame = _safe_int(model.get("frameId"))
          _update_best_camera("roadCameraState")
          _update_best_camera("wideRoadCameraState")
        if not model_needed:
          break
        if post_model_scan_budget <= 0:
          break
        continue
      if target_model_frame is not None:
        if which == "roadCameraState" or which == "wideRoadCameraState":
          _update_best_camera(which)
        if model_needed and got_model:
          post_model_scan_count += 1
          if post_model_scan_count >= post_model_scan_budget:
            break

    if best_road is not None:
      self._replay_cache["roadCameraState"] = best_road
    if best_wide is not None:
      self._replay_cache["wideRoadCameraState"] = best_wide

    payload.update(self._replay_cache)
    replay_meta = payload.get("replay")
    if isinstance(replay_meta, dict):
      replay_meta["modelFrameId"] = target_model_frame
      road = payload.get("roadCameraState")
      if isinstance(road, dict):
        road_id = _safe_int(road.get("frameId"))
        replay_meta["roadFrameId"] = road_id
        if road_id is not None and target_model_frame is not None:
          replay_meta["roadGap"] = abs(target_model_frame - road_id)
      wide = payload.get("wideRoadCameraState")
      if isinstance(wide, dict):
        wide_id = _safe_int(wide.get("frameId"))
        replay_meta["wideRoadFrameId"] = wide_id
        if wide_id is not None and target_model_frame is not None:
          replay_meta["wideRoadGap"] = abs(target_model_frame - wide_id)
    if self.replay_error:
      payload["error"] = self.replay_error
      payload["replay"]["error"] = self.replay_error
    if self.replay_finished:
      payload["replay"]["active"] = False
      payload["replay"]["finished"] = True
    if model_needed and not got_model and "modelV2" not in self._replay_cache:
      payload["replay"]["note"] = "modelV2 not found yet"
    return payload

  def _build_payload(self) -> dict[str, Any]:
    if self.replay_active:
      payload = self._build_replay_payload()
    else:
      payload = self._build_live_payload()
    try:
      overlay2d = _build_overlay2d(payload)
      if overlay2d is not None:
        payload["overlay2d"] = overlay2d
    except Exception:
      # Keep stream resilient even if 2D projection generation fails.
      pass
    return payload

  async def _broadcast_loop(self, app: web.Application) -> None:
    while True:
      try:
        if self.clients:
          payload = self._build_payload()
          message = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
          message_bytes = message.encode("utf-8")
          compressed: bytes | None = None
          stale: list[web.WebSocketResponse] = []
          for ws, encoding in list(self.clients.items()):
            try:
              if encoding == "zlib-json":
                if compressed is None:
                  compressed = zlib.compress(message_bytes, level=1)
                await ws.send_bytes(compressed)
              else:
                await ws.send_str(message)
            except Exception:
              stale.append(ws)
          for ws in stale:
            self.clients.pop(ws, None)
        base_interval = self.PROFILE_INTERVAL.get(self.profile, 0.12)
        if self.replay_active:
          sleep_s = max(0.03, base_interval / max(self.replay_speed, 0.25))
        else:
          sleep_s = base_interval
        await asyncio.sleep(sleep_s)
      except asyncio.CancelledError:
        break
      except Exception as e:
        self.last_error = f"broadcast error: {e}"
        await asyncio.sleep(0.25)

  async def ws_live(self, request: web.Request) -> web.WebSocketResponse:
    encoding = request.query.get("encoding", "json").strip().lower()
    if encoding not in {"json", "zlib-json"}:
      encoding = "json"
    ws = web.WebSocketResponse(heartbeat=20)
    await ws.prepare(request)
    self.clients[ws] = encoding
    try:
      await ws.send_str(
        json.dumps(
          {
            "type": "hello",
            "profile": self.profile,
            "source": "replay" if self.replay_active else "live",
            "encoding": encoding,
          }
        )
      )
      async for _ in ws:
        pass
    finally:
      self.clients.pop(ws, None)
      try:
        await ws.close()
      except Exception:
        pass
    return ws

  async def ws_camera(self, request: web.Request) -> web.WebSocketResponse:
    if self._camera_hub is None:
      raise web.HTTPServiceUnavailable(text="camera hub unavailable")
    return await self._camera_hub.ws_camera(request)

  async def get_health(self, request: web.Request) -> web.Response:
    camera_status = (
      self._camera_hub.status() if self._camera_hub is not None else {"mode": "disabled"}
    )
    return web.json_response(
      {
        "ok": self.sm is not None,
        "profile": self.profile,
        "clients": len(self.clients),
        "repo": self.repo,
        "mode": "replay" if self.replay_active else "live",
        "error": self.last_error,
        "cameraRelay": camera_status,
        "replay": {
          "active": self.replay_active,
          "finished": self.replay_finished,
          "route": self.replay_route,
          "segment": self.replay_segment,
          "logPath": self.replay_log_path,
          "error": self.replay_error,
        },
      }
    )

  async def get_profile(self, request: web.Request) -> web.Response:
    return web.json_response(
      {
        "profile": self.profile,
        "profiles": list(self.PROFILE_SERVICES.keys()),
      }
    )

  async def set_profile(self, request: web.Request) -> web.Response:
    try:
      body = await request.json()
    except Exception:
      return web.json_response({"ok": False, "error": "invalid json"}, status=400)
    profile = str(body.get("profile", "")).strip().lower()
    if profile not in self.PROFILE_SERVICES:
      return web.json_response({"ok": False, "error": "invalid profile"}, status=400)
    if profile != self.profile:
      self.profile = profile
      self._init_messaging()
    return web.json_response({"ok": True, "profile": self.profile})

  async def get_replay_routes(self, request: web.Request) -> web.Response:
    limit_raw = request.query.get("limit", "").strip()
    limit = 200
    if limit_raw:
      try:
        limit = max(1, min(2000, int(limit_raw)))
      except Exception:
        limit = 200
    routes = self._list_replay_routes(limit=limit)
    return web.json_response(
      {
        "ok": True,
        "realdataRoot": self.realdata_root,
        "count": len(routes),
        "routes": routes,
      }
    )

  async def get_replay_status(self, request: web.Request) -> web.Response:
    return web.json_response(
      {
        "ok": True,
        "active": self.replay_active,
        "finished": self.replay_finished,
        "route": self.replay_route,
        "segment": self.replay_segment,
        "logPath": self.replay_log_path,
        "speed": self.replay_speed,
        "error": self.replay_error,
      }
    )

  async def get_replay_camera_timeline(self, request: web.Request) -> web.Response:
    route = request.query.get("route", "").strip()
    segment_raw = request.query.get("segment", "").strip()
    if not route:
      route = self.replay_route
    if not route:
      return web.json_response({"ok": False, "error": "route is required"}, status=400)

    if segment_raw:
      try:
        segment = int(segment_raw)
      except Exception:
        return web.json_response({"ok": False, "error": "segment must be integer"}, status=400)
    else:
      if self.replay_segment < 0:
        return web.json_response({"ok": False, "error": "segment is required"}, status=400)
      segment = int(self.replay_segment)

    timeline, error = self._build_replay_camera_timeline(route, segment)
    if timeline is None:
      return web.json_response({"ok": False, "error": error}, status=400)
    return web.json_response(timeline)

  async def post_replay_start(self, request: web.Request) -> web.Response:
    try:
      body = await request.json()
    except Exception:
      return web.json_response({"ok": False, "error": "invalid json"}, status=400)
    route = str(body.get("route", "")).strip()
    segment_raw = body.get("segment", None)
    try:
      segment = int(segment_raw)
    except Exception:
      return web.json_response(
        {"ok": False, "error": "segment must be integer"},
        status=400,
      )
    speed = 1.0
    try:
      if body.get("speed", None) is not None:
        speed = float(body.get("speed"))
    except Exception:
      speed = 1.0

    ok, message = self._start_replay(route=route, segment=segment, speed=speed)
    if not ok:
      return web.json_response({"ok": False, "error": message}, status=400)
    return web.json_response(
      {
        "ok": True,
        "message": message,
        "active": self.replay_active,
        "route": self.replay_route,
        "segment": self.replay_segment,
        "logPath": self.replay_log_path,
        "speed": self.replay_speed,
      }
    )

  async def post_replay_stop(self, request: web.Request) -> web.Response:
    self._stop_replay()
    return web.json_response({"ok": True, "active": False})

  async def on_startup(self, app: web.Application) -> None:
    app["broadcast_task"] = asyncio.create_task(self._broadcast_loop(app))

  async def on_cleanup(self, app: web.Application) -> None:
    task = app.get("broadcast_task")
    if task:
      task.cancel()
      try:
        await task
      except Exception:
        pass
    if self._camera_hub is not None:
      await self._camera_hub.stop_all()


def main() -> None:
  profile = os.environ.get("CARROTLINK_SIDECAR_PROFILE", "p1").strip().lower()
  port = int(os.environ.get("CARROTLINK_SIDECAR_PORT", "7766"))
  host = os.environ.get("CARROTLINK_SIDECAR_HOST", "0.0.0.0").strip() or "0.0.0.0"

  app_state = SidecarApp(profile)
  app = web.Application()
  app.router.add_get("/health", app_state.get_health)
  app.router.add_get("/profile", app_state.get_profile)
  app.router.add_post("/profile", app_state.set_profile)
  app.router.add_get("/replay/routes", app_state.get_replay_routes)
  app.router.add_get("/replay/status", app_state.get_replay_status)
  app.router.add_get("/replay/camera_timeline", app_state.get_replay_camera_timeline)
  app.router.add_post("/replay/start", app_state.post_replay_start)
  app.router.add_post("/replay/stop", app_state.post_replay_stop)
  app.router.add_get("/ws/live", app_state.ws_live)
  app.router.add_get("/ws/camera/{camera}", app_state.ws_camera)
  app.on_startup.append(app_state.on_startup)
  app.on_cleanup.append(app_state.on_cleanup)

  print(f"[sidecar] starting host={host} port={port} profile={app_state.profile}")
  web.run_app(app, host=host, port=port)


if __name__ == "__main__":
  main()
