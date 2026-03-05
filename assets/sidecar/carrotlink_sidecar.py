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
  candidates: list[str] = []
  env_repo = os.environ.get("CARROTLINK_OPENPILOT_REPO", "").strip()
  if env_repo:
    candidates.append(env_repo)
  # Prefer local script-relative repo first when deployed under selfdrive/carrot.
  try:
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_from_script = os.path.abspath(os.path.join(script_dir, "..", ".."))
    if repo_from_script:
      candidates.append(repo_from_script)
  except Exception:
    pass

  candidates.extend(
    (
      "/data/openpilot",
      "/home/comma/openpilot",
      "/data/media/0/openpilot",
      "/data/openpilot_source/openpilot",
    )
  )
  for path in candidates:
    if os.path.isdir(path) and os.path.isdir(os.path.join(path, "selfdrive")):
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
  long_active = _as_bool(selfdrive_state.get("enabled"))
  active_lane_line = _as_bool(controls_state.get("activeLaneLine"))
  accel0 = _safe_float(long_plan.get("accel0")) or 0.0
  long_plan_source = _safe_int(long_plan.get("longitudinalPlanSource"))
  x_state = _safe_int(long_plan.get("xState")) or 0
  traffic_state = _safe_int(long_plan.get("trafficState")) or 0
  t_follow = _safe_float(long_plan.get("tFollow")) or 0.0
  desired_distance = _safe_float(long_plan.get("desiredDistance")) or 0.0
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

  def _apply_calibration(raw: dict[str, Any]) -> bool:
    nonlocal calibration_rpy, wide_from_device_euler, path_offset_z
    status = _safe_int(raw.get("calStatus"))
    # Match openpilot UI behavior: only apply when calibration is CALIBRATED(1).
    if status is not None and status != 1:
      return False
    rpy = _as_double_list(raw.get("rpyCalib"))
    if len(rpy) >= 3:
      calibration_rpy = rpy[:3]
    wide_euler = _as_double_list(raw.get("wideFromDeviceEuler"))
    if len(wide_euler) >= 3:
      wide_from_device_euler = wide_euler[:3]
    h = _safe_float(raw.get("height"))
    if h is not None and math.isfinite(h) and 0.3 < h < 4.0:
      path_offset_z = float(h)
    return (len(calibration_rpy) >= 3) and (len(wide_from_device_euler) >= 3)

  live_applied = False
  if live_calib:
    live_applied = _apply_calibration(live_calib)
  if (not live_applied) and (len(calibration_rpy) < 3 or len(wide_from_device_euler) < 3):
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

  model_line_x = _monotonic_x(model_path_x)
  model_line_y = model_path_y
  model_line_z = model_path_z
  model_line_count = min(len(model_line_x), len(model_line_y), len(model_line_z))

  # Carrot/openpilot lead projection uses model.position z as the primary
  # reference, not lane-line z.
  z_ref_x = model_line_x[:model_line_count]
  z_ref_z = model_line_z[:model_line_count]
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
    intrinsic = _intrinsic_for_source(source_w, source_h, is_wide)
    zoom = 2.0 if is_wide else 1.1
    center_x = intrinsic[0][2]
    center_y = intrinsic[1][2]
    x_offset = 0.0
    y_offset = 0.0
    tx = (source_w - (source_w * zoom)) * 0.5
    ty = (source_h - (source_h * zoom)) * 0.5
    inf_x, inf_y, inf_z = _m3_transform(transform, 1000.0, 0.0, 0.0)
    if math.isfinite(inf_z) and abs(inf_z) > 1e-6:
      max_x_offset = max(0.0, center_x * zoom - source_w * 0.5 - 5.0)
      max_y_offset = max(0.0, center_y * zoom - source_h * 0.5 - 5.0)
      x_offset = _clamp(((inf_x / inf_z) - center_x) * zoom, -max_x_offset, max_x_offset)
      y_offset = _clamp(((inf_y / inf_z) - center_y) * zoom, -max_y_offset, max_y_offset)
      tx = (source_w * 0.5 - x_offset) - (center_x * zoom)
      ty = (source_h * 0.5 - y_offset) - (center_y * zoom)

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

    tf_marker: dict[str, Any] | None = None
    if (
      model_line_count >= 2
      and math.isfinite(desired_distance)
      and desired_distance > 0.0
      and desired_distance <= (model_line_x[model_line_count - 1] + 5.0)
    ):
      tf_y = _interp1d(desired_distance, model_line_x[:model_line_count], model_line_y[:model_line_count])
      tf_z = _interp1d(desired_distance, model_line_x[:model_line_count], model_line_z[:model_line_count])
      if math.isfinite(tf_y) and math.isfinite(tf_z):
        tf_left = _map_to_source(
          transform,
          source_w,
          source_h,
          desired_distance,
          tf_y - 1.0,
          tf_z + 1.22,
        )
        tf_right = _map_to_source(
          transform,
          source_w,
          source_h,
          desired_distance,
          tf_y + 1.0,
          tf_z + 1.22,
        )
        if tf_left is not None and tf_right is not None:
          tf_marker = {
            "points": _flatten_points([tf_left, tf_right]),
            "distance": desired_distance,
            "tFollow": t_follow,
          }

    lead_area_boxes: list[dict[str, Any]] = []
    anchor_state = _LEAD_ANCHOR_STATE.setdefault(camera_name, {})

    def _build_box_from_anchor(
      anchor_x: float,
      anchor_y: float,
      anchor_w: float,
      top_y: float | None = None,
    ) -> list[tuple[float, float]]:
      x_left = anchor_x - (anchor_w / 2.0) - 10.0
      x_right = anchor_x + (anchor_w / 2.0) + 10.0
      y_base = anchor_y
      y_top_fallback = anchor_y - max(anchor_w * 0.86, 12.0)
      if top_y is not None and math.isfinite(top_y):
        # Respect projected roof point if it is above base enough.
        y_top = min(float(top_y), y_base - 4.0)
      else:
        y_top = y_top_fallback
      if y_top >= y_base - 2.0:
        y_top = y_top_fallback
      return [
        (x_left, y_top),
        (x_right, y_top),
        (x_right, y_base),
        (x_left, y_base),
      ]

    def _project_lead_pair_from_car_space(
      d_rel: float,
      y_center: float,
      z_center: float,
      half_width: float = 1.0,
    ) -> tuple[tuple[float, float], tuple[float, float]] | None:
      if (not math.isfinite(d_rel)) or d_rel <= 0.5:
        return None
      lane_half_w = _clamp(abs(half_width), 0.6, 1.4)
      left = _map_to_source(
        transform,
        source_w,
        source_h,
        d_rel,
        y_center - lane_half_w,
        z_center + 1.22,
      )
      right = _map_to_source(
        transform,
        source_w,
        source_h,
        d_rel,
        y_center + lane_half_w,
        z_center + 1.22,
      )
      if left is None or right is None:
        return None
      return left, right

    def _project_lead_top_from_car_space(
      d_rel: float,
      y_center: float,
      z_center: float,
      body_height: float = 1.45,
    ) -> tuple[float, float] | None:
      if (not math.isfinite(d_rel)) or d_rel <= 0.5:
        return None
      # car-space z axis in this pipeline behaves as "down"; subtract to move to roof.
      return _map_to_source(
        transform,
        source_w,
        source_h,
        d_rel,
        y_center,
        (z_center + 1.22) - body_height,
      )

    def _update_primary_anchor(
      left: tuple[float, float],
      right: tuple[float, float],
    ) -> None:
      lex, ley = left
      rex, rey = right
      path_width_raw = rex - lex
      path_x_raw = (lex + rex) / 2.0
      path_y_raw = (ley + rey) / 2.0
      if (
        (not math.isfinite(path_width_raw))
        or (not math.isfinite(path_x_raw))
        or (not math.isfinite(path_y_raw))
      ):
        return
      # Do not over-clamp to center area; keep near-full source domain for parity.
      path_x_clamped = _clamp(path_x_raw, -_CLIP_MARGIN, source_w + _CLIP_MARGIN)
      path_y_clamped = _clamp(path_y_raw, -_CLIP_MARGIN, source_h + _CLIP_MARGIN)
      path_width_clamped = _clamp(abs(path_width_raw), 40.0, 900.0)
      # Lower inertia to follow lead movement faster.
      alpha = 0.65
      keep = alpha
      mix = 1.0 - alpha
      fx_old = _safe_float(anchor_state.get("path_fx"))
      fy_old = _safe_float(anchor_state.get("path_fy"))
      fw_old = _safe_float(anchor_state.get("path_fw"))
      if fx_old is None or fy_old is None or fw_old is None:
        fx = path_x_clamped
        fy = path_y_clamped
        fw = path_width_clamped
      else:
        fx = fx_old * keep + path_x_clamped * mix
        fy = fy_old * keep + path_y_clamped * mix
        fw = fw_old * keep + path_width_clamped * mix
      anchor_state["path_fx"] = fx
      anchor_state["path_fy"] = fy
      anchor_state["path_fw"] = fw

    def _current_primary_anchor() -> tuple[float, float, float] | None:
      fx = _safe_float(anchor_state.get("path_fx"))
      fy = _safe_float(anchor_state.get("path_fy"))
      fw = _safe_float(anchor_state.get("path_fw"))
      if fx is None or fy is None or fw is None:
        return None
      return (float(fx), float(fy), float(fw))

    def _lead_badge_offsets(anchor_w: float) -> tuple[float, float]:
      dx = _clamp(anchor_w * 0.45, 56.0, 120.0)
      dy = _clamp(anchor_w * 0.32, 40.0, 96.0)
      return float(dx), float(dy)

    def _lead_state_offset_y(anchor_w: float) -> float:
      return float(_clamp(anchor_w * 0.52, 52.0, 140.0))

    lead_one_status = _as_bool(lead_one.get("status"))
    lead_one_d_rel = _safe_float(lead_one.get("dRel")) or 0.0
    lead_one_y_rel = _safe_float(lead_one.get("yRel")) or 0.0
    lead_one_d_path = _safe_float(lead_one.get("dPath"))
    lead_one_radar = _as_bool(lead_one.get("radar"))
    lead_one_track_id = _safe_int(lead_one.get("radarTrackId"))
    anchor_one: tuple[float, float, float] | None = None
    if lead_one_status:
      lead_distance = lead_one_d_rel
      if (
        lead_one_d_path is not None
        and math.isfinite(lead_one_d_path)
        and abs(lead_one_d_path) <= 4.0
      ):
        lead_y_center = -lead_one_d_path
      else:
        lead_y_center = -lead_one_y_rel
      lead_z_center = _z_at_distance(lead_distance, 0.0)
      pair_one = _project_lead_pair_from_car_space(
        lead_distance,
        lead_y_center,
        lead_z_center,
        half_width=1.0,
      )
      if pair_one is not None:
        _update_primary_anchor(pair_one[0], pair_one[1])
        anchor_one = _current_primary_anchor()
      else:
        # Strict behavior: do not reuse stale anchor when current projection fails.
        anchor_state.pop("path_fx", None)
        anchor_state.pop("path_fy", None)
        anchor_state.pop("path_fw", None)
        anchor_one = None
    else:
      # Keep lead overlay strict: no stale anchor/box when lead is not detected.
      anchor_state.pop("path_fx", None)
      anchor_state.pop("path_fy", None)
      anchor_state.pop("path_fw", None)

    if lead_one_status and anchor_one is not None:
      anchor_x, anchor_y, anchor_w = anchor_one
      lead_top_point = _project_lead_top_from_car_space(
        lead_one_d_rel,
        lead_y_center,
        _z_at_distance(lead_one_d_rel, 0.0),
      )
      lead_one_box = _build_box_from_anchor(
        anchor_x,
        anchor_y,
        anchor_w,
        top_y=lead_top_point[1] if lead_top_point is not None else None,
      )
      badge_dx, badge_dy = _lead_badge_offsets(anchor_w)
      state_dy = _lead_state_offset_y(anchor_w)
      vision_prob = _safe_float(lead_vision.get("prob")) or 0.0
      vision_x0 = _safe_float(lead_vision.get("x0")) or 0.0
      vision_dist = vision_x0 - 1.52 if vision_prob > 0.5 else 0.0
      if vision_dist < 0.0:
        vision_dist = 0.0
      lead_one_is_scc = (lead_one_track_id if lead_one_track_id is not None else -1) < 1
      lead_one_stroke_argb = (
        0xFF3D7BFF
        if not lead_one_radar
        else (0xFFFF3B30 if lead_one_is_scc else 0xFFFFA726)
      )
      lead_area_boxes.append(
        {
          "kind": "leadOne",
          "points": _flatten_points(lead_one_box),
          "radar": lead_one_radar,
          "radarTrackId": lead_one_track_id if lead_one_track_id is not None else -1,
          "status": 1,
          "radarDistance": lead_one_d_rel if lead_one_radar else 0.0,
          "visionDistance": vision_dist,
          "anchorCenter": [anchor_x, anchor_y],
          "anchorWidth": anchor_w,
          "radarBadgeCenter": [anchor_x - badge_dx, anchor_y + badge_dy],
          "visionBadgeCenter": [anchor_x + badge_dx, anchor_y + badge_dy],
          "stateTextCenter": [anchor_x, anchor_y + state_dy],
          "strokeColorArgb": int(lead_one_stroke_argb),
          "fillColorArgb": int(0x33000000),
          "radarBadgeColorArgb": int(0xFFFF3B30 if lead_one_is_scc else 0xFFFFA726),
          "visionBadgeColorArgb": int(0xFF3D7BFF),
        }
      )

    lead_two_status_flag = _as_bool(lead_two.get("status"))
    lead_two_d_rel = _safe_float(lead_two.get("dRel")) or 0.0
    lead_two_y_rel = _safe_float(lead_two.get("yRel")) or 0.0
    lead_two_d_path = _safe_float(lead_two.get("dPath"))
    lead_two_radar = _as_bool(lead_two.get("radar"))
    lead_two_track_id = _safe_int(lead_two.get("radarTrackId"))
    lead_two_prev_status = int(_safe_int(anchor_state.get("lead_two_status")) or 0)
    same_track_as_primary = (
      lead_one_track_id is not None
      and lead_two_track_id is not None
      and lead_two_track_id == lead_one_track_id
    )
    # Keep leadTwo gate close to radarState semantics:
    # - status/radar must be valid
    # - positive distance
    # - do not duplicate leadOne when both point to same radar track
    if lead_two_status_flag and lead_two_radar and lead_two_d_rel > 0.5 and not same_track_as_primary:
      z2 = _z_at_distance(lead_two_d_rel, 0.0)
      if (
        lead_two_d_path is not None
        and math.isfinite(lead_two_d_path)
        and abs(lead_two_d_path) <= 4.0
      ):
        lead_two_y_center = -lead_two_d_path
      else:
        lead_two_y_center = -lead_two_y_rel
      pair = _project_lead_pair_from_car_space(
        lead_two_d_rel,
        lead_two_y_center,
        z2,
        half_width=0.95,
      )
      if pair is not None:
        left, right = pair
        x_left = left[0]
        x_right = right[0]
        y_base = left[1]
        if lead_two_prev_status > 0:
          x_left = (anchor_state.get("lead_two_xl", x_left) * 0.8) + (x_left * 0.2)
          x_right = (anchor_state.get("lead_two_xr", x_right) * 0.8) + (x_right * 0.2)
          y_base = (anchor_state.get("lead_two_y", y_base) * 0.8) + (y_base * 0.2)
        anchor_state["lead_two_xl"] = x_left
        anchor_state["lead_two_xr"] = x_right
        anchor_state["lead_two_y"] = y_base
        width2 = abs(x_right - x_left)
        lead_two_top_point = _project_lead_top_from_car_space(
          lead_two_d_rel,
          lead_two_y_center,
          z2,
        )
        y_top_fallback = y_base - max(width2 * 0.86, 12.0)
        if lead_two_top_point is not None and math.isfinite(lead_two_top_point[1]):
          y_top = min(float(lead_two_top_point[1]), y_base - 4.0)
        else:
          y_top = y_top_fallback
        if y_top >= y_base - 2.0:
          y_top = y_top_fallback
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
            "radarTrackId": lead_two_track_id if lead_two_track_id is not None else -1,
            "status": lead_two_status,
            "radarDistance": lead_two_d_rel,
            "anchorCenter": [((x_left + x_right) * 0.5), y_base],
            "anchorWidth": width2,
            "strokeColorArgb": int(0xFFB68A3A),
            "fillColorArgb": int(0x66FF3B30 if lead_two_status >= 2 else 0x33000000),
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
      "displayTransform": {
        "zoom": zoom,
        "centerX": center_x,
        "centerY": center_y,
        "xOffset": x_offset,
        "yOffset": y_offset,
        "tx": tx,
        "ty": ty,
      },
      "modelFrameId": model_frame_id,
      "cameraFrameId": camera_frame_id,
      "pathMode": path_mode,
      "pathColor": path_color,
      "pathTrackVertices": _flatten_points(track_vertices) if track_vertices is not None else [],
      "lanePolygons": lane_polys,
      "roadEdgePolygons": edge_polys,
      "leadAreaBoxes": lead_area_boxes,
      "radarTargets": radar_targets,
      "tfMarker": tf_marker,
      "meta": {
        "usingLateralPath": using_lateral_path,
        "modelPathXMax": model_path_x_max,
        "lateralPathXMax": lateral_path_x_max,
        "brakeLights": brake_lights,
        "showRadarInfo": show_radar_info,
        "radarLatFactor": radar_lat_factor,
        "xState": x_state,
        "trafficState": traffic_state,
        "longActive": long_active,
        "vEgoMps": speed_mps,
        "tFollow": t_follow,
        "desiredDistance": desired_distance,
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
  CAMERA_SERVICE_CANDIDATES = {
    "road": [
      "livestreamRoadEncodeData",
      "roadEncodeData",
    ],
    "wideRoad": [
      "livestreamWideRoadEncodeData",
      "wideRoadEncodeData",
    ],
    "driver": [
      "livestreamDriverEncodeData",
      "driverEncodeData",
    ],
  }
  QUALITY_MODES = ("low_latency",)

  def __init__(self, messaging: Any):
    self.messaging = messaging
    self.clients: dict[str, set[web.WebSocketResponse]] = {
      cam: set() for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
    }
    self._producer_tasks: dict[str, asyncio.Task] = {}
    self._sender_tasks: dict[str, asyncio.Task] = {}
    self._sockets: dict[str, dict[str, Any]] = {
      cam: {} for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
    }
    self._queues: dict[str, asyncio.Queue[bytes]] = {
      cam: asyncio.Queue(maxsize=3)
      for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
    }
    self._frame_count: dict[str, int] = {
      cam: 0 for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
    }
    self._drop_count: dict[str, int] = {
      cam: 0 for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
    }
    self._ws_send_failures: dict[web.WebSocketResponse, int] = {}
    self._last_codec: dict[str, str] = {
      cam: "" for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
    }
    self._selected_service: dict[str, str] = {
      cam: ""
      for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
    }
    self._quality_mode = self._normalize_quality_mode(
      os.environ.get("CARROTLINK_CAMERA_QUALITY_MODE", "low_latency")
    )
    self._lock = asyncio.Lock()

  def _normalize_quality_mode(self, mode: Any) -> str:
    # Single fixed policy: always low-latency mode.
    _ = str(mode or "").strip().lower()
    return "low_latency"

  def set_quality_mode(self, mode: Any) -> str:
    self._quality_mode = self._normalize_quality_mode(mode)
    return self._quality_mode

  def get_quality_mode(self) -> str:
    return self._quality_mode

  def _ordered_camera_services(self, camera: str) -> list[str]:
    base = list(self.CAMERA_SERVICE_CANDIDATES.get(camera, []))
    if not base:
      return []
    # Always prioritize livestream service first for lower latency.
    return base

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

  async def _get_camera_socket(self, camera: str, service: str) -> Any:
    camera_sockets = self._sockets.get(camera)
    if camera_sockets is None:
      camera_sockets = {}
      self._sockets[camera] = camera_sockets
    existing = camera_sockets.get(service)
    if existing is not None:
      return existing
    try:
      sock = self.messaging.sub_sock(service, conflate=True)
      camera_sockets[service] = sock
      return sock
    except Exception:
      return None

  async def _camera_producer_loop(self, camera: str) -> None:
    if self.messaging is None:
      return
    queue = self._queues[camera]
    while True:
      try:
        if not self.clients.get(camera):
          await asyncio.sleep(0.03)
          continue

        services = self._ordered_camera_services(camera)
        if not services:
          await asyncio.sleep(0.1)
          continue

        msg = None
        source_service = ""
        for service in services:
          sock = await self._get_camera_socket(camera, service)
          if sock is None:
            continue
          try:
            candidate = self.messaging.recv_one_or_none(sock)
          except Exception:
            continue
          if candidate is not None:
            msg = candidate
            source_service = service
            break

        if msg is None:
          await asyncio.sleep(0.002)
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
        if queue.full():
          try:
            queue.get_nowait()
          except Exception:
            pass
        try:
          queue.put_nowait(packet)
        except Exception:
          await asyncio.sleep(0.001)
          continue
        self._frame_count[camera] += 1
        if source_service:
          self._selected_service[camera] = source_service
      except asyncio.CancelledError:
        break
      except Exception:
        await asyncio.sleep(0.01)

  async def _camera_sender_loop(self, camera: str) -> None:
    queue = self._queues[camera]
    while True:
      try:
        send_timeout = 0.20
        timeout_fail_limit = 3
        if not self.clients.get(camera):
          keep_count = 1
          while queue.qsize() > keep_count:
            try:
              queue.get_nowait()
            except Exception:
              break
          await asyncio.sleep(0.03)
          continue

        try:
          packet = await asyncio.wait_for(queue.get(), timeout=0.25)
        except asyncio.TimeoutError:
          continue
        dropped_backlog = 0
        while queue.qsize() > 0:
          try:
            packet = queue.get_nowait()
            dropped_backlog += 1
          except Exception:
            break
        if dropped_backlog > 0:
          self._drop_count[camera] += dropped_backlog

        stale: list[web.WebSocketResponse] = []
        for ws in list(self.clients.get(camera, set())):
          try:
            await asyncio.wait_for(ws.send_bytes(packet), timeout=send_timeout)
            self._ws_send_failures.pop(ws, None)
          except Exception:
            fail_count = self._ws_send_failures.get(ws, 0) + 1
            self._ws_send_failures[ws] = fail_count
            if fail_count >= timeout_fail_limit:
              stale.append(ws)
              self._drop_count[camera] += 1
        for ws in stale:
          self.clients[camera].discard(ws)
          self._ws_send_failures.pop(ws, None)
          try:
            await ws.close(code=1011, message=b"camera_send_timeout")
          except Exception:
            pass
      except asyncio.CancelledError:
        break
      except Exception:
        await asyncio.sleep(0.01)

  async def ensure_camera_task(self, camera: str) -> None:
    async with self._lock:
      producer = self._producer_tasks.get(camera)
      if producer is None or producer.done():
        self._producer_tasks[camera] = asyncio.create_task(self._camera_producer_loop(camera))
      sender = self._sender_tasks.get(camera)
      if sender is None or sender.done():
        self._sender_tasks[camera] = asyncio.create_task(self._camera_sender_loop(camera))

  async def stop_all(self) -> None:
    async with self._lock:
      tasks = list(self._producer_tasks.values()) + list(self._sender_tasks.values())
      self._producer_tasks = {}
      self._sender_tasks = {}
    for task in tasks:
      task.cancel()
      try:
        await task
      except Exception:
        pass

  async def ws_camera(self, request: web.Request) -> web.WebSocketResponse:
    camera = request.match_info.get("camera", "").strip()
    if camera not in self.CAMERA_SERVICE_CANDIDATES:
      raise web.HTTPNotFound(text=f"unknown camera: {camera}")
    if self.messaging is None:
      raise web.HTTPServiceUnavailable(text="messaging unavailable")

    ws = web.WebSocketResponse(heartbeat=20, max_msg_size=2 * 1024 * 1024)
    await ws.prepare(request)
    # Single external viewer policy: keep only one active camera client
    # per camera channel to avoid duplicate decode fanout load.
    stale_clients = list(self.clients[camera])
    for stale in stale_clients:
      self.clients[camera].discard(stale)
      self._ws_send_failures.pop(stale, None)
      try:
        await stale.close(code=1001, message=b"replaced_by_new_client")
      except Exception:
        pass
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
      self._ws_send_failures.pop(ws, None)
      try:
        await ws.close()
      except Exception:
        pass
    return ws

  def status(self) -> dict[str, Any]:
    cameras: dict[str, Any] = {}
    for camera in self.CAMERA_SERVICE_CANDIDATES.keys():
      cameras[camera] = {
        "clients": len(self.clients.get(camera, set())),
        "frames": self._frame_count.get(camera, 0),
        "drops": self._drop_count.get(camera, 0),
        "codec": self._last_codec.get(camera, ""),
        "queue": self._queues[camera].qsize(),
        "service": self._selected_service.get(camera, ""),
      }
    return {
      "mode": "queued_multi_sub_fanout",
      "qualityMode": self._quality_mode,
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
      "carrotMan",
      "navInstructionCarrot",
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
      "carrotMan",
      "navInstructionCarrot",
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
      "carrotMan",
      "navInstructionCarrot",
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
    self.profile = profile if profile in self.PROFILE_SERVICES else "p2"
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

  def _payload_carrot_man(self, cm: Any) -> dict[str, Any]:
    navi_paths = str(getattr(cm, "naviPaths", "") or "")
    # Keep payload bounded when path text is unexpectedly large.
    if len(navi_paths) > 12000:
      navi_paths = navi_paths[:12000]
    return {
      "activeCarrot": _safe_int(getattr(cm, "activeCarrot", None)),
      "xTurnInfo": _safe_int(getattr(cm, "xTurnInfo", None)),
      "xDistToTurn": _safe_float(getattr(cm, "xDistToTurn", None)),
      "xTurnCountDown": _safe_int(getattr(cm, "xTurnCountDown", None)),
      "szTBTMainText": str(getattr(cm, "szTBTMainText", "") or ""),
      "szPosRoadName": str(getattr(cm, "szPosRoadName", "") or ""),
      "szSdiDescr": str(getattr(cm, "szSdiDescr", "") or ""),
      "trafficState": _safe_int(getattr(cm, "trafficState", None)),
      "atcType": str(getattr(cm, "atcType", "") or ""),
      "remote": str(getattr(cm, "remote", "") or ""),
      "nRoadLimitSpeed": _safe_int(getattr(cm, "nRoadLimitSpeed", None)),
      "xSpdType": _safe_int(getattr(cm, "xSpdType", None)),
      "xSpdLimit": _safe_int(getattr(cm, "xSpdLimit", None)),
      "xSpdDist": _safe_float(getattr(cm, "xSpdDist", None)),
      "xSpdCountDown": _safe_int(getattr(cm, "xSpdCountDown", None)),
      "vTurnSpeed": _safe_float(getattr(cm, "vTurnSpeed", None)),
      "nGoPosDist": _safe_float(getattr(cm, "nGoPosDist", None)),
      "nGoPosTime": _safe_float(getattr(cm, "nGoPosTime", None)),
      "leftSec": _safe_int(getattr(cm, "leftSec", None)),
      "xPosLat": _safe_float(getattr(cm, "xPosLat", None)),
      "xPosLon": _safe_float(getattr(cm, "xPosLon", None)),
      "xPosAngle": _safe_float(getattr(cm, "xPosAngle", None)),
      "xPosSpeed": _safe_float(getattr(cm, "xPosSpeed", None)),
      "naviPaths": navi_paths,
    }

  def _payload_nav_instruction_carrot(self, ni: Any) -> dict[str, Any]:
    all_maneuvers: list[dict[str, Any]] = []
    try:
      for m in list(getattr(ni, "allManeuvers", []))[:8]:
        if isinstance(m, dict):
          all_maneuvers.append(
            {
              "distance": _safe_float(m.get("distance")),
              "type": str(m.get("type", "") or ""),
              "modifier": str(m.get("modifier", "") or ""),
            }
          )
        else:
          all_maneuvers.append(
            {
              "distance": _safe_float(getattr(m, "distance", None)),
              "type": str(getattr(m, "type", "") or ""),
              "modifier": str(getattr(m, "modifier", "") or ""),
            }
          )
    except Exception:
      pass
    return {
      "maneuverPrimaryText": str(getattr(ni, "maneuverPrimaryText", "") or ""),
      "maneuverSecondaryText": str(getattr(ni, "maneuverSecondaryText", "") or ""),
      "maneuverType": str(getattr(ni, "maneuverType", "") or ""),
      "maneuverModifier": str(getattr(ni, "maneuverModifier", "") or ""),
      "maneuverDistance": _safe_float(getattr(ni, "maneuverDistance", None)),
      "distanceRemaining": _safe_float(getattr(ni, "distanceRemaining", None)),
      "timeRemaining": _safe_float(getattr(ni, "timeRemaining", None)),
      "timeRemainingTypical": _safe_float(getattr(ni, "timeRemainingTypical", None)),
      "speedLimit": _safe_float(getattr(ni, "speedLimit", None)),
      "speedLimitSign": str(getattr(ni, "speedLimitSign", "") or ""),
      "showFull": bool(getattr(ni, "showFull", False)),
      "allManeuvers": all_maneuvers,
    }

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
        if self.sm.alive.get("carrotMan", False):
          payload["carrotMan"] = self._payload_carrot_man(self.sm["carrotMan"])
      except Exception:
        pass
      try:
        if self.sm.alive.get("navInstructionCarrot", False):
          payload["navInstructionCarrot"] = self._payload_nav_instruction_carrot(
            self.sm["navInstructionCarrot"]
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
    radar_state = payload.get("radarState") if isinstance(payload.get("radarState"), dict) else {}
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

    def _lead_tuple(raw: Any) -> tuple[Any, ...]:
      lead = raw if isinstance(raw, dict) else {}
      return (
        _as_bool(lead.get("status")),
        _as_bool(lead.get("radar")),
        _safe_int(lead.get("radarTrackId")),
        round((_safe_float(lead.get("dRel")) or 0.0), 3),
        round((_safe_float(lead.get("yRel")) or 0.0), 3),
        round((_safe_float(lead.get("dPath")) or 0.0), 3),
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
      _lead_tuple(radar_state.get("leadOne")),
      _lead_tuple(radar_state.get("leadTwo")),
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
    # Single external viewer policy: keep one active overlay client.
    stale_clients = list(self.clients.keys())
    for stale in stale_clients:
      self.clients.pop(stale, None)
      try:
        await stale.close(code=1001, message=b"replaced_by_new_client")
      except Exception:
        pass
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

  async def get_camera_quality(self, request: web.Request) -> web.Response:
    mode = "low_latency"
    if self._camera_hub is not None:
      mode = self._camera_hub.get_quality_mode()
    return web.json_response(
      {
        "ok": True,
        "mode": mode,
        "modes": list(CameraRelayHub.QUALITY_MODES),
      }
    )

  async def set_camera_quality(self, request: web.Request) -> web.Response:
    if self._camera_hub is None:
      return web.json_response(
        {"ok": False, "error": "camera hub unavailable"},
        status=503,
      )
    try:
      body = await request.json()
    except Exception:
      body = {}
    mode = body.get("mode")
    applied = self._camera_hub.set_quality_mode(mode)
    return web.json_response(
      {
        "ok": True,
        "mode": applied,
        "modes": list(CameraRelayHub.QUALITY_MODES),
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
  profile = os.environ.get("CARROTLINK_SIDECAR_PROFILE", "p2").strip().lower()
  port = int(os.environ.get("CARROTLINK_SIDECAR_PORT", "7766"))
  host = os.environ.get("CARROTLINK_SIDECAR_HOST", "0.0.0.0").strip() or "0.0.0.0"

  app_state = SidecarApp(profile)
  app = web.Application()
  app.router.add_get("/health", app_state.get_health)
  app.router.add_get("/profile", app_state.get_profile)
  app.router.add_post("/profile", app_state.set_profile)
  app.router.add_get("/camera_quality", app_state.get_camera_quality)
  app.router.add_post("/camera_quality", app_state.set_camera_quality)
  app.router.add_get("/ws/live", app_state.ws_live)
  app.router.add_get("/ws/camera/{camera}", app_state.ws_camera)
  app.on_startup.append(app_state.on_startup)
  app.on_cleanup.append(app_state.on_cleanup)

  print(f"[sidecar] starting host={host} port={port} profile={app_state.profile}")
  web.run_app(app, host=host, port=port)


if __name__ == "__main__":
  main()

