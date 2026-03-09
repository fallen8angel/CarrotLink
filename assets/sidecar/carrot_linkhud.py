#!/usr/bin/env python3
import asyncio
import json
import math
import os
import sys
import time
from typing import Any

from aiohttp import web


def _detect_repo() -> str:
  candidates: list[str] = []
  env_repo = os.environ.get("CARROTLINK_OPENPILOT_REPO", "").strip()
  if env_repo:
    candidates.append(env_repo)

  try:
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_from_script = os.path.abspath(os.path.join(script_dir, "..", ".."))
    if repo_from_script:
      candidates.append(repo_from_script)
  except Exception:
    pass

  candidates.extend((
    "/data/openpilot",
    "/home/comma/openpilot",
    "/data/media/0/openpilot",
    "/data/openpilot_source/openpilot",
  ))

  for path in candidates:
    if os.path.isdir(path) and os.path.isdir(os.path.join(path, "selfdrive")):
      return path
  return ""


def _ensure_pythonpath(repo: str) -> None:
  if repo and repo not in sys.path:
    sys.path.insert(0, repo)
  if repo:
    os.environ["PYTHONPATH"] = f"{repo}:{os.environ.get('PYTHONPATH', '')}".rstrip(":")


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


class LinkHudApp:
  SERVICES = [
    "carState",
    "deviceState",
    "selfdriveState",
    "peripheralState",
    "gpsLocationExternal",
    "gpsLocation",
    "longitudinalPlan",
    "carrotMan",
  ]

  ACTIVE_INTERVAL = 0.10
  IDLE_INTERVAL = 1.50
  SEND_TIMEOUT = 0.18
  PARAM_REFRESH_INTERVAL = 1.0
  METRIC_TOGGLE_INTERVAL = 3.2

  def __init__(self) -> None:
    self.repo = _detect_repo()
    self.messaging = None
    self.sm = None
    self.last_error = ""
    self.hud_clients: set[web.WebSocketResponse] = set()
    self._hud_send_failures: dict[web.WebSocketResponse, int] = {}
    self._hud_send_drop_count = 0
    self._last_hud_build_ms = 0.0
    self._last_hud_send_batch_ms = 0.0
    self._params = None
    self._hud_params_last_read = 0.0
    self._hud_params_cache: dict[str, Any] = {
      "personalityRaw": None,
      "tfGapDisplay": 0,
      "showDeviceState": True,
      "showDateTimeMode": 1,
    }
    self._hud_metric_toggle_last = 0.0
    self._hud_metric_show_volt = False
    self._broadcast_task: asyncio.Task[Any] | None = None
    self._init_messaging()
    self._init_params()

  def _init_messaging(self) -> None:
    try:
      _ensure_pythonpath(self.repo)
      from cereal import messaging  # type: ignore

      self.messaging = messaging
      self.sm = messaging.SubMaster(self.SERVICES)
      self.last_error = ""
      print("[linkhud] messaging ready")
    except Exception as e:
      self.messaging = None
      self.sm = None
      self.last_error = f"messaging init failed: {e}"
      print(f"[linkhud] {self.last_error}")

  def _init_params(self) -> None:
    try:
      _ensure_pythonpath(self.repo)
      try:
        from common.params import Params  # type: ignore
      except Exception:
        from openpilot.common.params import Params  # type: ignore
      self._params = Params()
      print("[linkhud] params ready")
    except Exception as e:
      self._params = None
      print(f"[linkhud] params unavailable: {e}")

  def _read_hud_params(self) -> dict[str, Any]:
    now = time.monotonic()
    if now - self._hud_params_last_read < self.PARAM_REFRESH_INTERVAL:
      return dict(self._hud_params_cache)

    self._hud_params_last_read = now
    if self._params is None:
      return dict(self._hud_params_cache)

    try:
      personality_raw = int(self._params.get_int("LongitudinalPersonality"))
      self._hud_params_cache["personalityRaw"] = personality_raw
      self._hud_params_cache["tfGapDisplay"] = max(0, personality_raw + 1)
      self._hud_params_cache["showDeviceState"] = int(
        self._params.get_int("ShowDeviceState")
      ) != 0
      self._hud_params_cache["showDateTimeMode"] = int(
        self._params.get_int("ShowDateTime")
      )
    except Exception:
      pass

    return dict(self._hud_params_cache)

  def _compute_metric_primary_mode(self) -> str:
    now = time.monotonic()
    if self._hud_metric_toggle_last <= 0.0:
      self._hud_metric_toggle_last = now
    elif now - self._hud_metric_toggle_last >= self.METRIC_TOGGLE_INTERVAL:
      self._hud_metric_toggle_last = now
      self._hud_metric_show_volt = not self._hud_metric_show_volt
    return "volt" if self._hud_metric_show_volt else "disk"

  def _gear_text_for_hud(self, cs: Any) -> str:
    raw_gear = str(getattr(cs, "gearShifter", "") or "").strip().lower()
    gear_step = _safe_int(getattr(cs, "gearStep", None))
    if raw_gear == "unknown" or not raw_gear:
      return "U"
    if raw_gear == "park":
      return "P"
    if raw_gear == "drive":
      return str(gear_step) if gear_step is not None and gear_step > 0 else "D"
    if raw_gear == "neutral":
      return "N"
    if raw_gear == "reverse":
      return "R"
    if raw_gear == "low":
      return "L"
    if raw_gear == "sport":
      return "S"
    return "X"

  def _device_cpu_metrics_for_hud(self, ds: Any) -> tuple[float | None, float | None]:
    cpu_list = getattr(ds, "cpuTempC", None)
    values: list[float] = []
    if cpu_list is not None:
      try:
        for v in cpu_list:
          fv = _safe_float(v)
          if fv is not None and math.isfinite(fv) and fv > 0.0:
            values.append(fv)
      except TypeError:
        fv = _safe_float(cpu_list)
        if fv is not None and math.isfinite(fv) and fv > 0.0:
          values.append(fv)
      except Exception:
        values = []
    if not values:
      return (None, None)
    return (sum(values) / float(len(values)), max(values))

  def _resolve_gps_state_for_hud(self) -> tuple[bool, str | None]:
    if self.sm is None:
      return (False, None)

    for key, provider in (
      ("gpsLocationExternal", "gpsLocationExternal"),
      ("gpsLocation", "gpsLocation"),
    ):
      try:
        if not self.sm.alive.get(key, False):
          continue
        msg = self.sm[key]
        return (bool(getattr(msg, "hasFix", False)), provider)
      except Exception:
        continue
    return (False, None)

  def _build_hud_snapshot(self) -> dict[str, Any]:
    # Canonical contract for the original c3 lower-left HUD clone in CarrotLink.
    # This path is only for the lower-left status HUD, not TBT/navigation overlay.
    #
    # Render targets expected by the app:
    # - top band: CPU, MEM, DISK/VOLT
    # - left main: current speed
    # - right main: set speed
    # - right support: apply source/apply speed, gap, gear
    # - bottom strip: drive mode | LIMIT/CAM/section | APN/APM
    #
    # Do not repurpose these slots for transport/debug metadata such as
    # semantic/live labels, host IP, compatibility text, or TBT strings.
    payload: dict[str, Any] = {
      "version": 1,
      "tsMonoMs": int(time.monotonic() * 1000.0),
      "source": {"transport": "carrot_linkhud"},
      "meta": {"quality": "semantic"},
    }
    if self.sm is None:
      payload["meta"] = {
        "quality": "degraded",
        "missingFields": ["remote.unavailable"],
      }
      payload["error"] = self.last_error or "messaging unavailable"
      return payload

    self.sm.update(0)
    hud_params = self._read_hud_params()

    cs = self.sm["carState"] if self.sm.alive.get("carState", False) else None
    ds = self.sm["deviceState"] if self.sm.alive.get("deviceState", False) else None
    ss = self.sm["selfdriveState"] if self.sm.alive.get("selfdriveState", False) else None
    ps = self.sm["peripheralState"] if self.sm.alive.get("peripheralState", False) else None
    lp = self.sm["longitudinalPlan"] if self.sm.alive.get("longitudinalPlan", False) else None
    cm = self.sm["carrotMan"] if self.sm.alive.get("carrotMan", False) else None

    speed_cluster_kph = None
    set_speed_cluster_kph = None
    gear_text = "U"
    if cs is not None:
      speed_cluster_kph = _safe_float(getattr(cs, "vEgoCluster", None))
      v_ego = _safe_float(getattr(cs, "vEgo", None))
      v_ego_kph = v_ego * 3.6 if v_ego is not None else None
      if speed_cluster_kph is None or (
        v_ego_kph is not None and v_ego_kph > 0.8 and speed_cluster_kph <= 0.1
      ):
        speed_cluster_kph = v_ego_kph
      set_speed_cluster_kph = _safe_float(getattr(cs, "vCruiseCluster", None))
      gear_text = self._gear_text_for_hud(cs)

    speed_cluster_mps = speed_cluster_kph / 3.6 if speed_cluster_kph is not None else None
    set_speed_cluster_mps = (
      set_speed_cluster_kph / 3.6 if set_speed_cluster_kph is not None else None
    )

    payload["vehicle"] = {
      "speedClusterKph": speed_cluster_kph,
      "setSpeedClusterKph": set_speed_cluster_kph,
      "speedClusterMps": speed_cluster_mps,
      "setSpeedClusterMps": set_speed_cluster_mps,
      "gearText": gear_text,
      "longActive": bool(getattr(ss, "enabled", False)) if ss is not None else False,
      "latActive": bool(getattr(ss, "active", False)) if ss is not None else False,
    }

    apply_speed_kph = _safe_float(getattr(cm, "desiredSpeed", None)) if cm is not None else None
    apply_source = str(getattr(cm, "desiredSource", "") or "").strip() if cm is not None else ""
    display_apply_source = apply_source
    if (
      display_apply_source
      and apply_speed_kph is not None
      and set_speed_cluster_kph is not None
      and apply_speed_kph >= set_speed_cluster_kph
    ):
      display_apply_source = ""
    cruise_target_kph = _safe_float(getattr(lp, "cruiseTarget", None)) if lp is not None else None
    is_decel = (
      apply_speed_kph is not None
      and set_speed_cluster_kph is not None
      and apply_speed_kph < (set_speed_cluster_kph - 0.5)
    )
    if display_apply_source and apply_speed_kph is not None:
      payload["tempControl"] = {
        "mode": "apply",
        "label": display_apply_source,
        "speedKph": apply_speed_kph,
        "sourceRaw": apply_source,
        "applySpeedKph": apply_speed_kph,
        "cruiseTargetKph": cruise_target_kph,
        "isDecel": is_decel,
      }
    elif (
      cruise_target_kph is not None
      and set_speed_cluster_kph is not None
      and abs(cruise_target_kph - set_speed_cluster_kph) > 0.5
    ):
      payload["tempControl"] = {
        "mode": "eco",
        "label": "eco",
        "speedKph": cruise_target_kph,
        "sourceRaw": apply_source or None,
        "applySpeedKph": apply_speed_kph,
        "cruiseTargetKph": cruise_target_kph,
        "isDecel": is_decel,
      }
    else:
      payload["tempControl"] = {
        "mode": "hidden",
        "sourceRaw": apply_source or None,
        "applySpeedKph": apply_speed_kph,
        "cruiseTargetKph": cruise_target_kph,
        "isDecel": is_decel,
      }

    drive_mode_code = _safe_int(getattr(lp, "myDrivingMode", None)) if lp is not None else None
    drive_mode_name = "NORM"
    drive_mode_kind = "normal"
    if drive_mode_code == 1:
      drive_mode_name = "ECO"
      drive_mode_kind = "eco"
    elif drive_mode_code == 2:
      drive_mode_name = "SAFE"
      drive_mode_kind = "safe"
    elif drive_mode_code == 4:
      drive_mode_name = "FAST"
      drive_mode_kind = "fast"
    payload["driveMode"] = {
      "code": drive_mode_code,
      "nameOriginal": drive_mode_name,
      "kind": drive_mode_kind,
    }

    tf_gap_display = max(0, _safe_int(hud_params.get("tfGapDisplay")) or 0)
    payload["gap"] = {
      "personalityRaw": _safe_int(hud_params.get("personalityRaw")),
      "displayValue": tf_gap_display,
      "barCount": tf_gap_display,
    }

    road_limit_kph = _safe_float(getattr(cm, "nRoadLimitSpeed", None)) if cm is not None else None
    camera_limit_kph = _safe_float(getattr(cm, "xSpdLimit", None)) if cm is not None else None
    camera_sign_type = _safe_int(getattr(cm, "xSpdType", None)) if cm is not None else None
    limit_mode = "hidden"
    limit_label = None
    display_limit_kph = None
    if camera_limit_kph is not None and camera_limit_kph > 0.0 and camera_sign_type == 4:
      limit_mode = "section"
      limit_label = "구간"
      display_limit_kph = camera_limit_kph
    elif (
      camera_limit_kph is not None
      and camera_limit_kph > 0.0
      and camera_sign_type not in (22, 4)
    ):
      limit_mode = "camera"
      limit_label = "CAM"
      display_limit_kph = camera_limit_kph
    elif road_limit_kph is not None and road_limit_kph > 0.0:
      limit_mode = "limit"
      limit_label = "LIMIT"
      display_limit_kph = road_limit_kph
    is_over_limit = (
      display_limit_kph is not None
      and speed_cluster_kph is not None
      and speed_cluster_kph > (display_limit_kph + 2.0)
    )
    payload["limits"] = {
      "mode": limit_mode,
      "label": limit_label,
      "displaySpeedKph": display_limit_kph,
      "roadLimitSpeedKph": road_limit_kph,
      "cameraLimitSpeedKph": camera_limit_kph,
      "cameraSignType": camera_sign_type,
      "isOverLimit": is_over_limit,
      "shouldBlink": limit_mode == "camera",
    }

    active_carrot = _safe_int(getattr(cm, "activeCarrot", None)) if cm is not None else None
    badge_mode = "hidden"
    badge_label = None
    if active_carrot is not None:
      if active_carrot >= 2:
        badge_mode = "apn"
        badge_label = "APN"
      elif active_carrot >= 1:
        badge_mode = "apm"
        badge_label = "APM"
    payload["connectivity"] = {
      "activeCarrot": active_carrot,
      "badgeMode": badge_mode,
      "badgeLabel": badge_label,
    }

    traffic_state_lp = _safe_int(getattr(lp, "trafficState", None)) if lp is not None else None
    traffic_state_carrot = _safe_int(getattr(cm, "trafficState", None)) if cm is not None else None
    visual_state = "off"
    if traffic_state_carrot == 1 or traffic_state_lp == 1:
      visual_state = "red"
    elif traffic_state_carrot == 2 or traffic_state_lp == 2:
      visual_state = "green"
    payload["signals"] = {
      "trafficStateLp": traffic_state_lp,
      "trafficStateCarrot": traffic_state_carrot,
      "visualState": visual_state,
      "redDot": visual_state == "red",
    }

    gps_has_fix, gps_provider = self._resolve_gps_state_for_hud()
    payload["gps"] = {
      "hasFix": gps_has_fix,
      "provider": gps_provider,
    }

    cpu_avg_c = None
    cpu_max_c = None
    mem_usage_pct = None
    free_space_pct = None
    if ds is not None:
      cpu_avg_c, cpu_max_c = self._device_cpu_metrics_for_hud(ds)
      mem_usage_pct = _safe_float(getattr(ds, "memoryUsagePercent", None))
      free_space_pct = _safe_float(getattr(ds, "freeSpacePercent", None))
    disk_used_pct = (100.0 - free_space_pct) if free_space_pct is not None else None
    volt_v = None
    if ps is not None:
      voltage_raw = _safe_float(getattr(ps, "voltage", None))
      volt_v = voltage_raw / 1000.0 if voltage_raw is not None else None
    payload["device"] = {
      "cpuTempAvgC": cpu_avg_c,
      "cpuTempMaxC": cpu_max_c,
      "memUsagePct": mem_usage_pct,
      "diskUsedPct": disk_used_pct,
      "freeSpacePct": free_space_pct,
      "voltV": volt_v,
      "metricPrimaryMode": self._compute_metric_primary_mode(),
    }

    payload["visibility"] = {
      "showDeviceState": bool(hud_params.get("showDeviceState", True)),
      "showDateTimeMode": _safe_int(hud_params.get("showDateTimeMode")),
    }
    return payload

  async def _broadcast_loop(self) -> None:
    while True:
      try:
        if not self.hud_clients:
          await asyncio.sleep(self.IDLE_INTERVAL)
          continue

        build_started = time.monotonic()
        hud_payload = self._build_hud_snapshot()
        hud_message = json.dumps(hud_payload, separators=(",", ":"), ensure_ascii=False)
        self._last_hud_build_ms = max(0.0, (time.monotonic() - build_started) * 1000.0)

        send_jobs: list[tuple[web.WebSocketResponse, asyncio.Task[Any]]] = []
        stale: list[web.WebSocketResponse] = []
        batch_started = time.monotonic()
        for ws in list(self.hud_clients):
          try:
            send_jobs.append((
              ws,
              asyncio.create_task(
                asyncio.wait_for(ws.send_str(hud_message), timeout=self.SEND_TIMEOUT)
              ),
            ))
          except Exception:
            stale.append(ws)

        if send_jobs:
          results = await asyncio.gather(
            *[task for _, task in send_jobs],
            return_exceptions=True,
          )
          self._last_hud_send_batch_ms = max(
            0.0,
            (time.monotonic() - batch_started) * 1000.0,
          )
          for (ws, _), result in zip(send_jobs, results):
            if not isinstance(result, Exception):
              self._hud_send_failures.pop(ws, None)
              continue
            fail_count = self._hud_send_failures.get(ws, 0) + 1
            self._hud_send_failures[ws] = fail_count
            if fail_count >= 3:
              self._hud_send_drop_count += 1
              stale.append(ws)

        for ws in stale:
          self.hud_clients.discard(ws)
          self._hud_send_failures.pop(ws, None)
          try:
            await ws.close(code=1011, message=b"hud_send_failed")
          except Exception:
            pass

        await asyncio.sleep(self.ACTIVE_INTERVAL)
      except asyncio.CancelledError:
        break
      except Exception as e:
        self.last_error = f"broadcast error: {e}"
        await asyncio.sleep(0.25)

  async def ws_hud(self, request: web.Request) -> web.WebSocketResponse:
    ws = web.WebSocketResponse(heartbeat=20)
    await ws.prepare(request)
    self.hud_clients.add(ws)
    try:
      initial = self._build_hud_snapshot()
      await ws.send_str(json.dumps(initial, separators=(",", ":"), ensure_ascii=False))
      async for _ in ws:
        pass
    finally:
      self.hud_clients.discard(ws)
      self._hud_send_failures.pop(ws, None)
      try:
        await ws.close()
      except Exception:
        pass
    return ws

  async def get_health(self, request: web.Request) -> web.Response:
    return web.json_response({
      "ok": self.sm is not None,
      "source": "carrot_linkhud",
      "repo": self.repo,
      "clients": len(self.hud_clients),
      "error": self.last_error,
      "hudRelay": {
        "clients": len(self.hud_clients),
        "sendDrops": self._hud_send_drop_count,
        "lastBuildMs": round(self._last_hud_build_ms, 1),
        "lastSendBatchMs": round(self._last_hud_send_batch_ms, 1),
      },
      "intervalMs": int(self.ACTIVE_INTERVAL * 1000.0),
    })

  async def on_startup(self, app: web.Application) -> None:
    self._broadcast_task = asyncio.create_task(self._broadcast_loop())
    app["broadcast_task"] = self._broadcast_task

  async def on_cleanup(self, app: web.Application) -> None:
    task = self._broadcast_task or app.get("broadcast_task")
    if task is None:
      return
    task.cancel()
    try:
      await task
    except asyncio.CancelledError:
      pass


def main() -> None:
  host = os.environ.get("CARROTLINK_HUD_HOST", "0.0.0.0").strip() or "0.0.0.0"
  port = int(os.environ.get("CARROTLINK_HUD_PORT", "7767"))

  app_state = LinkHudApp()
  app = web.Application()
  app.router.add_get("/health", app_state.get_health)
  app.router.add_get("/ws/hud", app_state.ws_hud)
  app.on_startup.append(app_state.on_startup)
  app.on_cleanup.append(app_state.on_cleanup)

  print(f"[linkhud] starting host={host} port={port}")
  web.run_app(app, host=host, port=port)


if __name__ == "__main__":
  main()
