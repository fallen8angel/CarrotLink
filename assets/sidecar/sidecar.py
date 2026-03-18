#!/usr/bin/env python3
import asyncio
import json
import math
import os
import subprocess
import struct
import sys
import time
import zlib
from typing import Any

try:
    import msgpack as _msgpack  # type: ignore[import-untyped]
except ImportError:
    _msgpack = None

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
        os.environ["PYTHONPATH"] = f"{repo}:{os.environ.get('PYTHONPATH', '')}".rstrip(
            ":"
        )


def _detect_base_dir() -> str:
    base = os.environ.get("CARROTLINK_SIDECAR_BASE", "").strip()
    if base:
        return base
    try:
        return os.path.dirname(os.path.abspath(__file__))
    except Exception:
        return ""


def _detect_repo_flavor(repo: str, base_dir: str = "") -> str:
    env_flavor = os.environ.get("CARROTLINK_OPENPILOT_FLAVOR", "").strip().lower()
    if env_flavor in ("c3", "c4"):
        return env_flavor

    candidates: list[str] = []
    if repo:
        candidates.append(repo)
    if base_dir:
        try:
            repo_from_base = os.path.abspath(os.path.join(base_dir, "..", ".."))
            if (
                repo_from_base
                and repo_from_base not in candidates
                and os.path.isdir(os.path.join(repo_from_base, "selfdrive"))
            ):
                candidates.append(repo_from_base)
        except Exception:
            pass

    def _flavor_from_branch(path: str) -> str:
        try:
            completed = subprocess.run(
                ["git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD"],
                check=False,
                capture_output=True,
                text=True,
                timeout=1.5,
            )
            branch = (completed.stdout or "").strip().lower()
        except Exception:
            branch = ""
        if not branch:
            return ""
        tokens = branch.replace("_", "-").replace("/", "-").split("-")
        if "c4" in tokens:
            return "c4"
        if "c3" in tokens:
            return "c3"
        return ""

    for path in candidates:
        branch_flavor = _flavor_from_branch(path)
        if branch_flavor:
            return branch_flavor
        cfg = os.path.join(path, "system", "manager", "process_config.py")
        if not os.path.isfile(cfg):
            continue
        try:
            with open(cfg, "r", encoding="utf-8") as fp:
                text = fp.read()
        except Exception:
            try:
                with open(cfg, "r", errors="ignore") as fp:
                    text = fp.read()
            except Exception:
                text = ""
        if 'PythonProcess("ui"' in text or "PythonProcess('ui'" in text:
            return "c4"
        if 'NativeProcess("ui"' in text or "NativeProcess('ui'" in text:
            return "c3"
    return "unknown"


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


_MODEL_GEOMETRY_POINTS = 48
_MODEL_GEOMETRY_PRECISION = 3


def _downsample(
    values: list[float], max_points: int = 24, precision: int = 1
) -> list[float]:
    if len(values) <= max_points:
        return [round(v, precision) for v in values]
    if max_points <= 1:
        return [round(values[0], precision)]
    step = (len(values) - 1) / float(max_points - 1)
    out = []
    for i in range(max_points):
        idx = int(round(i * step))
        out.append(round(values[idx], precision))
    return out


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
    CAMERA_QUEUE_MAXSIZE = 2
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
    QUALITY_MODES = ("quality", "stable")

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
            cam: asyncio.Queue(maxsize=self.CAMERA_QUEUE_MAXSIZE)
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
            cam: "" for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
        }
        self._queue_drop_count: dict[str, int] = {
            cam: 0 for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
        }
        self._send_drop_count: dict[str, int] = {
            cam: 0 for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
        }
        self._last_frame_at_mono: dict[str, float] = {
            cam: 0.0 for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
        }
        self._last_frame_id: dict[str, int] = {
            cam: -1 for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
        }
        self._last_send_batch_ms: dict[str, float] = {
            cam: 0.0 for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
        }
        self._quality_mode = self._normalize_quality_mode(
            os.environ.get("CARROTLINK_CAMERA_QUALITY_MODE", "quality")
        )
        self._lock = asyncio.Lock()

    def _normalize_quality_mode(self, mode: Any) -> str:
        value = str(mode or "").strip().lower()
        if value in ("stable", "low_latency", "low-latency", "latency"):
            return "stable"
        return "quality"

    def set_quality_mode(self, mode: Any) -> str:
        self._quality_mode = self._normalize_quality_mode(mode)
        return self._quality_mode

    def get_quality_mode(self) -> str:
        return self._quality_mode

    def rebind_messaging(self, messaging: Any) -> None:
        self.messaging = messaging
        self._sockets = {
            cam: {} for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
        }
        self._selected_service = {
            cam: "" for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
        }

    async def reset_runtime_state(self, reason: str = "runtime_reset") -> None:
        async with self._lock:
            self._sockets = {
                cam: {} for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
            }
            self._selected_service = {
                cam: "" for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
            }
            self._last_codec = {
                cam: "" for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
            }
            self._last_frame_at_mono = {
                cam: 0.0 for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
            }
            self._last_frame_id = {
                cam: -1 for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
            }
            self._last_send_batch_ms = {
                cam: 0.0 for cam in self.CAMERA_SERVICE_CANDIDATES.keys()
            }
            self._ws_send_failures = {}
            for queue in self._queues.values():
                while not queue.empty():
                    try:
                        queue.get_nowait()
                    except Exception:
                        break
        print(f"[sidecar] camera runtime reset reason={reason}")

    def _ordered_camera_services(self, camera: str) -> list[str]:
        base = list(self.CAMERA_SERVICE_CANDIDATES.get(camera, []))
        if not base:
            return []
        if self._quality_mode == "stable":
            return base[:1]
        # quality mode: prefer full encode first, then livestream fallback.
        return list(reversed(base))

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

                frame_id = _safe_int(getattr(frame, "frameId", None))
                packet = self._pack_frame(camera, frame)
                if queue.full():
                    try:
                        queue.get_nowait()
                        self._queue_drop_count[camera] += 1
                    except Exception:
                        pass
                try:
                    queue.put_nowait(packet)
                except Exception:
                    await asyncio.sleep(0.001)
                    continue
                self._frame_count[camera] += 1
                self._last_frame_at_mono[camera] = time.monotonic()
                if frame_id is not None and frame_id >= 0:
                    self._last_frame_id[camera] = frame_id
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
                quality_mode = self._quality_mode
                send_timeout = 0.35 if quality_mode == "quality" else 0.25
                timeout_fail_limit = 5 if quality_mode == "quality" else 4
                if not self.clients.get(camera):
                    keep_count = 1
                    while queue.qsize() > keep_count:
                        try:
                            queue.get_nowait()
                            self._queue_drop_count[camera] += 1
                        except Exception:
                            break
                    await asyncio.sleep(0.03)
                    continue

                try:
                    packet = await asyncio.wait_for(queue.get(), timeout=0.25)
                except asyncio.TimeoutError:
                    continue

                # Low-latency mode prefers the freshest frame over guaranteed
                # delivery of every queued frame.
                while not queue.empty():
                    try:
                        packet = queue.get_nowait()
                        self._queue_drop_count[camera] += 1
                    except Exception:
                        break

                stale: list[web.WebSocketResponse] = []
                clients = list(self.clients.get(camera, set()))
                send_started = time.monotonic()
                results = await asyncio.gather(
                    *[
                        asyncio.wait_for(ws.send_bytes(packet), timeout=send_timeout)
                        for ws in clients
                    ],
                    return_exceptions=True,
                )
                self._last_send_batch_ms[camera] = max(
                    0.0,
                    (time.monotonic() - send_started) * 1000.0,
                )
                for ws, result in zip(clients, results):
                    if not isinstance(result, Exception):
                        self._ws_send_failures.pop(ws, None)
                        continue
                    fail_count = self._ws_send_failures.get(ws, 0) + 1
                    self._ws_send_failures[ws] = fail_count
                    if fail_count >= timeout_fail_limit:
                        stale.append(ws)
                        self._drop_count[camera] += 1
                        self._send_drop_count[camera] += 1
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
                self._producer_tasks[camera] = asyncio.create_task(
                    self._camera_producer_loop(camera)
                )
            sender = self._sender_tasks.get(camera)
            if sender is None or sender.done():
                self._sender_tasks[camera] = asyncio.create_task(
                    self._camera_sender_loop(camera)
                )

    async def stop_all(self) -> None:
        async with self._lock:
            tasks = list(self._producer_tasks.values()) + list(
                self._sender_tasks.values()
            )
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
            last_frame_at = self._last_frame_at_mono.get(camera, 0.0)
            last_frame_age_ms = (
                max(0, int((time.monotonic() - last_frame_at) * 1000.0))
                if last_frame_at > 0.0
                else None
            )
            cameras[camera] = {
                "clients": len(self.clients.get(camera, set())),
                "frames": self._frame_count.get(camera, 0),
                "drops": self._drop_count.get(camera, 0),
                "codec": self._last_codec.get(camera, ""),
                "queue": self._queues[camera].qsize(),
                "queueMax": self.CAMERA_QUEUE_MAXSIZE,
                "queueDrops": self._queue_drop_count.get(camera, 0),
                "sendDrops": self._send_drop_count.get(camera, 0),
                "lastFrameId": self._last_frame_id.get(camera, -1),
                "lastFrameAgeMs": last_frame_age_ms,
                "lastSendBatchMs": round(self._last_send_batch_ms.get(camera, 0.0), 1),
                "service": self._selected_service.get(camera, ""),
            }
        return {
            "mode": "queued_multi_sub_fanout",
            "qualityMode": self._quality_mode,
            "cameras": cameras,
        }


class SidecarApp:
    PROFILE_SERVICES = {
        "p0": [
            "carState",
            "selfdriveState",
        ],
        "p1": [
            "carState",
            "selfdriveState",
            "liveCalibration",
        ],
        "p1c4": [
            "selfdriveState",
            "liveCalibration",
        ],
        "p2": [
            "carState",
            "selfdriveState",
            "carControl",
            "controlsState",
            "longitudinalPlan",
            "liveCalibration",
            "liveDelay",
            "liveParameters",
            "liveTorqueParameters",
            "modelV2",
            "radarState",
            "roadCameraState",
            "wideRoadCameraState",
        ],
        "p3": [
            "carState",
            "selfdriveState",
            "carControl",
            "controlsState",
            "longitudinalPlan",
            "liveCalibration",
            "liveDelay",
            "liveParameters",
            "liveTorqueParameters",
            "modelV2",
            "radarState",
            "roadCameraState",
            "wideRoadCameraState",
        ],
        # p4: high-rate alias of p3 services for aggressive HUD refresh.
        "p4": [
            "carState",
            "selfdriveState",
            "carControl",
            "controlsState",
            "longitudinalPlan",
            "liveCalibration",
            "liveDelay",
            "liveParameters",
            "liveTorqueParameters",
            "modelV2",
            "radarState",
            "roadCameraState",
            "wideRoadCameraState",
        ],
    }

    PROFILE_SM_UPDATE_INTERVAL = {
        "p0": 0.08,
        "p1": 0.06,
        "p1c4": 0.08,
        "p2": 0.033,
        "p3": 0.033,
        "p4": 0.025,
    }

    PROFILE_LIVE_INTERVAL = {
        "p0": 0.16,
        "p1": 0.12,
        "p1c4": 0.16,
        "p2": 0.033,
        "p3": 0.033,
        "p4": 0.025,
    }

    PROFILE_LIVE_CACHE_INTERVAL = {
        "p0": 0.12,
        "p1": 0.08,
        "p1c4": 0.12,
        "p2": 0.033,
        "p3": 0.033,
        "p4": 0.025,
    }

    PROFILE_HUD_INTERVAL = {
        "p0": 0.10,
        "p1": 0.08,
        "p1c4": 0.10,
        "p2": 0.08,
        "p3": 0.08,
        "p4": 0.08,
    }

    SUPPORTED_VARIANTS = {"default", "c4_safe"}
    C4_SAFE_BOOTSTRAP_NO_CARSTATE_PROFILES = ("p1c4",)
    # C4-safe uses a lighter bootstrap profile without carState and only
    # graduates to live profiles after HUD/camera health stabilizes.
    C4_SAFE_RELAXATION_ENABLED = False
    C4_SAFE_LIVE_PROFILES = ("p2", "p3", "p4")
    C4_SAFE_RADAR_MONITOR_PROFILES = ("p1", "p1c4", "p2", "p3", "p4")
    C4_SAFE_STARTUP_GRACE_SEC = 12.0
    C4_SAFE_RADAR_STABLE_SEC = 1.5
    C4_SAFE_SM_UPDATE_INTERVAL = {
        "p2": 0.06,
        "p3": 0.06,
        "p4": 0.05,
    }
    C4_SAFE_LIVE_INTERVAL = {
        "p2": 0.06,
        "p3": 0.06,
        "p4": 0.05,
    }
    C4_SAFE_LIVE_CACHE_INTERVAL = {
        "p2": 0.06,
        "p3": 0.06,
        "p4": 0.05,
    }


    def __init__(self, profile: str, variant: str = "default"):
        self.profile = profile if profile in self.PROFILE_SERVICES else "p2"
        normalized_variant = str(variant or "").strip().lower()
        self.variant = (
            normalized_variant
            if normalized_variant in self.SUPPORTED_VARIANTS
            else "default"
        )
        self.base_dir = _detect_base_dir()
        self.repo = _detect_repo()
        self.repo_flavor = _detect_repo_flavor(self.repo, self.base_dir)
        self.clients: dict[web.WebSocketResponse, tuple[str, str, str, str]] = {}
        self.hud_clients: dict[web.WebSocketResponse, tuple[str, str, str]] = {}
        self.messaging = None
        self.sm = None
        self._camera_hub: CameraRelayHub | None = None
        self.last_error = ""
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
        self._plot_mode_last_read = 0.0
        self._plot_mode_cache = 0
        self._debug_plot_last_built = 0.0
        self._debug_plot_cache: dict[str, Any] | None = None
        self._cached_calibration_last_read = 0.0
        self._cached_calibration_cache: dict[str, Any] | None = None
        self._live_optional_cache: dict[str, Any] | None = None
        self._live_optional_last_built = 0.0
        self._last_optional_build_ms = 0.0
        self._diag_snapshot_path = (
            os.path.join(self.base_dir, "diag_snapshot.json")
            if self.base_dir
            else "diag_snapshot.json"
        )
        self._live_send_failures: dict[web.WebSocketResponse, int] = {}
        self._live_send_drop_count = 0
        self._last_live_build_ms = 0.0
        self._last_live_send_batch_ms = 0.0
        self._hud_send_failures: dict[web.WebSocketResponse, int] = {}
        self._hud_send_drop_count = 0
        self._last_hud_build_ms = 0.0
        self._last_hud_send_batch_ms = 0.0
        self._hud_params_last_read = 0.0
        self._hud_params_cache: dict[str, Any] = {
            "personalityRaw": None,
            "tfGapDisplay": 0,
            "showDeviceState": True,
            "showDateTimeMode": 1,
            "customSr": None,
        }
        self._hud_metric_toggle_last = 0.0
        self._hud_metric_show_volt = False
        self._last_sm_update_mono = 0.0
        self._sm_update_min_interval = 0.02
        self._cached_live_payload: dict[str, Any] | None = None
        self._cached_live_json: str | None = None
        self._cached_live_zlib_json: bytes | None = None
        self._cached_live_msgpack: bytes | None = None
        self._cached_live_last_built = 0.0
        self._cached_hud_payload: dict[str, Any] | None = None
        self._cached_hud_json: str | None = None
        self._cached_hud_msgpack: bytes | None = None
        self._cached_hud_last_built = 0.0
        self._profile_generation = 0
        self._service_last_alive_mono: dict[str, float] = {}
        self._service_last_updated_mono: dict[str, float] = {}
        self._profile_started_mono = time.monotonic()
        self._radar_fresh_since_mono = 0.0

        self._init_messaging()
        self._init_params()

    def _invalidate_broadcast_caches(self) -> None:
        self._cached_live_payload = None
        self._cached_live_json = None
        self._cached_live_zlib_json = None
        self._cached_live_msgpack = None
        self._cached_live_last_built = 0.0
        self._cached_hud_payload = None
        self._cached_hud_json = None
        self._cached_hud_msgpack = None
        self._cached_hud_last_built = 0.0

    def _sm_update_loop_interval(self) -> float:
        base = self.PROFILE_SM_UPDATE_INTERVAL.get(self.profile, 0.05)
        override = self._variant_interval_override(
            self.C4_SAFE_SM_UPDATE_INTERVAL
        )
        return max(base, override) if override is not None else base

    def _live_broadcast_interval(self) -> float:
        base = self.PROFILE_LIVE_INTERVAL.get(self.profile, 0.05)
        override = self._variant_interval_override(self.C4_SAFE_LIVE_INTERVAL)
        return max(base, override) if override is not None else base

    def _live_cache_interval(self) -> float:
        base = self.PROFILE_LIVE_CACHE_INTERVAL.get(
            self.profile,
            self._live_broadcast_interval(),
        )
        override = self._variant_interval_override(
            self.C4_SAFE_LIVE_CACHE_INTERVAL
        )
        return max(base, override) if override is not None else base

    def _hud_interval(self) -> float:
        return self.PROFILE_HUD_INTERVAL.get(self.profile, 0.10)

    def _payload_cache_loop_interval(self) -> float:
        if self.clients and self.hud_clients:
            return min(self._live_cache_interval(), self._hud_interval())
        if self.clients:
            return self._live_cache_interval()
        if self.hud_clients:
            return self._hud_interval()
        return 0.10

    def _reset_profile_runtime_state(self, reason: str = "profile_switch") -> None:
        self._invalidate_broadcast_caches()
        self._live_optional_cache = None
        self._live_optional_last_built = 0.0
        self._last_optional_build_ms = 0.0
        self._cached_calibration_last_read = 0.0
        self._cached_calibration_cache = None
        self._debug_plot_last_built = 0.0
        self._debug_plot_cache = None
        self._plot_mode_last_read = 0.0
        self._path_style_last_read = 0.0
        self._hud_params_last_read = 0.0
        self._hud_metric_toggle_last = 0.0
        self._last_live_build_ms = 0.0
        self._last_live_send_batch_ms = 0.0
        self._last_hud_build_ms = 0.0
        self._last_hud_send_batch_ms = 0.0
        self._live_send_failures.clear()
        self._hud_send_failures.clear()
        self._last_sm_update_mono = 0.0
        self._service_last_alive_mono = {}
        self._service_last_updated_mono = {}
        self._profile_started_mono = time.monotonic()
        self._radar_fresh_since_mono = 0.0
        self._profile_generation += 1
        if hasattr(self, "_calib_cache"):
            delattr(self, "_calib_cache")
        if hasattr(self, "_calib_cache_tick"):
            delattr(self, "_calib_cache_tick")
        print(
            f"[sidecar] profile runtime reset reason={reason} generation={self._profile_generation}"
        )

    def _radar_stable_for_variant(self, now: float | None = None) -> bool:
        if (
            not self.C4_SAFE_RELAXATION_ENABLED
            or
            self.variant != "c4_safe"
            or self.profile not in self.C4_SAFE_RADAR_MONITOR_PROFILES
        ):
            return False
        current = time.monotonic() if now is None else now
        radar_ready = self._service_ready("radarState", require_updated=True)
        if not radar_ready:
            self._radar_fresh_since_mono = 0.0
            return False
        if self._radar_fresh_since_mono <= 0.0:
            self._radar_fresh_since_mono = current
            return False
        return (
            current - self._radar_fresh_since_mono
        ) >= self.C4_SAFE_RADAR_STABLE_SEC

    def _variant_soft_mode_active(self, now: float | None = None) -> bool:
        if (
            not self.C4_SAFE_RELAXATION_ENABLED
            or
            self.variant != "c4_safe"
            or self.profile not in self.C4_SAFE_RADAR_MONITOR_PROFILES
        ):
            return False
        current = time.monotonic() if now is None else now
        if (current - self._profile_started_mono) >= self.C4_SAFE_STARTUP_GRACE_SEC:
            return False
        return not self._radar_stable_for_variant(now=current)

    def _services_for_profile(self, profile: str) -> list[str]:
        services = list(self.PROFILE_SERVICES.get(profile, []))
        if (
            self.C4_SAFE_RELAXATION_ENABLED
            and
            self.variant == "c4_safe"
            and profile == "p1"
            and "radarState" not in services
        ):
            services.append("radarState")
        return services

    def _variant_interval_override(
        self,
        interval_table: dict[str, float],
    ) -> float | None:
        if self.profile not in self.C4_SAFE_LIVE_PROFILES:
            return None
        if not self._variant_soft_mode_active():
            return None
        return interval_table.get(self.profile)

    def _init_messaging(self) -> None:
        self._invalidate_broadcast_caches()
        self._live_optional_cache = None
        self._live_optional_last_built = 0.0
        self._last_sm_update_mono = 0.0
        try:
            _ensure_pythonpath(self.repo)
            from cereal import messaging  # type: ignore

            self.messaging = messaging
            services = self._services_for_profile(self.profile)
            # Merge optional/hud services that Flutter still consumes.
            for s in [
                "deviceState", "peripheralState",
                "gpsLocationExternal", "gpsLocation",
                "lateralPlan", "carrotMan", "navInstructionCarrot",
            ]:
                if s not in services:
                    services.append(s)
            self._service_last_alive_mono = {name: 0.0 for name in services}
            self._service_last_updated_mono = {name: 0.0 for name in services}
            self.sm = messaging.SubMaster(services)
            if self._camera_hub is None:
                self._camera_hub = CameraRelayHub(messaging)
            else:
                self._camera_hub.rebind_messaging(messaging)
            self.last_error = ""
            print(
                f"[sidecar] messaging ready profile={self.profile} "
                f"services={len(services)}"
            )
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
                "showPathColorCruiseOff": int(
                    self._params.get_int("ShowPathColorCruiseOff")
                ),
                "showPathWidth": int(self._params.get_int("ShowPathWidth")),
                "showRadarInfo": int(self._params.get_int("ShowRadarInfo")),
                "radarLatFactor": float(self._params.get_float("RadarLatFactor")),
            }
        except Exception:
            pass
        return dict(self._path_style_cache)

    def _read_plot_mode(self) -> int:
        now = time.monotonic()
        if now - self._plot_mode_last_read < 1.0:
            return self._plot_mode_cache
        self._plot_mode_last_read = now
        if self._params is None:
            return self._plot_mode_cache
        try:
            self._plot_mode_cache = int(self._params.get_int("ShowPlotMode"))
        except Exception:
            pass
        return self._plot_mode_cache


    def _service_health(self, name: str) -> dict[str, Any]:
        sm_ref = self.sm
        alive_map = getattr(sm_ref, "alive", {}) if sm_ref is not None else {}
        valid_map = getattr(sm_ref, "valid", {}) if sm_ref is not None else {}
        updated_map = getattr(sm_ref, "updated", {}) if sm_ref is not None else {}
        now = time.monotonic()
        last_alive = self._service_last_alive_mono.get(name, 0.0)
        last_updated = self._service_last_updated_mono.get(name, 0.0)
        freshness_ms = self._service_freshness_limit_ms(name)
        diag: dict[str, Any] = {
            "subscribed": name in alive_map,
            "alive": bool(alive_map.get(name, False)),
            "updated": bool(updated_map.get(name, False)),
            "valid": bool(valid_map.get(name, False)),
            "aliveAgeMs": int(max(0.0, (now - last_alive) * 1000.0))
            if last_alive > 0.0
            else None,
            "updatedAgeMs": int(max(0.0, (now - last_updated) * 1000.0))
            if last_updated > 0.0
            else None,
            "freshnessLimitMs": freshness_ms,
        }
        diag["isFresh"] = (
            diag["updatedAgeMs"] is not None
            and diag["updatedAgeMs"] <= freshness_ms
        )
        if sm_ref is None or not diag["alive"]:
            return diag
        try:
            msg = sm_ref[name]
            if name == "selfdriveState":
                diag["enabled"] = bool(getattr(msg, "enabled", False))
                diag["active"] = bool(getattr(msg, "active", False))
                diag["engageable"] = bool(getattr(msg, "engageable", False))
                diag["state"] = str(getattr(msg, "state", "") or "")
            elif name == "liveCalibration":
                diag["calStatus"] = _safe_int(getattr(msg, "calStatus", None))
            elif name in ("roadCameraState", "wideRoadCameraState", "modelV2"):
                diag["frameId"] = _safe_int(getattr(msg, "frameId", None))
        except Exception:
            pass
        return diag

    def _service_freshness_limit_ms(self, name: str) -> int:
        limits = {
            "carState": 1200,
            "selfdriveState": 1200,
            "controlsState": 1200,
            "longitudinalPlan": 1200,
            "carrotMan": 1500,
            "navInstructionCarrot": 2000,
            "modelV2": 500,
            "radarState": 800,
            "roadCameraState": 500,
            "wideRoadCameraState": 700,
            "liveCalibration": 2500,
            "deviceState": 3000,
            "peripheralState": 3000,
            "gpsLocationExternal": 3000,
            "gpsLocation": 3000,
            "lateralPlan": 1500,
        }
        return limits.get(name, 1500)

    def _service_ready(
        self,
        name: str,
        *,
        require_updated: bool = False,
        require_frame: bool = False,
    ) -> bool:
        diag = self._service_health(name)
        if not diag.get("subscribed", False):
            return False
        if not diag.get("alive", False):
            return False
        if require_updated and not diag.get("isFresh", False):
            return False
        if require_frame and diag.get("frameId") is None:
            return False
        return True

    def _hud_stale_reasons(self) -> list[str]:
        reasons: list[str] = []

        def append_if_stale(service: str, code: str) -> None:
            diag = self._service_health(service)
            if diag.get("alive", False) and not diag.get("isFresh", False):
                reasons.append(code)

        append_if_stale("carState", "vehicle.carState.stale")
        append_if_stale("selfdriveState", "vehicle.selfdriveState.stale")
        append_if_stale("deviceState", "device.deviceState.stale")
        append_if_stale("peripheralState", "device.peripheralState.stale")
        append_if_stale("longitudinalPlan", "assist.longitudinalPlan.stale")
        append_if_stale("carrotMan", "assist.carrotMan.stale")
        append_if_stale("navInstructionCarrot", "nav.instruction.stale")

        if (
            self._last_sm_update_mono > 0.0
            and (time.monotonic() - self._last_sm_update_mono) * 1000.0 > 2500.0
        ):
            reasons.append("transport.smUpdate.stale")
        return reasons

    def _runtime_health_flags(
        self,
        camera_status: dict[str, Any],
    ) -> dict[str, Any]:
        process_ready = self.sm is not None and self.messaging is not None
        hud_requires_car_state = (
            self.profile not in self.C4_SAFE_BOOTSTRAP_NO_CARSTATE_PROFILES
        )
        hud_ready = process_ready and self._service_ready(
            "selfdriveState",
            require_updated=True,
        )
        if hud_ready and hud_requires_car_state:
            hud_ready = self._service_ready(
                "carState",
                require_updated=True,
            )
        carrot_ready = self._service_ready("carrotMan", require_updated=True)
        plan_ready = self._service_ready(
            "longitudinalPlan",
            require_updated=True,
        )
        nav_ready = self._service_ready("navInstructionCarrot", require_updated=True)
        live_ready = hud_ready and self._service_ready(
            "modelV2",
            require_updated=True,
            require_frame=True,
        ) and self._service_ready(
            "roadCameraState",
            require_updated=True,
            require_frame=True,
        )
        wide_ready = self._service_ready(
            "wideRoadCameraState",
            require_updated=True,
            require_frame=True,
        )
        road_camera = camera_status.get("cameras", {}).get("road", {})
        camera_ready = (
            live_ready
            and isinstance(road_camera, dict)
            and bool(str(road_camera.get("service", "")).strip())
        )
        semantic_ready = hud_ready and carrot_ready
        assist_ready = hud_ready and (carrot_ready or plan_ready)
        signal_ready = hud_ready and (plan_ready or carrot_ready)
        ready = hud_ready if self.profile in ("p0", "p1", "p1c4") else live_ready
        return {
            "processReady": process_ready,
            "transportReady": process_ready and self._camera_hub is not None,
            "hudReady": hud_ready,
            "semanticHudReady": semantic_ready,
            "assistReady": assist_ready,
            "signalReady": signal_ready,
            "carrotReady": carrot_ready,
            "planReady": plan_ready,
            "navReady": nav_ready,
            "liveReady": live_ready,
            "wideLiveReady": wide_ready,
            "cameraReady": camera_ready,
            "ready": ready,
        }

    def _normalize_client_role(self, raw: Any, fallback: str) -> str:
        value = str(raw or "").strip().lower().replace(" ", "_")
        if not value:
            return fallback
        safe = "".join(ch for ch in value if ch.isalnum() or ch in ("_", "-", "."))
        return safe or fallback

    def _normalize_client_session(self, raw: Any, fallback_prefix: str) -> str:
        value = str(raw or "").strip()
        if not value:
            return f"{fallback_prefix}-{int(time.time() * 1000)}"
        safe = "".join(ch for ch in value if ch.isalnum() or ch in ("_", "-", ".", ":"))
        return safe or f"{fallback_prefix}-{int(time.time() * 1000)}"

    def _client_role_counts(
        self,
        entries: list[tuple[str, ...]],
    ) -> dict[str, int]:
        counts: dict[str, int] = {}
        for entry in entries:
            if not entry:
                continue
            role = entry[0]
            counts[role] = counts.get(role, 0) + 1
        return counts

    def _client_encoding_counts(
        self,
        encodings: list[str],
    ) -> dict[str, int]:
        counts: dict[str, int] = {}
        for encoding in encodings:
            value = str(encoding or "").strip().lower() or "json"
            counts[value] = counts.get(value, 0) + 1
        return counts

    def _build_debug_plot(self, safe_mode: bool = False) -> dict[str, Any] | None:
        mode = self._read_plot_mode()
        if mode <= 0 or self.sm is None:
            self._debug_plot_cache = None
            return None
        if not self.sm.alive.get("carState", False):
            self._debug_plot_cache = None
            return None
        if not self.sm.alive.get("longitudinalPlan", False):
            self._debug_plot_cache = None
            return None
        now = time.monotonic()
        # Keep plot generation off the hot path while engaged; the chart is non-core.
        # If locationd/selfdrived/modeld timing regresses, this should be one of the
        # first places to sacrifice responsiveness. Do not put model/path/radar core
        # payloads behind the same throttle.
        min_interval = 0.35 if safe_mode else 0.10
        if (
            self._debug_plot_cache is not None
            and (now - self._debug_plot_last_built) < min_interval
        ):
            return dict(self._debug_plot_cache)

        car_state = self.sm["carState"]
        lp = self.sm["longitudinalPlan"]
        car_control = (
            self.sm["carControl"] if self.sm.alive.get("carControl", False) else None
        )
        controls_state = (
            self.sm["controlsState"]
            if self.sm.alive.get("controlsState", False)
            else None
        )
        model = self.sm["modelV2"] if self.sm.alive.get("modelV2", False) else None
        radar_state = (
            self.sm["radarState"] if self.sm.alive.get("radarState", False) else None
        )
        live_params = (
            self.sm["liveParameters"]
            if self.sm.alive.get("liveParameters", False)
            else None
        )

        def fv(raw: Any, default: float = 0.0) -> float:
            value = _safe_float(raw)
            if value is None or not math.isfinite(value):
                return default
            return float(value)

        def seq_value(raw: Any, idx: int, default: float = 0.0) -> float:
            try:
                seq = list(raw)
            except Exception:
                return default
            if idx < 0 or idx >= len(seq):
                return default
            return fv(seq[idx], default)

        actuators = (
            getattr(car_control, "actuators", None) if car_control is not None else None
        )
        lateral_state = (
            getattr(controls_state, "lateralControlState", None)
            if controls_state is not None
            else None
        )
        torque_state = None
        if lateral_state is not None:
            try:
                if lateral_state.which() == "torqueState":
                    torque_state = getattr(lateral_state, "torqueState", None)
            except Exception:
                torque_state = getattr(lateral_state, "torqueState", None)

        position = getattr(model, "position", None) if model is not None else None
        velocity = getattr(model, "velocity", None) if model is not None else None
        lead_one = (
            getattr(radar_state, "leadOne", None) if radar_state is not None else None
        )

        values = [0.0, 0.0, 0.0]
        title = "no data"
        if mode == 1:
            values = [
                fv(getattr(car_state, "aEgo", None)),
                seq_value(getattr(lp, "accels", []), 0),
                fv(getattr(actuators, "accel", None)),
            ]
            title = "1.Accel (Y:a_ego, G:a_target, O:a_out)"
        elif mode == 2:
            values = [
                seq_value(getattr(lp, "speeds", []), 0),
                fv(getattr(car_state, "vEgo", None)),
                fv(getattr(car_state, "aEgo", None)),
            ]
            title = "2.Speed/Accel(Y:speed_0, G:v_ego, O:a_ego)"
        elif mode == 3:
            values = [
                seq_value(getattr(position, "x", []), 32),
                seq_value(getattr(velocity, "x", []), 32),
                seq_value(getattr(velocity, "x", []), 0),
            ]
            title = "3.Model(Y:pos_32, G:vel_32, O:vel_0)"
        elif mode == 4:
            values = [
                seq_value(getattr(lp, "accels", []), 0),
                fv(getattr(lead_one, "aLeadK", None)),
                fv(getattr(lead_one, "vRel", None)),
            ]
            title = "4.Lead(Y:accel, G:a_lead, O:v_rel)"
        elif mode == 5:
            values = [
                fv(getattr(car_state, "aEgo", None)),
                fv(getattr(lead_one, "aLead", None)),
                fv(getattr(lead_one, "jLead", None)),
            ]
            title = "5.Lead(Y:a_ego, G:a_lead, O:j_lead)"
        elif mode == 6:
            values = [
                fv(getattr(torque_state, "actualLateralAccel", None)) * 10.0,
                fv(getattr(torque_state, "desiredLateralAccel", None)) * 10.0,
                fv(getattr(torque_state, "output", None)) * 10.0,
            ]
            title = "6.Steer(Y:actual, G:desire, O:output)"
        elif mode == 7:
            values = [
                fv(getattr(car_state, "steeringAngleDeg", None)),
                fv(getattr(actuators, "steeringAngleDeg", None)),
                fv(getattr(live_params, "angleOffsetDeg", None)) * 10.0,
            ]
            title = "7.SteerA (Y:Actual, G:Target, O:Offset*10)"
        elif mode == 8:
            curvature = fv(getattr(actuators, "curvature", None)) * 10000.0
            values = [curvature, curvature, curvature]
            title = "8.SteerA (Y:Actual, G:Target, O:Offset*10)"

        out = {
            "mode": mode,
            "title": title,
            "values": values,
        }
        self._debug_plot_cache = out
        self._debug_plot_last_built = now
        return dict(out)

    def _read_hud_params(self) -> dict[str, Any]:
        now = time.monotonic()
        if now - self._hud_params_last_read < 1.0:
            return dict(self._hud_params_cache)
        self._hud_params_last_read = now
        if self._params is None:
            return dict(self._hud_params_cache)
        try:
            personality_raw = int(self._params.get_int("LongitudinalPersonality"))
            self._hud_params_cache["personalityRaw"] = personality_raw
            self._hud_params_cache["tfGapDisplay"] = max(0, personality_raw + 1)
            self._hud_params_cache["showDeviceState"] = (
                int(self._params.get_int("ShowDeviceState")) != 0
            )
            self._hud_params_cache["showDateTimeMode"] = int(
                self._params.get_int("ShowDateTime")
            )
            custom_sr = _safe_float(self._params.get_float("CustomSR"))
            self._hud_params_cache["customSr"] = (
                custom_sr / 10.0
                if custom_sr is not None and math.isfinite(custom_sr)
                else None
            )
        except Exception:
            pass
        return dict(self._hud_params_cache)

    def _compute_metric_primary_mode(self) -> str:
        now = time.monotonic()
        if self._hud_metric_toggle_last <= 0.0:
            self._hud_metric_toggle_last = now
        elif now - self._hud_metric_toggle_last >= 3.2:
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

    def _resolve_gps_state_for_hud(self, sm_ref: Any) -> tuple[bool, str | None]:
        if sm_ref is None:
            return (False, None)
        for key, provider in (
            ("gpsLocationExternal", "gpsLocationExternal"),
            ("gpsLocation", "gpsLocation"),
        ):
            try:
                if not sm_ref.alive.get(key, False):
                    continue
                msg = sm_ref[key]
                has_fix = bool(getattr(msg, "hasFix", False))
                return (has_fix, provider)
            except Exception:
                continue
        return (False, None)

    def _refresh_sm_if_needed(self, force: bool = False) -> None:
        sm = self.sm
        if sm is None:
            return
        now = time.monotonic()
        if (
            not force
            and self._last_sm_update_mono > 0.0
            and (now - self._last_sm_update_mono) < self._sm_update_min_interval
        ):
            return
        try:
            sm.update(0)
            updated_at = time.monotonic()
            self._last_sm_update_mono = updated_at
            alive_map = getattr(sm, "alive", {})
            updated_map = getattr(sm, "updated", {})
            for name in alive_map.keys():
                if bool(alive_map.get(name, False)):
                    self._service_last_alive_mono[name] = updated_at
                if bool(updated_map.get(name, False)):
                    self._service_last_updated_mono[name] = updated_at
        except Exception as sm_err:
            self.last_error = f"sm update error: {sm_err}"

    def _build_hud_snapshot(
        self,
        do_update: bool = True,
        sm_ref: Any = None,
    ) -> dict[str, Any]:
        missing_fields: list[str] = []
        stale_reasons: list[str] = []
        payload: dict[str, Any] = {
            "version": 1,
            "tsMonoMs": int(time.monotonic() * 1000.0),
            "source": {"transport": "sidecar_hud"},
            "meta": {
                "quality": "semantic",
                "missingFields": missing_fields,
                "staleReasons": stale_reasons,
            },
        }
        sm = sm_ref if sm_ref is not None else self.sm
        if sm is None:
            payload["meta"] = {
                "quality": "degraded",
                "missingFields": ["remote.unavailable"],
                "staleReasons": ["remote.unavailable"],
            }
            payload["error"] = self.last_error or "messaging unavailable"
            return payload

        if do_update:
            self._refresh_sm_if_needed()
        hud_params = self._read_hud_params()

        cs = sm["carState"] if sm.alive.get("carState", False) else None
        ds = sm["deviceState"] if sm.alive.get("deviceState", False) else None
        ss = sm["selfdriveState"] if sm.alive.get("selfdriveState", False) else None
        ps = sm["peripheralState"] if sm.alive.get("peripheralState", False) else None
        lp = sm["longitudinalPlan"] if sm.alive.get("longitudinalPlan", False) else None
        cm = sm["carrotMan"] if sm.alive.get("carrotMan", False) else None

        if cs is None:
            missing_fields.append("vehicle.carState")
        if ss is None:
            missing_fields.append("vehicle.selfdriveState")
        if cs is None and ss is None:
            missing_fields.append("vehicle.core")
        stale_reasons.extend(self._hud_stale_reasons())
        if missing_fields or stale_reasons:
            payload["meta"]["quality"] = "degraded"

        raw_speed_cluster = None
        speed_cluster_kph = None
        set_speed_cluster_kph = None
        gear_text = "U"
        if cs is not None:
            raw_speed_cluster = _safe_float(getattr(cs, "vEgoCluster", None))
            speed_cluster_kph = (
                raw_speed_cluster * 3.6 if raw_speed_cluster is not None else None
            )
            v_ego = _safe_float(getattr(cs, "vEgo", None))
            v_ego_kph = v_ego * 3.6 if v_ego is not None else None
            if speed_cluster_kph is None or (
                v_ego_kph is not None and v_ego_kph > 0.8 and speed_cluster_kph <= 0.1
            ):
                speed_cluster_kph = v_ego_kph
            set_speed_cluster_kph = _safe_float(getattr(cs, "vCruiseCluster", None))
            gear_text = self._gear_text_for_hud(cs)

        speed_cluster_mps = (
            speed_cluster_kph / 3.6 if speed_cluster_kph is not None else None
        )
        set_speed_cluster_mps = (
            set_speed_cluster_kph / 3.6 if set_speed_cluster_kph is not None else None
        )

        long_active = bool(getattr(ss, "enabled", False)) if ss is not None else False
        lat_active = bool(getattr(ss, "active", False)) if ss is not None else False
        payload["vehicle"] = {
            "speedClusterKph": speed_cluster_kph,
            "setSpeedClusterKph": set_speed_cluster_kph,
            "speedClusterMps": speed_cluster_mps,
            "setSpeedClusterMps": set_speed_cluster_mps,
            "gearText": gear_text,
            "longActive": long_active,
            "latActive": lat_active,
        }

        apply_speed_kph = (
            _safe_float(getattr(cm, "desiredSpeed", None)) if cm is not None else None
        )
        apply_source = (
            str(getattr(cm, "desiredSource", "") or "").strip()
            if cm is not None
            else ""
        )
        cruise_target_kph = (
            _safe_float(getattr(lp, "cruiseTarget", None)) if lp is not None else None
        )
        is_decel = (
            apply_speed_kph is not None
            and set_speed_cluster_kph is not None
            and apply_speed_kph < (set_speed_cluster_kph - 0.5)
        )
        if apply_source and apply_speed_kph is not None:
            payload["tempControl"] = {
                "mode": "apply",
                "label": apply_source,
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

        drive_mode_code = (
            _safe_int(getattr(lp, "myDrivingMode", None)) if lp is not None else None
        )
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

        road_limit_kph = (
            _safe_float(getattr(cm, "nRoadLimitSpeed", None))
            if cm is not None
            else None
        )
        camera_limit_kph = (
            _safe_float(getattr(cm, "xSpdLimit", None)) if cm is not None else None
        )
        camera_sign_type = (
            _safe_int(getattr(cm, "xSpdType", None)) if cm is not None else None
        )
        limit_mode = "hidden"
        limit_label = None
        display_limit_kph = None
        if (
            camera_limit_kph is not None
            and camera_limit_kph > 0.0
            and camera_sign_type == 4
        ):
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

        active_carrot = (
            _safe_int(getattr(cm, "activeCarrot", None)) if cm is not None else None
        )
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

        traffic_state_lp = (
            _safe_int(getattr(lp, "trafficState", None)) if lp is not None else None
        )
        traffic_state_carrot = (
            _safe_int(getattr(cm, "trafficState", None)) if cm is not None else None
        )
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

        gps_has_fix, gps_provider = self._resolve_gps_state_for_hud(sm)
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
                    "rpyCalib": [
                        float(v) for v in list(getattr(lc, "rpyCalib", []))[:3]
                    ],
                    "wideFromDeviceEuler": [
                        float(v)
                        for v in list(getattr(lc, "wideFromDeviceEuler", []))[:3]
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
            "gearStep": _safe_int(getattr(cs, "gearStep", None)),
        }

    def _payload_device_state(self, ds: Any) -> dict[str, Any]:
        cpu_list = getattr(ds, "cpuTempC", None)
        cpu_temp = None
        cpu_avg = None
        if cpu_list is not None:
            try:
                values: list[float] = []
                for v in cpu_list:
                    fv = _safe_float(v)
                    if fv is not None and math.isfinite(fv) and fv > 0.0:
                        values.append(fv)
                if values:
                    cpu_avg = sum(values) / float(len(values))
                    cpu_temp = max(values)
            except TypeError:
                fv = _safe_float(cpu_list)
                if fv is not None and math.isfinite(fv) and fv > 0.0:
                    cpu_avg = fv
                    cpu_temp = fv
            except Exception:
                cpu_avg = None
                cpu_temp = None
        mem_pct = _safe_float(getattr(ds, "memoryUsagePercent", None))
        free_pct = _safe_float(getattr(ds, "freeSpacePercent", None))
        disk_pct = (100.0 - free_pct) if free_pct is not None else None
        return {
            "cpuTempAvgC": cpu_avg,
            "cpuTempC": cpu_temp,
            "memPct": mem_pct,
            "diskPct": disk_pct,
            "freeSpacePct": free_pct,
            "thermalStatus": str(getattr(ds, "thermalStatus", "")),
        }

    def _payload_peripheral_state(self, ps: Any) -> dict[str, Any]:
        voltage_raw = _safe_float(getattr(ps, "voltage", None))
        return {
            "voltage": voltage_raw,
            "voltV": voltage_raw / 1000.0 if voltage_raw is not None else None,
        }

    def _payload_gps_location(self, gps: Any) -> dict[str, Any]:
        return {
            "hasFix": bool(getattr(gps, "hasFix", False)),
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
            "longitudinalPlanSource": _safe_int(
                getattr(lp, "longitudinalPlanSource", None)
            ),
            "tFollow": _safe_float(getattr(lp, "tFollow", None)),
            "desiredDistance": _safe_float(getattr(lp, "desiredDistance", None)),
            "cruiseTarget": _safe_float(getattr(lp, "cruiseTarget", None)),
            "myDrivingMode": _safe_int(getattr(lp, "myDrivingMode", None)),
        }
        try:
            accels = list(getattr(lp, "accels", []))
            out["accel0"] = _safe_float(accels[0]) if len(accels) > 0 else None
        except Exception:
            pass
        return out

    def _payload_stock_debug(self) -> dict[str, Any] | None:
        sm = self.sm
        if sm is None:
            return None

        live_delay = sm["liveDelay"] if sm.alive.get("liveDelay", False) else None
        live_torque = (
            sm["liveTorqueParameters"]
            if sm.alive.get("liveTorqueParameters", False)
            else None
        )
        live_params = (
            sm["liveParameters"] if sm.alive.get("liveParameters", False) else None
        )
        hud_params = self._read_hud_params()

        ld_cal = (
            _safe_int(getattr(live_delay, "calPerc", None))
            if live_delay is not None
            else None
        )
        ld_lateral_delay = (
            _safe_float(getattr(live_delay, "lateralDelay", None))
            if live_delay is not None
            else None
        )
        lt_cal = (
            _safe_int(getattr(live_torque, "calPerc", None))
            if live_torque is not None
            else None
        )
        lt_live_valid = (
            bool(getattr(live_torque, "liveValid", False))
            if live_torque is not None
            else False
        )
        lt_lat_accel_factor = (
            _safe_float(getattr(live_torque, "latAccelFactorFiltered", None))
            if live_torque is not None
            else None
        )
        lt_friction_coefficient = (
            _safe_float(getattr(live_torque, "frictionCoefficientFiltered", None))
            if live_torque is not None
            else None
        )
        sr_steer_ratio = (
            _safe_float(getattr(live_params, "steerRatio", None))
            if live_params is not None
            else None
        )
        sr_custom = _safe_float(hud_params.get("customSr"))

        has_any = any(
            value is not None
            for value in (
                ld_cal,
                ld_lateral_delay,
                lt_cal,
                lt_lat_accel_factor,
                lt_friction_coefficient,
                sr_steer_ratio,
                sr_custom,
            )
        )
        if not has_any:
            return None

        def fmt_pct(value: int | None) -> str:
            return f"{value}%" if value is not None else "--%"

        def fmt_float(value: float | None, digits: int) -> str:
            if value is None or not math.isfinite(value):
                return "--"
            return f"{value:.{digits}f}"

        top_right_text = (
            f"LD[{fmt_pct(ld_cal)},{fmt_float(ld_lateral_delay, 2)}],"
            f"LT[{fmt_pct(lt_cal)},{'ON' if lt_live_valid else 'OFF'}]"
            f"({fmt_float(lt_lat_accel_factor, 2)}/{fmt_float(lt_friction_coefficient, 2)}), "
            f"SR({fmt_float(sr_steer_ratio, 1)},{fmt_float(sr_custom, 1)})"
        )
        return {
            "ldCalPerc": ld_cal,
            "ldLateralDelay": ld_lateral_delay,
            "ltCalPerc": lt_cal,
            "ltLiveValid": lt_live_valid,
            "ltLatAccelFactorFiltered": lt_lat_accel_factor,
            "ltFrictionCoefficientFiltered": lt_friction_coefficient,
            "srSteerRatio": sr_steer_ratio,
            "srCustom": sr_custom,
            "topRightText": top_right_text,
        }

    def _payload_lateral_plan(self, lp: Any) -> dict[str, Any]:
        out: dict[str, Any] = {}
        try:
            out["laneChangeState"] = _safe_int(getattr(lp, "laneChangeState", None))
            out["laneChangeDirection"] = _safe_int(
                getattr(lp, "laneChangeDirection", None)
            )
            out["latDebugText"] = str(getattr(lp, "latDebugText", "") or "")
        except Exception:
            pass
        try:
            pos = getattr(lp, "position", None)
            if pos is not None:
                out["position"] = {
                    "x": _downsample(
                        [float(v) for v in list(getattr(pos, "x", []))],
                        _MODEL_GEOMETRY_POINTS,
                        _MODEL_GEOMETRY_PRECISION,
                    ),
                    "y": _downsample(
                        [float(v) for v in list(getattr(pos, "y", []))],
                        _MODEL_GEOMETRY_POINTS,
                        _MODEL_GEOMETRY_PRECISION,
                    ),
                    "z": _downsample(
                        [float(v) for v in list(getattr(pos, "z", []))],
                        _MODEL_GEOMETRY_POINTS,
                        _MODEL_GEOMETRY_PRECISION,
                    ),
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
            out["exposureValPercent"] = _safe_float(
                getattr(rcs, "exposureValPercent", None)
            )
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
            "desiredSpeed": _safe_float(getattr(cm, "desiredSpeed", None)),
            "desiredSource": str(getattr(cm, "desiredSource", "") or ""),
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
            "maneuverSecondaryText": str(
                getattr(ni, "maneuverSecondaryText", "") or ""
            ),
            "maneuverType": str(getattr(ni, "maneuverType", "") or ""),
            "maneuverModifier": str(getattr(ni, "maneuverModifier", "") or ""),
            "maneuverDistance": _safe_float(getattr(ni, "maneuverDistance", None)),
            "distanceRemaining": _safe_float(getattr(ni, "distanceRemaining", None)),
            "timeRemaining": _safe_float(getattr(ni, "timeRemaining", None)),
            "timeRemainingTypical": _safe_float(
                getattr(ni, "timeRemainingTypical", None)
            ),
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
                out["pathX"] = _downsample(
                    [float(v) for v in list(getattr(pos, "x", []))],
                    _MODEL_GEOMETRY_POINTS,
                    _MODEL_GEOMETRY_PRECISION,
                )
                out["pathY"] = _downsample(
                    [float(v) for v in list(getattr(pos, "y", []))],
                    _MODEL_GEOMETRY_POINTS,
                    _MODEL_GEOMETRY_PRECISION,
                )
                out["pathZ"] = _downsample(
                    [float(v) for v in list(getattr(pos, "z", []))],
                    _MODEL_GEOMETRY_POINTS,
                    _MODEL_GEOMETRY_PRECISION,
                )
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
            lane_probs = [round(float(v), 2) for v in list(getattr(mv2, "laneLineProbs", []))]
            out["laneLineProbs"] = lane_probs[:4]
        except Exception:
            pass

        try:
            lane_stds = [round(float(v), 1) for v in list(getattr(mv2, "laneLineStds", []))]
            out["laneLineStds"] = lane_stds[:4]
        except Exception:
            pass

        try:
            lane_lines = list(getattr(mv2, "laneLines", []))
            packed = []
            for ln in lane_lines[:4]:
                packed.append(
                    {
                        "x": _downsample(
                            [float(v) for v in list(getattr(ln, "x", []))],
                            _MODEL_GEOMETRY_POINTS,
                            _MODEL_GEOMETRY_PRECISION,
                        ),
                        "y": _downsample(
                            [float(v) for v in list(getattr(ln, "y", []))],
                            _MODEL_GEOMETRY_POINTS,
                            _MODEL_GEOMETRY_PRECISION,
                        ),
                        "z": _downsample(
                            [float(v) for v in list(getattr(ln, "z", []))],
                            _MODEL_GEOMETRY_POINTS,
                            _MODEL_GEOMETRY_PRECISION,
                        ),
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
                        "x": _downsample(
                            [float(v) for v in list(getattr(edge, "x", []))],
                            _MODEL_GEOMETRY_POINTS,
                            _MODEL_GEOMETRY_PRECISION,
                        ),
                        "y": _downsample(
                            [float(v) for v in list(getattr(edge, "y", []))],
                            _MODEL_GEOMETRY_POINTS,
                            _MODEL_GEOMETRY_PRECISION,
                        ),
                        "z": _downsample(
                            [float(v) for v in list(getattr(edge, "z", []))],
                            _MODEL_GEOMETRY_POINTS,
                            _MODEL_GEOMETRY_PRECISION,
                        ),
                    }
                )
            out["roadEdges"] = packed_edges
        except Exception:
            pass

        try:
            edge_stds = [round(float(v), 1) for v in list(getattr(mv2, "roadEdgeStds", []))]
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
        try:
            lead_left = getattr(rs, "leadLeft", None)
            if lead_left is not None:
                out["leadLeft"] = self._payload_radar_lead(lead_left)
        except Exception:
            pass
        try:
            lead_right = getattr(rs, "leadRight", None)
            if lead_right is not None:
                out["leadRight"] = self._payload_radar_lead(lead_right)
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

    def _optional_payload_min_interval(
        self,
        safe_mode: bool,
        payload_mode: str,
    ) -> float:
        if payload_mode == "camera_only":
            return 1.0
        if payload_mode == "minimal":
            return 0.60 if safe_mode else 0.30
        return 0.35 if safe_mode else 0.15

    def _write_diag_snapshot(
        self,
        payload: dict[str, Any],
    ) -> None:
        path = self._diag_snapshot_path
        directory = os.path.dirname(path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        tmp_path = f"{path}.tmp"
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))
        os.replace(tmp_path, path)

    def _read_diag_snapshot(
        self,
        safe_mode: bool = False,
        payload_mode: str = "full",
    ) -> dict[str, Any]:
        path = self._diag_snapshot_path
        if not path or not os.path.isfile(path):
            return {}
        try:
            with open(path, "r", encoding="utf-8") as f:
                raw = json.load(f)
        except Exception:
            return {}
        if not isinstance(raw, dict):
            return {}
        optional = raw.get("optional")
        if not isinstance(optional, dict):
            return {}
        snapshot_mode = str(raw.get("payloadMode", "") or "").strip()
        snapshot_profile = str(raw.get("profile", "") or "").strip()
        snapshot_safe = bool(raw.get("safeMode", False))
        if snapshot_profile and snapshot_profile != self.profile:
            return {}
        if snapshot_mode and snapshot_mode != payload_mode and payload_mode != "full":
            return {}
        if snapshot_safe != safe_mode and payload_mode != "full":
            return {}
        return optional

    def _refresh_live_optional_cache(
        self,
        safe_mode: bool = False,
        payload_mode: str = "full",
        do_update: bool = True,
    ) -> dict[str, Any]:
        now = time.monotonic()
        started = time.monotonic()
        optional: dict[str, Any] = {}
        sm = self.sm
        if payload_mode == "full" and sm is not None:
            if do_update:
                self._refresh_sm_if_needed()
            try:
                if sm.alive.get("deviceState", False):
                    optional["deviceState"] = self._payload_device_state(
                        sm["deviceState"]
                    )
            except Exception:
                pass
            try:
                if sm.alive.get("peripheralState", False):
                    optional["peripheralState"] = self._payload_peripheral_state(
                        sm["peripheralState"]
                    )
            except Exception:
                pass
            try:
                if sm.alive.get("gpsLocationExternal", False):
                    optional["gpsLocationExternal"] = self._payload_gps_location(
                        sm["gpsLocationExternal"]
                    )
                elif sm.alive.get("gpsLocation", False):
                    optional["gpsLocation"] = self._payload_gps_location(
                        sm["gpsLocation"]
                    )
            except Exception:
                pass
            try:
                if sm.alive.get("lateralPlan", False):
                    optional["lateralPlan"] = self._payload_lateral_plan(
                        sm["lateralPlan"]
                    )
            except Exception:
                pass
            if self.profile in ("p2", "p3", "p4"):
                try:
                    if sm.alive.get("carrotMan", False):
                        optional["carrotMan"] = self._payload_carrot_man(
                            sm["carrotMan"]
                        )
                except Exception:
                    pass
                try:
                    if sm.alive.get("navInstructionCarrot", False):
                        optional["navInstructionCarrot"] = (
                            self._payload_nav_instruction_carrot(
                                sm["navInstructionCarrot"]
                            )
                        )
                except Exception:
                    pass
        cached_calib = self._read_cached_calibration()
        if cached_calib is not None:
            optional["cachedCalibration"] = cached_calib
        optional["pathStyle"] = self._read_path_style()
        debug_plot = self._build_debug_plot(safe_mode=safe_mode)
        if payload_mode == "full" and debug_plot is not None:
            optional["debugPlot"] = debug_plot

        self._live_optional_cache = optional
        self._live_optional_last_built = now
        self._last_optional_build_ms = max(
            0.0,
            (time.monotonic() - started) * 1000.0,
        )
        return dict(optional)

    def _build_live_optional_payload(
        self,
        safe_mode: bool = False,
        payload_mode: str = "full",
        do_update: bool = True,
    ) -> dict[str, Any]:
        now = time.monotonic()
        min_interval = self._optional_payload_min_interval(safe_mode, payload_mode)
        if (
            self._live_optional_cache is not None
            and (now - self._live_optional_last_built) < (min_interval * 2.0)
        ):
            return dict(self._live_optional_cache)
        return self._refresh_live_optional_cache(
            safe_mode=safe_mode,
            payload_mode=payload_mode,
            do_update=do_update,
        )

    def _build_live_payload(
        self,
        do_update: bool = True,
        safe_mode: bool = False,
        payload_mode: str = "full",
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "ts": time.time(),
            "profile": self.profile,
            "repo": self.repo,
            "repoFlavor": self.repo_flavor,
            "source": "live",
        }
        if self.sm is None:
            payload["error"] = self.last_error or "messaging unavailable"
            return payload

        if do_update:
            self._refresh_sm_if_needed()
        try:
            if self.sm.alive.get("carState", False):
                payload["carState"] = self._payload_car_state(self.sm["carState"])
        except Exception:
            pass
        try:
            if self.sm.alive.get("selfdriveState", False):
                payload["selfdriveState"] = self._payload_selfdrive_state(
                    self.sm["selfdriveState"]
                )
        except Exception:
            pass
        try:
            if payload_mode != "camera_only" and self.sm.alive.get(
                "controlsState", False
            ):
                payload["controlsState"] = self._payload_controls_state(
                    self.sm["controlsState"]
                )
        except Exception:
            pass
        try:
            if payload_mode != "camera_only" and self.sm.alive.get(
                "longitudinalPlan", False
            ):
                payload["longitudinalPlan"] = self._payload_longitudinal_plan(
                    self.sm["longitudinalPlan"]
                )
        except Exception:
            pass
        try:
            if payload_mode != "camera_only" and self.profile in ("p2", "p3", "p4"):
                stock_debug = self._payload_stock_debug()
                if stock_debug is not None:
                    payload["stockDebug"] = stock_debug
        except Exception:
            pass
        try:
            if self.sm.alive.get("liveCalibration", False):
                # liveCalibration changes very slowly (~1Hz).
                # Cache and refresh every 20 ticks (~1s at 20Hz).
                calib_tick = getattr(self, "_calib_cache_tick", 0)
                if calib_tick <= 0 or not hasattr(self, "_calib_cache"):
                    self._calib_cache = self._payload_live_calibration(
                        self.sm["liveCalibration"]
                    )
                    self._calib_cache_tick = 20
                else:
                    self._calib_cache_tick = calib_tick - 1
                payload["liveCalibration"] = self._calib_cache
        except Exception:
            pass
        try:
            if self.sm.alive.get("roadCameraState", False):
                payload["roadCameraState"] = self._payload_road_camera_state(
                    self.sm["roadCameraState"]
                )
        except Exception:
            pass
        try:
            if self.sm.alive.get("wideRoadCameraState", False):
                payload["wideRoadCameraState"] = self._payload_wide_road_camera_state(
                    self.sm["wideRoadCameraState"]
                )
        except Exception:
            pass
        if payload_mode != "camera_only" and self.profile in ("p2", "p3", "p4"):
            try:
                if self.sm.alive.get("modelV2", False):
                    payload["modelV2"] = self._payload_model_v2(self.sm["modelV2"])
            except Exception:
                pass
        if payload_mode != "camera_only" and self.profile in ("p2", "p3", "p4"):
            try:
                if self.sm.alive.get("radarState", False):
                    payload["radarState"] = self._payload_radar_state(
                        self.sm["radarState"]
                    )
            except Exception:
                pass
        payload.update(
            self._build_live_optional_payload(
                safe_mode=safe_mode,
                payload_mode=payload_mode,
                do_update=do_update,
            )
        )
        return payload

    def _refresh_live_broadcast_cache(self) -> None:
        build_started = time.monotonic()
        live_payload = self._build_live_payload(
            do_update=False,
            safe_mode=self._variant_soft_mode_active(),
        )
        live_json = json.dumps(
            live_payload, separators=(",", ":"), ensure_ascii=False
        )
        has_zlib_client = any(
            encoding == "zlib-json"
            for encoding, _camera_mode, _role, _session in self.clients.values()
        )
        has_msgpack_client = any(
            encoding == "msgpack"
            for encoding, _camera_mode, _role, _session in self.clients.values()
        )
        self._cached_live_payload = live_payload
        self._cached_live_json = live_json
        self._cached_live_zlib_json = (
            zlib.compress(live_json.encode("utf-8"), level=1)
            if has_zlib_client
            else None
        )
        self._cached_live_msgpack = (
            _msgpack.packb(live_payload, use_bin_type=True)
            if has_msgpack_client and _msgpack is not None
            else None
        )
        self._cached_live_last_built = time.monotonic()
        self._last_live_build_ms = max(
            0.0,
            (self._cached_live_last_built - build_started) * 1000.0,
        )

    def _refresh_hud_broadcast_cache(self) -> None:
        build_started = time.monotonic()
        hud_payload = self._build_hud_snapshot(do_update=False)
        self._cached_hud_payload = hud_payload
        self._cached_hud_json = json.dumps(
            hud_payload, separators=(",", ":"), ensure_ascii=False
        )
        has_msgpack_client = any(
            encoding == "msgpack"
            for _role, _session, encoding in self.hud_clients.values()
        )
        self._cached_hud_msgpack = (
            _msgpack.packb(hud_payload, use_bin_type=True)
            if has_msgpack_client and _msgpack is not None
            else None
        )
        self._cached_hud_last_built = time.monotonic()
        self._last_hud_build_ms = max(
            0.0,
            (self._cached_hud_last_built - build_started) * 1000.0,
        )

    async def _sm_update_loop(self, app: web.Application) -> None:
        while True:
            try:
                if self.sm is not None:
                    self._refresh_sm_if_needed(force=True)
                await asyncio.sleep(self._sm_update_loop_interval())
            except asyncio.CancelledError:
                break
            except Exception as e:
                self.last_error = f"sm updater error: {e}"
                await asyncio.sleep(0.25)

    async def _payload_cache_loop(self, app: web.Application) -> None:
        while True:
            try:
                if self.sm is not None:
                    now = time.monotonic()
                    if self.clients and (
                        self._cached_live_json is None
                        or (now - self._cached_live_last_built)
                        >= self._live_cache_interval()
                    ):
                        self._refresh_live_broadcast_cache()
                    if self.hud_clients and (
                        self._cached_hud_json is None
                        or (now - self._cached_hud_last_built) >= self._hud_interval()
                    ):
                        self._refresh_hud_broadcast_cache()
                await asyncio.sleep(self._payload_cache_loop_interval())
            except asyncio.CancelledError:
                break
            except Exception as e:
                self.last_error = f"payload cache error: {e}"
                await asyncio.sleep(0.25)

    async def _live_broadcast_loop(self, app: web.Application) -> None:
        live_send_timeout = 1.0
        live_fail_limit = 3
        while True:
            try:
                base_interval = self._live_broadcast_interval()
                if self.clients:
                    if self._cached_live_json is None:
                        self._refresh_live_broadcast_cache()
                    message = self._cached_live_json
                    if message is None:
                        await asyncio.sleep(base_interval)
                        continue
                    send_jobs: list[
                        tuple[web.WebSocketResponse, asyncio.Task[Any]]
                    ] = []
                    batch_started = time.monotonic()
                    for ws, entry in list(self.clients.items()):
                        encoding, _camera_mode, _role, _session = entry
                        try:
                            if encoding == "zlib-json":
                                compressed = self._cached_live_zlib_json
                                if compressed is None:
                                    compressed = zlib.compress(
                                        message.encode("utf-8"),
                                        level=1,
                                    )
                                send_jobs.append(
                                    (
                                        ws,
                                        asyncio.create_task(
                                            asyncio.wait_for(
                                                ws.send_bytes(compressed),
                                                timeout=live_send_timeout,
                                            )
                                        ),
                                    )
                                )
                            elif encoding == "msgpack" and _msgpack is not None:
                                packed = self._cached_live_msgpack
                                if packed is None:
                                    packed = _msgpack.packb(
                                        self._cached_live_payload or {},
                                        use_bin_type=True,
                                    )
                                send_jobs.append(
                                    (
                                        ws,
                                        asyncio.create_task(
                                            asyncio.wait_for(
                                                ws.send_bytes(packed),
                                                timeout=live_send_timeout,
                                            )
                                        ),
                                    )
                                )
                            else:
                                send_jobs.append(
                                    (
                                        ws,
                                        asyncio.create_task(
                                            asyncio.wait_for(
                                                ws.send_str(message),
                                                timeout=live_send_timeout,
                                            )
                                        ),
                                    )
                                )
                        except Exception:
                            pass  # skip this tick, retry next
                    if send_jobs:
                        results = await asyncio.gather(
                            *[task for _, task in send_jobs],
                            return_exceptions=True,
                        )
                        stale: list[web.WebSocketResponse] = []
                        self._last_live_send_batch_ms = max(
                            0.0,
                            (time.monotonic() - batch_started) * 1000.0,
                        )
                        for (ws, _), result in zip(send_jobs, results):
                            if isinstance(result, Exception):
                                self._live_send_drop_count += 1
                                fail_count = self._live_send_failures.get(ws, 0) + 1
                                self._live_send_failures[ws] = fail_count
                                if fail_count >= live_fail_limit:
                                    stale.append(ws)
                            else:
                                self._live_send_failures.pop(ws, None)
                        for ws in stale:
                            self.clients.pop(ws, None)
                            self._live_send_failures.pop(ws, None)
                            try:
                                await ws.close(code=1011, message=b"live_send_timeout")
                            except Exception:
                                pass
                await asyncio.sleep(base_interval)
            except asyncio.CancelledError:
                break
            except Exception as e:
                self.last_error = f"live broadcast error: {e}"
                await asyncio.sleep(0.25)

    async def _hud_broadcast_loop(self, app: web.Application) -> None:
        hud_send_timeout = 0.3
        hud_fail_limit = 3
        while True:
            try:
                base_interval = self._hud_interval()
                if self.hud_clients:
                    if self._cached_hud_json is None:
                        self._refresh_hud_broadcast_cache()
                    hud_message_json = self._cached_hud_json
                    if hud_message_json is None:
                        await asyncio.sleep(base_interval)
                        continue
                    hud_send_jobs: list[
                        tuple[web.WebSocketResponse, asyncio.Task[Any]]
                    ] = []
                    hud_batch_started = time.monotonic()
                    for ws in list(self.hud_clients.keys()):
                        try:
                            _role, _session, encoding = self.hud_clients.get(
                                ws, ("app_hud", "hud", "json")
                            )
                            if encoding == "msgpack" and _msgpack is not None:
                                packed = self._cached_hud_msgpack
                                if packed is None:
                                    packed = _msgpack.packb(
                                        self._cached_hud_payload or {},
                                        use_bin_type=True,
                                    )
                                send_coro = ws.send_bytes(packed)
                            else:
                                send_coro = ws.send_str(hud_message_json)
                            hud_send_jobs.append(
                                (
                                    ws,
                                    asyncio.create_task(
                                        asyncio.wait_for(
                                            send_coro,
                                            timeout=hud_send_timeout,
                                        )
                                    ),
                                )
                            )
                        except Exception:
                            pass  # skip this tick, retry next
                    if hud_send_jobs:
                        hud_results = await asyncio.gather(
                            *[task for _, task in hud_send_jobs],
                            return_exceptions=True,
                        )
                        stale: list[web.WebSocketResponse] = []
                        self._last_hud_send_batch_ms = max(
                            0.0,
                            (time.monotonic() - hud_batch_started) * 1000.0,
                        )
                        for (ws, _), result in zip(hud_send_jobs, hud_results):
                            if isinstance(result, Exception):
                                self._hud_send_drop_count += 1
                                fail_count = self._hud_send_failures.get(ws, 0) + 1
                                self._hud_send_failures[ws] = fail_count
                                if fail_count >= hud_fail_limit:
                                    stale.append(ws)
                            else:
                                self._hud_send_failures.pop(ws, None)
                        for ws in stale:
                            self.hud_clients.pop(ws, None)
                            self._hud_send_failures.pop(ws, None)
                            try:
                                await ws.close(code=1011, message=b"hud_send_timeout")
                            except Exception:
                                pass
                await asyncio.sleep(base_interval)
            except asyncio.CancelledError:
                break
            except Exception as e:
                self.last_error = f"hud broadcast error: {e}"
                await asyncio.sleep(0.25)

    async def ws_live(self, request: web.Request) -> web.WebSocketResponse:
        encoding = request.query.get("encoding", "json").strip().lower()
        _valid_encodings = {"json", "zlib-json", "msgpack"}
        if encoding not in _valid_encodings:
            encoding = "json"
        if encoding == "msgpack" and _msgpack is None:
            encoding = "json"
        camera_mode = str(request.query.get("camera", "both")).strip()
        if camera_mode not in ("road", "wideRoad"):
            camera_mode = "both"
        role = self._normalize_client_role(
            request.query.get("role"),
            "drive_overlay",
        )
        session_id = self._normalize_client_session(
            request.query.get("session"),
            "drive",
        )
        ws = web.WebSocketResponse(heartbeat=20)
        await ws.prepare(request)
        self.clients[ws] = (encoding, camera_mode, role, session_id)
        try:
            await ws.send_str(
                json.dumps(
                    {
                        "type": "hello",
                        "profile": self.profile,
                        "variant": self.variant,
                        "repoFlavor": self.repo_flavor,
                        "source": "live",
                        "encoding": encoding,
                        "cameraMode": camera_mode,
                        "role": role,
                        "session": session_id,
                    }
                )
            )
            async for _ in ws:
                pass
        finally:
            self.clients.pop(ws, None)
            self._live_send_failures.pop(ws, None)
            try:
                await ws.close()
            except Exception:
                pass
        return ws

    async def ws_hud(self, request: web.Request) -> web.WebSocketResponse:
        encoding = request.query.get("encoding", "json").strip().lower()
        if encoding not in {"json", "msgpack"}:
            encoding = "json"
        if encoding == "msgpack" and _msgpack is None:
            encoding = "json"
        role = self._normalize_client_role(
            request.query.get("role"),
            "app_hud",
        )
        session_id = self._normalize_client_session(
            request.query.get("session"),
            "hud",
        )
        ws = web.WebSocketResponse(heartbeat=20)
        await ws.prepare(request)
        self.hud_clients[ws] = (role, session_id, encoding)
        try:
            if self._cached_hud_json is None:
                self._refresh_hud_broadcast_cache()
            await ws.send_str(
                json.dumps(
                    {
                        "type": "hello",
                        "profile": self.profile,
                        "variant": self.variant,
                        "repoFlavor": self.repo_flavor,
                        "source": "hud",
                        "encoding": encoding,
                        "role": role,
                        "session": session_id,
                    }
                )
            )
            initial_json = self._cached_hud_json
            initial_payload = self._cached_hud_payload
            if initial_json is None or initial_payload is None:
                initial_payload = self._build_hud_snapshot()
                initial_json = json.dumps(
                    initial_payload,
                    separators=(",", ":"),
                    ensure_ascii=False,
                )
            if encoding == "msgpack" and _msgpack is not None:
                initial_msgpack = self._cached_hud_msgpack
                if initial_msgpack is None:
                    initial_msgpack = _msgpack.packb(
                        initial_payload,
                        use_bin_type=True,
                    )
                await ws.send_bytes(initial_msgpack)
            else:
                await ws.send_str(initial_json)
            async for _ in ws:
                pass
        finally:
            self.hud_clients.pop(ws, None)
            self._hud_send_failures.pop(ws, None)
            try:
                await ws.close()
            except Exception:
                pass
        return ws

    async def ws_camera(self, request: web.Request) -> web.WebSocketResponse:
        if self._camera_hub is None:
            raise web.HTTPServiceUnavailable(text="camera hub unavailable")
        return await self._camera_hub.ws_camera(request)

    async def get_camera_quality(self, request: web.Request) -> web.Response:
        mode = "stable"
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

    async def get_health(self, request: web.Request) -> web.Response:
        camera_status = (
            self._camera_hub.status()
            if self._camera_hub is not None
            else {"mode": "disabled"}
        )
        camera_status = {
            **camera_status,
            "transport": "internal",
            "port": int(os.environ.get("CARROTLINK_SIDECAR_PORT", "7766")),
        }
        health_flags = self._runtime_health_flags(camera_status)
        now = time.monotonic()
        radar_ready = self._service_ready("radarState", require_updated=True)
        radar_stable = self._radar_stable_for_variant(now=now)
        startup_protection_active = self._variant_soft_mode_active(now=now)
        return web.json_response(
            {
                "kind": "carrotlink_sidecar_broker_v1",
                "ok": health_flags["processReady"],
                "ready": health_flags["ready"],
                "transportReady": health_flags["transportReady"],
                "hudReady": health_flags["hudReady"],
                "semanticHudReady": health_flags["semanticHudReady"],
                "assistReady": health_flags["assistReady"],
                "signalReady": health_flags["signalReady"],
                "carrotReady": health_flags["carrotReady"],
                "planReady": health_flags["planReady"],
                "navReady": health_flags["navReady"],
                "liveReady": health_flags["liveReady"],
                "wideLiveReady": health_flags["wideLiveReady"],
                "cameraReady": health_flags["cameraReady"],
                "profile": self.profile,
                "variant": self.variant,
                "repoFlavor": self.repo_flavor,
                "startupProtectionActive": startup_protection_active,
                "radarReady": radar_ready,
                "radarFreshStable": radar_stable,
                "profileGeneration": self._profile_generation,
                "clients": len(self.clients),
                "repo": self.repo,
                "error": self.last_error,
                "liveRelay": {
                    "clients": len(self.clients),
                    "clientRoles": self._client_role_counts(
                        [
                            (role, session)
                            for _, _, role, session in self.clients.values()
                        ]
                    ),
                    "encodings": self._client_encoding_counts(
                        [encoding for encoding, _camera_mode, _role, _session in self.clients.values()]
                    ),
                    "msgpackAvailable": _msgpack is not None,
                    "msgpackActive": any(
                        encoding == "msgpack"
                        for encoding, _camera_mode, _role, _session in self.clients.values()
                    ),
                    "clientSessions": sorted(
                        {session for _, _, _role, session in self.clients.values()}
                    ),
                    "sendDrops": self._live_send_drop_count,
                    "lastBuildMs": round(self._last_live_build_ms, 1),
                    "lastSendBatchMs": round(self._last_live_send_batch_ms, 1),
                    "cacheAgeMs": int(
                        max(
                            0.0,
                            (time.monotonic() - self._cached_live_last_built) * 1000.0,
                        )
                    )
                    if self._cached_live_last_built > 0.0
                    else None,
                    "optionalLastBuildMs": round(self._last_optional_build_ms, 1),
                    "optionalCacheAgeMs": int(
                        max(
                            0.0,
                            (time.monotonic() - self._live_optional_last_built)
                            * 1000.0,
                        )
                    )
                    if self._live_optional_last_built > 0.0
                    else None,
                },
                "hudRelay": {
                    "clients": len(self.hud_clients),
                    "clientRoles": self._client_role_counts(
                        list(self.hud_clients.values())
                    ),
                    "encodings": self._client_encoding_counts(
                        [encoding for _role, _session, encoding in self.hud_clients.values()]
                    ),
                    "msgpackAvailable": _msgpack is not None,
                    "msgpackActive": any(
                        encoding == "msgpack"
                        for _role, _session, encoding in self.hud_clients.values()
                    ),
                    "clientSessions": sorted(
                        {
                            session
                            for _role, session, _encoding
                            in self.hud_clients.values()
                        }
                    ),
                    "sendDrops": self._hud_send_drop_count,
                    "lastBuildMs": round(self._last_hud_build_ms, 1),
                    "lastSendBatchMs": round(self._last_hud_send_batch_ms, 1),
                    "cacheAgeMs": int(
                        max(
                            0.0,
                            (time.monotonic() - self._cached_hud_last_built) * 1000.0,
                        )
                    )
                    if self._cached_hud_last_built > 0.0
                    else None,
                },
                "cameraRelay": camera_status,
                "smUpdater": {
                    "intervalMs": int(self._sm_update_loop_interval() * 1000.0),
                    "lastUpdateAgeMs": int(
                        max(
                            0.0,
                            (time.monotonic() - self._last_sm_update_mono) * 1000.0,
                        )
                    )
                    if self._last_sm_update_mono > 0.0
                    else None,
                },
                "payloadCache": {
                    "intervalMs": int(self._payload_cache_loop_interval() * 1000.0),
                    "liveIntervalMs": int(self._live_cache_interval() * 1000.0),
                    "hudIntervalMs": int(self._hud_interval() * 1000.0),
                    "liveAgeMs": int(
                        max(
                            0.0,
                            (time.monotonic() - self._cached_live_last_built) * 1000.0,
                        )
                    )
                    if self._cached_live_last_built > 0.0
                    else None,
                    "hudAgeMs": int(
                        max(
                            0.0,
                            (time.monotonic() - self._cached_hud_last_built) * 1000.0,
                        )
                    )
                    if self._cached_hud_last_built > 0.0
                    else None,
                },
                "debug": {
                    "debugPlotMode": self._plot_mode_cache,
                    "debugPlotCached": self._debug_plot_cache is not None,
                },
                "serviceHealth": {
                    name: self._service_health(name) for name in (
                        "selfdriveState", "carState", "liveCalibration",
                        "modelV2", "radarState", "roadCameraState",
                        "wideRoadCameraState", "gpsLocationExternal",
                        "longitudinalPlan", "carrotMan",
                        "navInstructionCarrot",
                    )
                },
            }
        )

    async def get_profile(self, request: web.Request) -> web.Response:
        return web.json_response(
            {
                "profile": self.profile,
                "variant": self.variant,
                "repoFlavor": self.repo_flavor,
                "profiles": list(self.PROFILE_SERVICES.keys()),
                "variants": sorted(self.SUPPORTED_VARIANTS),
            }
        )

    async def set_profile(self, request: web.Request) -> web.Response:
        try:
            body = await request.json()
        except Exception:
            return web.json_response({"ok": False, "error": "invalid json"}, status=400)
        profile = str(body.get("profile", "")).strip().lower()
        if profile not in self.PROFILE_SERVICES:
            return web.json_response(
                {"ok": False, "error": "invalid profile"}, status=400
            )
        if profile != self.profile:
            previous = self.profile
            self._reset_profile_runtime_state(
                reason=f"profile_switch:{previous}->{profile}"
            )
            if self._camera_hub is not None:
                await self._camera_hub.reset_runtime_state(
                    reason=f"profile_switch:{previous}->{profile}"
                )
            self.profile = profile
            self._init_messaging()
        return web.json_response(
            {
                "ok": True,
                "profile": self.profile,
                "variant": self.variant,
                "repoFlavor": self.repo_flavor,
                "profileGeneration": self._profile_generation,
            }
        )

    async def on_startup(self, app: web.Application) -> None:
        app["sm_update_task"] = asyncio.create_task(
            self._sm_update_loop(app)
        )
        app["payload_cache_task"] = asyncio.create_task(
            self._payload_cache_loop(app)
        )
        app["live_broadcast_task"] = asyncio.create_task(
            self._live_broadcast_loop(app)
        )
        app["hud_broadcast_task"] = asyncio.create_task(
            self._hud_broadcast_loop(app)
        )

    async def on_cleanup(self, app: web.Application) -> None:
        for task_name in (
            "sm_update_task",
            "payload_cache_task",
            "live_broadcast_task",
            "hud_broadcast_task",
        ):
            task = app.get(task_name)
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
    variant = os.environ.get("CARROTLINK_SIDECAR_VARIANT", "default").strip().lower()
    port = int(os.environ.get("CARROTLINK_SIDECAR_PORT", "7766"))
    host = os.environ.get("CARROTLINK_SIDECAR_HOST", "0.0.0.0").strip() or "0.0.0.0"

    app_state = SidecarApp(profile, variant=variant)
    app = web.Application()
    app.router.add_get("/health", app_state.get_health)
    app.router.add_get("/profile", app_state.get_profile)
    app.router.add_post("/profile", app_state.set_profile)
    app.router.add_get("/camera_quality", app_state.get_camera_quality)
    app.router.add_post("/camera_quality", app_state.set_camera_quality)
    app.router.add_get("/ws/camera/{camera}", app_state.ws_camera)
    app.router.add_get("/ws/hud", app_state.ws_hud)
    app.router.add_get("/ws/live", app_state.ws_live)
    app.on_startup.append(app_state.on_startup)
    app.on_cleanup.append(app_state.on_cleanup)

    print(
        f"[sidecar] starting host={host} port={port} "
        f"profile={app_state.profile} variant={app_state.variant} "
        f"repoFlavor={app_state.repo_flavor}"
    )
    web.run_app(app, host=host, port=port)


if __name__ == "__main__":
    main()


