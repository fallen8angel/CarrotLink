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

# Keep per-camera lead anchor state to match carrot/openpilot-style smoothing.
_LEAD_ANCHOR_STATE: dict[str, dict[str, float]] = {}


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
  long_plan_source = _safe_int(long_plan.get("longitudinalPlanSource"))
  lead_one = radar_state.get("leadOne") if isinstance(radar_state.get("leadOne"), dict) else {}
  lead_two = radar_state.get("leadTwo") if isinstance(radar_state.get("leadTwo"), dict) else {}
  leads_left = radar_state.get("leadsLeft") if isinstance(radar_state.get("leadsLeft"), list) else []
  leads_right = radar_state.get("leadsRight") if isinstance(radar_state.get("leadsRight"), list) else []
  leads_center = radar_state.get("leadsCenter") if isinstance(radar_state.get("leadsCenter"), list) else []
  lead_detected = _as_bool(lead_one.get("status"))

  model_frame_id = _safe_int(model_v2.get("frameId"))
  lead_vision = model_v2.get("leadVision") if isinstance(model_v2.get("leadVision"), dict) else {}
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
  show_radar_info = _safe_int(path_style.get("showRadarInfo")) or 0
  radar_lat_factor_raw = _safe_float(path_style.get("radarLatFactor"))
  if radar_lat_factor_raw is None:
    radar_lat_factor_raw = 20.0
  radar_lat_factor = float(_clamp(radar_lat_factor_raw / 100.0, 0.0, 2.0))
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

  z_ref_x: list[float] = []
  z_ref_z: list[float] = []
  for lane in lane_lines:
    lane_idx = _safe_int(lane.get("index"))
    if lane_idx == 2:
      z_ref_x = _monotonic_x(_as_double_list(lane.get("x")))
      z_ref_z = _as_double_list(lane.get("z"))
      break
  if len(z_ref_x) < 2 or len(z_ref_z) < 2:
    z_ref_x = _monotonic_x(path_x)
    z_ref_z = path_z

  def _z_at_distance(distance: float, fallback: float = 0.0) -> float:
    if not math.isfinite(distance) or distance < 0.0:
      return fallback
    count = min(len(z_ref_x), len(z_ref_z))
    if count < 2:
      return fallback
    z = _interp1d(distance, z_ref_x[:count], z_ref_z[:count])
    return float(z) if math.isfinite(z) else fallback

  camera_mode = str(payload.get("_overlayCameraMode", "both")).strip()
  if camera_mode == "road":
    camera_inputs = (
      ("road", False, _safe_int(road_state.get("frameId"))),
    )
  elif camera_mode == "wideRoad":
    camera_inputs = (
      ("wideRoad", True, _safe_int(wide_state.get("frameId"))),
    )
  else:
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

    lead_area_boxes: list[dict[str, Any]] = []
    anchor_state = _LEAD_ANCHOR_STATE.setdefault(camera_name, {})

    def _project_lead_pair(
      d_rel: float,
      y_rel: float,
    ) -> tuple[tuple[float, float], tuple[float, float], float] | None:
      if (not math.isfinite(d_rel)) or d_rel <= 0.5:
        return None
      z = _z_at_distance(d_rel, 0.0)
      left = _map_to_source(
        transform,
        source_w,
        source_h,
        d_rel,
        -y_rel - 1.2,
        z + 1.22,
      )
      right = _map_to_source(
        transform,
        source_w,
        source_h,
        d_rel,
        -y_rel + 1.2,
        z + 1.22,
      )
      if left is None or right is None:
        return None
      width = abs(right[0] - left[0])
      if (not math.isfinite(width)) or width < 2.0:
        return None
      return left, right, width

    def _apply_anchor_smoothing(
      raw_x: float,
      raw_y: float,
      raw_width: float,
    ) -> tuple[float, float, float]:
      # Match carrot/openpilot behavior: clamp + EMA.
      clamped_x = _clamp(raw_x, 350.0, source_w - 350.0)
      clamped_y = _clamp(raw_y, 200.0, source_h - 80.0)
      clamped_w = _clamp(raw_width, 120.0, 800.0)
      alpha = 0.85
      fx_old = _safe_float(anchor_state.get("path_fx"))
      fy_old = _safe_float(anchor_state.get("path_fy"))
      fw_old = _safe_float(anchor_state.get("path_fw"))
      if fx_old is None or fy_old is None or fw_old is None:
        fx, fy, fw = clamped_x, clamped_y, clamped_w
      else:
        keep = alpha
        mix = 1.0 - alpha
        fx = fx_old * keep + clamped_x * mix
        fy = fy_old * keep + clamped_y * mix
        fw = fw_old * keep + clamped_w * mix
      anchor_state["path_fx"] = fx
      anchor_state["path_fy"] = fy
      anchor_state["path_fw"] = fw
      return fx, fy, fw

    def _build_box_from_anchor(
      anchor_x: float,
      anchor_y: float,
      anchor_w: float,
    ) -> list[tuple[float, float]]:
      x_left = anchor_x - (anchor_w / 2.0) - 10.0
      x_right = anchor_x + (anchor_w / 2.0) + 10.0
      y_base = anchor_y
      y_top = anchor_y - (anchor_w * 0.8)
      return [
        (x_left, y_top),
        (x_right, y_top),
        (x_right, y_base),
        (x_left, y_base),
      ]

    lead_one_status = _as_bool(lead_one.get("status"))
    lead_one_d_rel = _safe_float(lead_one.get("dRel")) or 0.0
    lead_one_y_rel = _safe_float(lead_one.get("yRel")) or 0.0
    lead_one_radar = _as_bool(lead_one.get("radar"))
    lead_one_track_id = _safe_int(lead_one.get("radarTrackId"))
    if lead_one_status:
      pair = _project_lead_pair(lead_one_d_rel, lead_one_y_rel)
      if pair is not None:
        left, right, width = pair
        raw_x = (left[0] + right[0]) * 0.5
        raw_y = (left[1] + right[1]) * 0.5
        anchor_x, anchor_y, anchor_w = _apply_anchor_smoothing(raw_x, raw_y, width)
        lead_one_box = _build_box_from_anchor(anchor_x, anchor_y, anchor_w)
        vision_prob = _safe_float(lead_vision.get("prob")) or 0.0
        vision_x0 = _safe_float(lead_vision.get("x0")) or 0.0
        vision_dist = vision_x0 - 1.52 if vision_prob > 0.5 else 0.0
        if vision_dist < 0.0:
          vision_dist = 0.0
        lead_area_boxes.append(
          {
            "kind": "leadOne",
            "points": _flatten_points(lead_one_box),
            "radar": lead_one_radar,
            "radarTrackId": lead_one_track_id,
            "status": 1,
            "radarDistance": lead_one_d_rel if lead_one_radar else 0.0,
            "visionDistance": vision_dist,
            "anchorCenter": [anchor_x, anchor_y],
            "anchorWidth": anchor_w,
            "radarBadgeCenter": [anchor_x - 80.0, anchor_y + 60.0],
            "visionBadgeCenter": [anchor_x + 80.0, anchor_y + 60.0],
          }
        )

    lead_two_d_rel = _safe_float(lead_two.get("dRel")) or 0.0
    lead_two_y_rel = _safe_float(lead_two.get("yRel")) or 0.0
    lead_two_radar = _as_bool(lead_two.get("radar"))
    lead_two_prev_status = int(_safe_int(anchor_state.get("lead_two_status")) or 0)
    if lead_two_radar and lead_two_d_rel > (lead_one_d_rel + 3.0):
      pair = _project_lead_pair(lead_two_d_rel, lead_two_y_rel)
      if pair is not None:
        left, right, width = pair
        x_left = min(left[0], right[0])
        x_right = max(left[0], right[0])
        y_base = (left[1] + right[1]) * 0.5
        if lead_two_prev_status > 0:
          x_left = (anchor_state.get("lead_two_xl", x_left) * 0.8) + (x_left * 0.2)
          x_right = (anchor_state.get("lead_two_xr", x_right) * 0.8) + (x_right * 0.2)
          y_base = (anchor_state.get("lead_two_y", y_base) * 0.8) + (y_base * 0.2)
        anchor_state["lead_two_xl"] = x_left
        anchor_state["lead_two_xr"] = x_right
        anchor_state["lead_two_y"] = y_base
        width2 = abs(x_right - x_left)
        y_top = y_base - (width2 * 0.8)
        lead_two_box = [
          (x_left - 10.0, y_top),
          (x_right + 10.0, y_top),
          (x_right + 10.0, y_base),
          (x_left - 10.0, y_base),
        ]
        lead_two_status = 2 if long_plan_source == 1 else 1
        anchor_state["lead_two_status"] = float(lead_two_status)
        lead_area_boxes.append(
          {
            "kind": "leadTwo",
            "points": _flatten_points(lead_two_box),
            "radar": True,
            "status": lead_two_status,
            "radarDistance": lead_two_d_rel,
            "anchorCenter": [((x_left + x_right) * 0.5), y_base],
            "anchorWidth": width2,
          }
        )
      else:
        anchor_state["lead_two_status"] = 0.0
    else:
      anchor_state["lead_two_status"] = 0.0

    radar_targets: list[dict[str, Any]] = []
    if show_radar_info > 0:
      for group_name, group in (
        ("leadsLeft", leads_left),
        ("leadsRight", leads_right),
        ("leadsCenter", leads_center),
      ):
        for raw_track in group:
          if not isinstance(raw_track, dict):
            continue
          d_rel = _safe_float(raw_track.get("dRel"))
          if d_rel is None or (not math.isfinite(d_rel)) or d_rel <= 2.5:
            continue
          y_rel = _safe_float(raw_track.get("yRel")) or 0.0
          z = _z_at_distance(d_rel, 0.0) - 0.61
          center = _map_to_source(
            transform,
            source_w,
            source_h,
            d_rel,
            -y_rel,
            z,
          )
          if center is None:
            continue
          v_lead = _safe_float(raw_track.get("vLeadK"))
          if v_lead is None:
            v_lead = _safe_float(raw_track.get("vRel")) or 0.0
          v_lat = _safe_float(raw_track.get("vLat")) or 0.0
          v_abs = math.sqrt((v_lead * v_lead) + (v_lat * v_lat))
          v_sum = v_abs if v_lead >= 0.0 else -v_abs
          item: dict[str, Any] = {
            "group": group_name,
            "center": [center[0], center[1]],
            "dRel": d_rel,
            "yRel": y_rel,
            "vLeadK": v_lead,
            "vLat": v_lat,
            "speedMpsSigned": v_sum,
            "speedKphSigned": v_sum * 3.6,
            "radar": _as_bool(raw_track.get("radar")),
            "modelProb": _safe_float(raw_track.get("modelProb")) or 0.0,
          }
          if v_abs > 3.0 and abs(v_lead) > 3.0 and radar_lat_factor > 0.0:
            a_d_rel = d_rel + (v_lead * radar_lat_factor)
            if a_d_rel < 2.0:
              a_d_rel = 2.0
            a_y_rel = y_rel + (v_lat * radar_lat_factor)
            future = _map_to_source(
              transform,
              source_w,
              source_h,
              a_d_rel,
              -a_y_rel,
              z,
            )
            if future is not None:
              item["future"] = [future[0], future[1]]
          radar_targets.append(item)

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
      "leadAreaBoxes": lead_area_boxes,
      "radarTargets": radar_targets,
      "meta": {
        "usingLateralPath": using_lateral_path,
        "modelPathXMax": model_path_x_max,
        "lateralPathXMax": lateral_path_x_max,
        "brakeLights": brake_lights,
        "showRadarInfo": show_radar_info,
        "radarLatFactor": radar_lat_factor,
      },
    }

  return {
    "version": 1,
    "source": "sidecar_projected",
    "cameraMode": camera_mode,
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
    if flags is not None:
      is_key = bool(flags & 0x8)
    else:
      is_key = _is_h264_keyframe(payload)
    codec = self._last_codec[camera]
    if not codec:
      parsed_codec = _extract_h264_codec(payload)
      if parsed_codec:
        self._last_codec[camera] = parsed_codec
        codec = parsed_codec

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
            await asyncio.wait_for(ws.send_bytes(packet), timeout=0.12)
          except Exception:
            stale.append(ws)
            self._drop_count[camera] += 1
        for ws in stale:
          self.clients[camera].discard(ws)
          try:
            await ws.close(code=1011, message=b"camera_send_timeout")
          except Exception:
            pass
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
    # p4: high-rate alias of p3 services for aggressive HUD refresh.
    "p4": [
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
    "p4": 0.03,
  }

  def __init__(self, profile: str):
    self.profile = profile if profile in self.PROFILE_SERVICES else "p1"
    self.clients: dict[web.WebSocketResponse, tuple[str, str]] = {}
    self.repo = _detect_repo()
    self.messaging = None
    self.sm = None
    self.last_error = ""

    self._camera_hub: CameraRelayHub | None = None
    self._params = None
    self._path_style_last_read = 0.0
    self._path_style_cache: dict[str, Any] = {
      "showPathMode": 0,
      "showPathColor": 3,
      "showPathModeLane": 0,
      "showPathColorLane": 3,
      "showPathColorCruiseOff": 3,
      "showRadarInfo": 0,
      "radarLatFactor": 20.0,
    }
    self._cached_calibration_last_read = 0.0
    self._cached_calibration_cache: dict[str, Any] | None = None
    self._overlay2d_cache_key: tuple[Any, ...] | None = None
    self._overlay2d_cache_value: dict[str, Any] | None = None

    self._init_messaging()
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
        "showRadarInfo": int(self._params.get_int("ShowRadarInfo")),
        "radarLatFactor": float(self._params.get_float("RadarLatFactor")),
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
    if cpu_list is not None:
      try:
        values: list[float] = []
        for v in cpu_list:
          fv = _safe_float(v)
          if fv is not None and math.isfinite(fv) and fv > 0.0:
            values.append(fv)
        if values:
          cpu_temp = max(values)
      except TypeError:
        fv = _safe_float(cpu_list)
        if fv is not None and math.isfinite(fv) and fv > 0.0:
          cpu_temp = fv
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
      "trafficState": _safe_int(getattr(lp, "trafficState", None)),
      "longitudinalPlanSource": _safe_int(getattr(lp, "longitudinalPlanSource", None)),
      "tFollow": _safe_float(getattr(lp, "tFollow", None)),
      "desiredDistance": _safe_float(getattr(lp, "desiredDistance", None)),
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
      leads_v3 = list(getattr(mv2, "leadsV3", []))
      if leads_v3:
        lead0 = leads_v3[0]
        lead_x = [float(v) for v in list(getattr(lead0, "x", []))]
        out["leadVision"] = {
          "prob": _safe_float(getattr(lead0, "prob", None)),
          "x0": _safe_float(lead_x[0]) if len(lead_x) > 0 else None,
        }
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

  def _payload_radar_lead(self, lead: Any) -> dict[str, Any]:
    out = {
      "status": bool(getattr(lead, "status", False)),
      "dRel": _safe_float(getattr(lead, "dRel", None)),
      "yRel": _safe_float(getattr(lead, "yRel", None)),
      "vRel": _safe_float(getattr(lead, "vRel", None)),
      "vLeadK": _safe_float(getattr(lead, "vLeadK", None)),
      "vLat": _safe_float(getattr(lead, "vLat", None)),
      "aRel": _safe_float(getattr(lead, "aRel", None)),
      "aLeadK": _safe_float(getattr(lead, "aLeadK", None)),
      "radar": bool(getattr(lead, "radar", False)),
      "radarTrackId": _safe_int(getattr(lead, "radarTrackId", None)),
      "modelProb": _safe_float(getattr(lead, "modelProb", None)),
      "score": _safe_float(getattr(lead, "score", None)),
    }
    d_path = _safe_float(getattr(lead, "dPath", None))
    if d_path is not None:
      out["dPath"] = d_path
    return out

  def _payload_radar_track(self, track: Any) -> dict[str, Any]:
    out = {
      "dRel": _safe_float(getattr(track, "dRel", None)),
      "yRel": _safe_float(getattr(track, "yRel", None)),
      "vRel": _safe_float(getattr(track, "vRel", None)),
      "vLeadK": _safe_float(getattr(track, "vLeadK", None)),
      "vLat": _safe_float(getattr(track, "vLat", None)),
      "aRel": _safe_float(getattr(track, "aRel", None)),
      "aLeadK": _safe_float(getattr(track, "aLeadK", None)),
      "radar": bool(getattr(track, "radar", False)),
      "radarTrackId": _safe_int(getattr(track, "radarTrackId", None)),
      "modelProb": _safe_float(getattr(track, "modelProb", None)),
      "score": _safe_float(getattr(track, "score", None)),
    }
    d_path = _safe_float(getattr(track, "dPath", None))
    if d_path is not None:
      out["dPath"] = d_path
    return out

  def _payload_radar_state(self, rs: Any) -> dict[str, Any]:
    out: dict[str, Any] = {}
    try:
      lead_one = getattr(rs, "leadOne", None)
      if lead_one is not None:
        out["leadOne"] = self._payload_radar_lead(lead_one)
    except Exception:
      pass
    try:
      lead_two = getattr(rs, "leadTwo", None)
      if lead_two is not None:
        out["leadTwo"] = self._payload_radar_lead(lead_two)
    except Exception:
      pass
    for group in ("leadsLeft", "leadsRight", "leadsCenter"):
      try:
        packed: list[dict[str, Any]] = []
        for track in list(getattr(rs, group, []))[:16]:
          packed.append(self._payload_radar_track(track))
        out[group] = packed
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
    if self.profile in ("p2", "p3", "p4"):
      try:
        if self.sm.alive.get("modelV2", False):
          payload["modelV2"] = self._payload_model_v2(self.sm["modelV2"])
      except Exception:
        pass
    if self.profile in ("p2", "p3", "p4"):
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

  def _build_payload(self) -> dict[str, Any]:
    return self._build_payload_for_camera_mode("both")

  def _normalize_overlay_camera_mode(self, mode: Any) -> str:
    v = str(mode or "").strip()
    if v == "road":
      return "road"
    if v == "wideRoad":
      return "wideRoad"
    return "both"

  def _overlay2d_cache_key_for(
    self,
    payload: dict[str, Any],
    camera_mode: str,
  ) -> tuple[Any, ...]:
    model_v2 = payload.get("modelV2") if isinstance(payload.get("modelV2"), dict) else {}
    road_state = payload.get("roadCameraState") if isinstance(payload.get("roadCameraState"), dict) else {}
    wide_state = payload.get("wideRoadCameraState") if isinstance(payload.get("wideRoadCameraState"), dict) else {}
    path_style = payload.get("pathStyle") if isinstance(payload.get("pathStyle"), dict) else {}
    controls_state = payload.get("controlsState") if isinstance(payload.get("controlsState"), dict) else {}
    selfdrive_state = payload.get("selfdriveState") if isinstance(payload.get("selfdriveState"), dict) else {}
    car_state = payload.get("carState") if isinstance(payload.get("carState"), dict) else {}
    live_calib = payload.get("liveCalibration") if isinstance(payload.get("liveCalibration"), dict) else {}
    cached_calib = payload.get("cachedCalibration") if isinstance(payload.get("cachedCalibration"), dict) else {}

    def _calib_tuple(raw: dict[str, Any]) -> tuple[Any, ...]:
      rpy = _as_double_list(raw.get("rpyCalib"))
      wide = _as_double_list(raw.get("wideFromDeviceEuler"))
      h = _safe_float(raw.get("height"))
      return (
        tuple(round(v, 6) for v in rpy[:3]),
        tuple(round(v, 6) for v in wide[:3]),
        round(h, 6) if h is not None else None,
      )

    return (
      camera_mode,
      _safe_int(model_v2.get("frameId")),
      _safe_int(road_state.get("frameId")),
      _safe_int(wide_state.get("frameId")),
      _safe_int(path_style.get("showPathMode")),
      _safe_int(path_style.get("showPathColor")),
      _safe_int(path_style.get("showPathModeLane")),
      _safe_int(path_style.get("showPathColorLane")),
      _safe_int(path_style.get("showPathColorCruiseOff")),
      _safe_int(path_style.get("showPathWidth")),
      _safe_int(path_style.get("showRadarInfo")),
      _safe_int(car_state.get("leftLaneLine")),
      _safe_int(car_state.get("rightLaneLine")),
      _safe_int(car_state.get("useLaneLineSpeed")),
      _as_bool(car_state.get("brakeLights")),
      _as_bool(controls_state.get("activeLaneLine")),
      _as_bool(selfdrive_state.get("active")),
      _calib_tuple(live_calib),
      _calib_tuple(cached_calib),
    )

  def _build_payload_for_camera_mode(self, camera_mode: str) -> dict[str, Any]:
    payload = self._build_live_payload()
    try:
      mode = self._normalize_overlay_camera_mode(camera_mode)
      cache_key = self._overlay2d_cache_key_for(payload, mode)
      overlay2d: dict[str, Any] | None = None
      if self._overlay2d_cache_key == cache_key and self._overlay2d_cache_value is not None:
        overlay2d = self._overlay2d_cache_value
      else:
        payload["_overlayCameraMode"] = mode
        overlay2d = _build_overlay2d(payload)
        self._overlay2d_cache_key = cache_key
        self._overlay2d_cache_value = overlay2d
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
          payload_cache: dict[str, tuple[str, bytes]] = {}
          compressed_cache: dict[str, bytes] = {}
          stale: list[web.WebSocketResponse] = []
          for ws, entry in list(self.clients.items()):
            encoding, camera_mode = entry
            try:
              mode = self._normalize_overlay_camera_mode(camera_mode)
              cached = payload_cache.get(mode)
              if cached is None:
                payload = self._build_payload_for_camera_mode(mode)
                message = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
                message_bytes = message.encode("utf-8")
                payload_cache[mode] = (message, message_bytes)
              else:
                message, message_bytes = cached
              if encoding == "zlib-json":
                comp = compressed_cache.get(mode)
                if comp is None:
                  comp = zlib.compress(message_bytes, level=1)
                  compressed_cache[mode] = comp
                await ws.send_bytes(comp)
              else:
                await ws.send_str(message)
            except Exception:
              stale.append(ws)
          for ws in stale:
            self.clients.pop(ws, None)
            try:
              await ws.close(code=1011, message=b"broadcast_send_failed")
            except Exception:
              pass
        base_interval = self.PROFILE_INTERVAL.get(self.profile, 0.12)
        await asyncio.sleep(base_interval)
      except asyncio.CancelledError:
        break
      except Exception as e:
        self.last_error = f"broadcast error: {e}"
        await asyncio.sleep(0.25)

  async def ws_live(self, request: web.Request) -> web.WebSocketResponse:
    encoding = request.query.get("encoding", "json").strip().lower()
    if encoding not in {"json", "zlib-json"}:
      encoding = "json"
    camera_mode = self._normalize_overlay_camera_mode(request.query.get("camera", "both"))
    ws = web.WebSocketResponse(heartbeat=20)
    await ws.prepare(request)
    self.clients[ws] = (encoding, camera_mode)
    try:
      await ws.send_str(
        json.dumps(
          {
            "type": "hello",
            "profile": self.profile,
            "source": "live",
            "encoding": encoding,
            "cameraMode": camera_mode,
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
        "error": self.last_error,
        "cameraRelay": camera_status,
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
  app.router.add_get("/ws/live", app_state.ws_live)
  app.router.add_get("/ws/camera/{camera}", app_state.ws_camera)
  app.on_startup.append(app_state.on_startup)
  app.on_cleanup.append(app_state.on_cleanup)

  print(f"[sidecar] starting host={host} port={port} profile={app_state.profile}")
  web.run_app(app, host=host, port=port)


if __name__ == "__main__":
  main()

