# 사이드카 근본적 리팩토링 설계 (대안B: Slim Proxy)

## 제약 조건

| # | 제약 | 설명 |
|---|------|------|
| 1 | **v10 브랜치 수정 불가** | `c3-v10-wip` 코드 절대 수정 안 함 |
| 2 | **콤마측 연산 최소화** | 성능 마진이 적음. CPU 최소 사용 |
| 3 | **앱측 렌더링** | 콤마에서 원시 데이터만 받아 앱에서 계산/그리기 |
| 4 | **빠른 속도 유지** | HUD/Stock 데이터 수신 속도 30~40ms 유지 |
| 5 | **WebRTC 폐기** | WebRTC 관련 코드 전부 제거 |

---

## v10 코드 정밀 검증 결과

### carrot_man.py — 5개 통신 채널 확인

| 포트/프로토콜 | 방향 | 용도 | sidecar와 관계 |
|-------------|------|------|---------------|
| UDP:7705 브로드캐스트 | 콤마→앱 | 디바이스 발견/상태 전송 | sidecar 불필요 |
| UDP:7706 수신 | 앱→콤마 | 네비 SDI/TBT/GPS 데이터 수신 | sidecar 불필요 |
| ZMQ:7710 REP | 앱→콤마 | 원격 명령(echo_cmd, tmux_send) | sidecar 불필요 |
| TCP:7709 수신 | 앱→콤마 | 경로 좌표 수신 | sidecar 불필요 |
| UDP:12345 수신 | KISA앱→콤마 | Waze 속도제한/도로명 | sidecar 불필요 |

> [!IMPORTANT]
> carrot_man.py의 5개 통신 채널은 **sidecar 없이도 이미 동작 중**이다.
> sidecar가 실제로 하는 역할은 "cereal IPC → JSON WebSocket 변환"뿐이다.

### CarrotMan cereal 메시지 스키마 (custom.capnp)

`carrot_man.py`가 20Hz로 발행하는 `carrotMan` 메시지에 이미 포함된 데이터:

```capnp
struct CarrotMan {
  activeCarrot    : Int32    # CarrotMan 활성 상태 (0~6)
  nRoadLimitSpeed : Int32    # 도로 제한속도
  remote          : Text     # 원격 IP
  xSpdType        : Int32    # 속도제한 타입 (카메라/구간/범프/경찰등)
  xSpdLimit       : Int32    # 속도제한 값 (km/h)
  xSpdDist        : Int32    # 속도제한까지 거리
  xSpdCountDown   : Int32    # 속도제한 카운트다운
  xTurnInfo       : Int32    # 회전 정보 (좌/우/포크 등)
  xDistToTurn     : Int32    # 회전까지 거리
  xTurnCountDown  : Int32    # 회전 카운트다운
  atcType         : Text     # 자동회전 타입
  vTurnSpeed      : Int32    # 커브 속도
  szPosRoadName   : Text     # 현재 도로명
  szTBTMainText   : Text     # TBT 안내 텍스트
  desiredSpeed    : Int32    # 목표 속도
  desiredSource   : Text     # 속도 소스 (cam/road/atc/vturn등)
  carrotCmdIndex  : Int32    # 명령 인덱스
  carrotCmd       : Text     # 명령 (DETECT/DISPLAY 등)
  carrotArg       : Text     # 명령 인자
  xPosLat/Lon     : Float32  # GPS 위치
  xPosAngle       : Float32  # 진행 방향
  xPosSpeed       : Float32  # 속도
  trafficState    : Int32    # 신호등 상태 (0/1/2/3)
  nGoPosDist/Time : Int32    # 목적지 거리/시간
  szSdiDescr      : Text     # SDI 설명
  naviPaths       : Text     # 경로 좌표 (x,y,d;...)
  leftSec         : Int32    # 카운트다운 초
}
```

> [!TIP]
> **HUD에 필요한 데이터의 대부분이 `carrotMan` 1개 메시지에 이미 있다.**
> 사이드카가 28개 서비스를 직접 구독할 이유가 없다.

### stream_encoderd 실행 조건 — 카메라 릴레이 영향

```python
# process_config.py (v10)
NativeProcess("encoderd", "system/loggerd", ["./encoderd"], only_onroad)
  → 발행: roadEncodeData (항상 on-road 시 실행) ✅

NativeProcess("stream_encoderd", "system/loggerd", ["./encoderd", "--stream"],
              or_(notcar, and_(only_onroad, enable_webrtc)))
  → 발행: livestreamRoadEncodeData
  → 조건: DisableDM==2 에서만 실행 ⚠️
```

| 카메라 소스 | 발행 조건 | 사이드카에서 사용 |
|------------|---------|----------------|
| `roadEncodeData` | 주행 중 **항상** 발행 | quality 모드(2순위) |
| `livestreamRoadEncodeData` | `enable_webrtc`일 때만 | stable 모드(1순위) |

> [!CAUTION]
> **WebRTC 폐기 → `stream_encoderd` 미실행 → `livestreamRoadEncodeData` 미발행**
> 하지만 `roadEncodeData`는 **항상 발행**되므로 카메라 릴레이에는 문제 없음.
> 단, `roadEncodeData`는 loggerd와 경합하므로 부하가 더 클 수 있음.

### v10 프로세스 목록 (carrot 관련)

| 프로세스 | 실행 조건 | 비고 |
|---------|---------|------|
| `carrot_man` | **항상** | SubMaster 11개 구독, PubMaster 3개 발행 |
| `carrot_server` | **항상** | aiohttp 웹서버 포트 7000 (설정UI) |
| `xiaoge_data` | ShareData 활성 시 | 데이터 공유 |
| `ui` (carrot.h/cc 통합) | **항상** | NanoVG 렌더링 (네이티브 UI) |

---

## 현재 vs 목표 아키텍처

### 현재 (문제)

```
comma 디바이스
┌──────────────────────────────────────────────────────────────┐
│  openpilot (v10, 수정불가)                                    │
│  ┌─────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────┐     │
│  │ modeld  │ │controlsd │ │ camerad  │ │ carrot_man   │     │
│  └────┬────┘ └────┬─────┘ └────┬─────┘ └───┬──────────┘     │
│       └───────────┴────────────┴────────────┘               │
│                     cereal IPC 버스                           │
│       ┌───────────┬──────────┬─────────────┐                │
│  ┌────┴──────┐ ┌──┴──────┐ ┌┴──────┐ ┌────┴────┐           │
│  │sidecar.py │ │camera.py│ │hud.py │ │diag.py  │ 4개 추가   │
│  │3×SM(28개) │ │1×SM     │ │proxy  │ │file     │ ★ 문제     │
│  │overlay2D ★│ │H.264 ★  │ │       │ │serve    │            │
│  │JSON+zlib  │ │relay    │ │       │ │         │            │
│  └─────┬─────┘ └────┬────┘ └───┬───┘ └────┬───┘            │
│   ws:7766     ws:7768     ws:7767     http:7769             │
└────────┼────────────┼──────────┼──────────┼─────────────────┘
         └────────────┴──────────┴──────────┘
                      ▼
              CarrotLink 앱 (Flutter)
```

### 목표 (Slim Proxy)

```
comma 디바이스
┌──────────────────────────────────────────────────────────────┐
│  openpilot (v10, 그대로)                                      │
│  ┌─────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────┐     │
│  │ modeld  │ │controlsd │ │ encoderd │ │ carrot_man   │     │
│  └────┬────┘ └────┬─────┘ └────┬─────┘ └───┬──────────┘     │
│       └───────────┴────────────┴────────────┘               │
│                     cereal IPC 버스                           │
│                          │                                   │
│               ┌──────────┴───────────┐                       │
│               │  sidecar.py (재작성)  │ 1개 프로세스만          │
│               │  1×SM (18개 서비스)   │                       │
│               │  연산 없음, 변환만     │                       │
│               │  카메라 릴레이 내장    │                       │
│               │  HUD/diag 내장       │                       │
│               └──────────┬───────────┘                       │
│                     ws:7766 (통합)                            │
└──────────────────────────┼───────────────────────────────────┘
                           ▼
              CarrotLink 앱 (Flutter)
              ┌───────────────────────┐
              │ 3D→2D 투영 계산       │ ← 앱이 계산
              │ Canvas 렌더링         │
              │ HUD 그래픽            │
              └───────────────────────┘
```

---

## 상세 변경사항

### 1. 프로세스 통합 4→1

| 현재 | 변경 | 이유 |
|------|------|------|
| sidecar.py | sidecar_slim.py | 핵심만 남기고 재작성 |
| camera.py | **삭제** | CameraRelayHub가 sidecar에 이미 내장 |
| hud.py | **삭제** | `/ws/hud` 엔드포인트가 sidecar에 이미 존재 |
| diag.py | **삭제** | `/health`가 sidecar에 이미 존재 |

### 2. SubMaster 축소 3개→1개 (28→12 서비스)

> [!IMPORTANT]
> 아래 목록은 Flutter `_DriveOverlaySnapshot.fromSidecar()`가 payload에서 **실제로 읽는 키**를 역추적하여 확정한 것임. 추측이 아닌 코드 기반 검증 결과.

**Flutter가 payload에서 읽는 전체 키 (line 521~925):**
`carState`, `selfdriveState`, `controlsState`, `longitudinalPlan`,
`lateralPlan`, `radarState`, `pathStyle`(Params), `liveCalibration`,
`cachedCalibration`(Params), `roadCameraState`, `wideRoadCameraState`,
`modelV2`, `carrotMan`, `navInstructionCarrot`, `debugPlot`, `overlay2d`

| 서비스 | 구독 | Flutter 사용 내용 |
|--------|------|------------------|
| carState | ✅ 유지 | vEgo, aEgo, brakeLights, leftLaneLine, rightLaneLine, useLaneLineSpeed |
| selfdriveState | ✅ 유지 | active (engaged 여부) |
| controlsState | ✅ 유지 | activeLaneLine |
| longitudinalPlan | ✅ 유지 | xState(실험모드), accel0 |
| liveCalibration | ✅ 유지 | rpyCalib, wideFromDeviceEuler, height, calStatus |
| carrotMan | ✅ 유지 | naviPaths, xTurnInfo, xDistToTurn, szTBTMainText |
| modelV2 | ✅ 유지 | pathX/Y/Z, laneLines, roadEdges, laneLineProbs/Stds, frameId |
| radarState | ✅ 유지 | leadOne, leadTwo, leadsLeft, leadsRight, leadsCenter |
| lateralPlan | ✅ 유지 | position(x,y,z) — 차선보조 경로 렌더링 |
| navInstructionCarrot | ✅ 유지 | maneuverPrimaryText/Type/Modifier/Distance, distanceRemaining |
| roadCameraState | ✅ 유지 | **frameId** — overlay-카메라 프레임 동기화에 핵심 사용 |
| wideRoadCameraState | ✅ 유지 | **frameId** — 위와 동일, AR scene 카메라 선택에도 사용 |
| carControl | ❌ 제거 | Flutter에서 미사용 확인 |
| liveParameters | ❌ 제거 | Flutter에서 미사용 확인 |
| deviceState | ❌ 제거 | 드라이브 화면에서 미사용 확인 |
| peripheralState | ❌ 제거 | 드라이브 화면에서 미사용 확인 |
| gpsLocation 등 | ❌ 제거 | carrotMan.xPosLat/Lon으로 대체 |

> [!NOTE]
> **Params에서 읽는 데이터 (SubMaster 아님, 유지 필요):**
> - `pathStyle`: ShowPathMode/Color/Width 등 → 1초 캐시, 부하 극소
> -`cachedCalibration`: liveCalibration 없을 때 fallback
> - `debugPlot`: ShowPlotMode — 디버그 차트용 (선택적)

### 3. overlay2D 완전 제거 → 앱측 렌더링

> [!CAUTION]
> Flutter 렌더링 코드가 `sidecarOverlay2d` 필드에 의존하는 부분이 있음 (overlay_sync, overlay_components).
> overlay2d를 제거하면 이 필드가 null이 되므로, **Flutter 쪽에서 원시 데이터 기반 렌더링 fallback을 동시에 구현**해야 함.
> 순서: 먼저 Flutter에 원시 데이터 렌더링 구현 → 그 다음 sidecar에서 overlay2d 제거.

**sidecar(콤마)에서 앱(Flutter)으로 이전하는 연산:**

| 함수 (현재 sidecar.py) | 기능 | 이전 후 |
|----------------------|------|---------|
| `_build_car_space_transform()` | 4×4 변환행렬 (numpy) | Flutter Matrix4로 재구현 |
| `_map_line_to_track_vertices_dist()` | 경로 폴리곤 (numpy) | Flutter Canvas.drawPath()로 재구현 |
| `_map_line_to_polygon_points()` | 차선 폴리곤 (numpy) | Flutter Canvas.drawPath()로 재구현 |
| `_build_overlay2d()` | 전체 오버레이 조합 | Flutter overlay_math로 재구현 |
| `_project_lead_pair()` | 리드 바운딩박스 (numpy) | Flutter Canvas.drawRect()로 재구현 |

> [!NOTE]
> **경로/차선/리드 박스는 그대로 표시됨.** 계산 장소만 콤마(Python) → 앱(Dart)으로 옮기는 것.
> 콤마는 원시 3D 좌표만 보내고, 앱이 2D로 변환하여 그림.

**sidecar가 원시 데이터를 그대로 보내는 것 (이미 구현되어 있음):**
- `modelV2`의 원시 좌표 (pathX/Y/Z, laneLines, roadEdges) → `_payload_model_v2()`
- `liveCalibration`의 rpyCalib, wideFromDeviceEuler → 이미 전송 중
- `radarState`의 leadOne/leadTwo dRel/yRel → 이미 전송 중

**Flutter에서 추가 구현할 것:**
- `live_drive_canvas_overlay_math_components.dart` 확장
- 3D→2D 투영 (Matrix4, vector_math 패키지)
- 경로 폴리곤 생성 → Canvas.drawPath()
- 리드차 바운딩박스 → Canvas.drawRect()

### 4. 카메라 — roadEncodeData 전용

WebRTC 폐기 후 카메라 소스 전략:

```python
# 변경 후: roadEncodeData만 사용 (항상 발행됨)
CAMERA_SERVICE_CANDIDATES = {
    "road": ["roadEncodeData"],        # livestream 제거
    "wideRoad": ["wideRoadEncodeData"],
}
```

- `livestreamRoadEncodeData`는 `stream_encoderd` 의존 → WebRTC 비활성 시 미발행
- `roadEncodeData`는 일반 `encoderd`가 항상 발행 → 안정적 소스
- loggerd와 경쟁 가능성 → 하지만 단일 프로세스로 통합하면 충분히 관리 가능

### 5. WebRTC 코드 전면 제거

**Flutter 쪽 삭제 대상:**
- `live_drive_canvas_camera_html_components.dart`의 `connectWebRtc()`, `fallbackToWebRtc()`, WebRTC SDP 협상 코드
- `HudDriveSettingsService.modeWebrtc` 옵션 및 설정 UI
- `live_drive_canvas_screen.dart`의 webrtc 모드 분기

### 6. safe mode: 클라이언트 연결 기반

```python
# 변경 후: 클라이언트 없으면 완전 sleep
async def _broadcast_loop(self, app):
    while True:
        if not self.clients and not self.hud_clients:
            await asyncio.sleep(1.0)  # 완전 유휴
            continue
        self.sm.update(0)
        payload = self._build_raw_payload()  # 가공 없는 원시 데이터
        # ... 전송
        await asyncio.sleep(0.04)  # 25Hz
```

---

## 예상 효과

| 항목 | 현재 | 변경 후 | 개선 |
|------|------|---------|------|
| Python 프로세스 | 4개 | 1개 | -75% |
| SubMaster 구독 | 26구독(3개 SM, 15유니크) | 18구독(1개 SM) | -31% |
| overlay2D CPU | ~15ms/프레임 | 0ms | **-100%** (핵심 절감) |
| JSON 크기 | ~50KB | ~15KB | -70% |
| 코드 줄 수 | 3,773줄 | ~1,680줄 | -55% |
| 메모리 | ~200MB (4×Python) | ~50MB | -75% |
| cold-start | 15~25초 | 3~5초 | -80% |
| 클라이언트 없을 때 CPU | 계속 가동 | 0% (sleep) | -100% |

---

## 수정 대상 파일 (CarrotLink-dev만)

### 삭제

| 파일 | 이유 |
|------|------|
| `assets/sidecar/camera.py` | sidecar에 CameraRelayHub 내장 |
| `assets/sidecar/camera.sh` | 위와 동일 |
| `assets/sidecar/hud.py` | sidecar에 /ws/hud 내장 |
| `assets/sidecar/hud.sh` | 위와 동일 |
| `assets/sidecar/diag.py` | sidecar에 /health 내장 |
| `assets/sidecar/diag.sh` | 위와 동일 |

### 대규모 수정

| 파일 | 변경 내용 |
|------|----------|
| `assets/sidecar/sidecar.py` | 3,773줄 → ~300줄 재작성 (slim proxy) |
| `assets/sidecar/sidecar.sh` | 단일 프로세스만 실행 |
| `lib/services/sidecar_service.dart` | 4개 tmux → 1개, health 체크에서 diag(7769) 포트 확인 제거, 프로필 시스템 단순화 |
| `lib/services/link_hud_service.dart` | hud.py 별도 관리 제거 |
| `lib/screens/drive/live_drive_canvas_camera_html_components.dart` | WebRTC 코드 전부 제거 |
| `lib/screens/drive/live_drive_canvas_overlay_math_components.dart` | 3D→2D 투영 엔진 구현 |
| `lib/screens/drive/live_drive_canvas_overlay_components.dart` | overlay2D → 원시 데이터 렌더링 |
| `lib/screens/settings/hud_settings_screen.dart` | Stock/WebRTC 선택 UI 제거 |

### c3-v10-wip (수정 없음) ✅

---

## 주의사항 및 리스크

### carrot_server.py (포트 7000) — 사이드카와 별개

`carrot_server.py`는 `always_run`으로 항상 실행되며, Flutter 앱의 **설정 탭/프로필 편집/백업** 기능이 이 서버에 의존함. sidecar 리팩토링과는 완전히 별개이므로 건드리지 않음.

연동하는 Flutter 서비스:
- `carrot_server_settings_service.dart` → 설정/토글값 읽기·쓰기
- `carrot_profile_service.dart` → 프로필 관리
- `backup_service.dart` → 설정 백업/복원

### sidecar_service.dart health 체크 의존성

현재 `sidecar_service.dart`의 `_isHealthy()` 메서드가 **2개 포트를 모두 확인**해야 SIDECAR_HEALTH_OK를 반환:
- 포트 7766: `kind:"carrotlink_sidecar_broker_v1"` + `cameraRelay` 필드 확인
- 포트 7769: `kind:"carrotlink_diag_snapshot_v1"` 확인

`diag.py`를 삭제하면 7769 체크가 실패 → 앱이 sidecar가 불건강하다고 판단 → **재배포 무한 루프** 발생.

따라서 slim proxy에 `/health` 엔드포인트를 포함하거나, `sidecar_service.dart`의 health 체크 로직에서 diag 포트 확인을 제거해야 함.

### roadEncodeData 사용 시 loggerd 경합

`livestreamRoadEncodeData`(stream_encoderd)가 없을 경우 `roadEncodeData`(encoderd)를 사용하게 되는데, 이 스트림은 주행 녹화(loggerd)도 구독한다. 두 소비자가 동시에 읽으면서 메모리 복사 증가 가능성 있음. 실 테스트 시 카메라 프레임 드롭 여부 모니터링 필요.

### overlay 투영 정확도 검증

Python numpy에서 Flutter Dart로 투영 알고리즘을 이식할 때, 부동소수점 차이로 미세한 좌표 불일치가 발생할 수 있음. 기존 openpilot C++ UI의 투영 결과와 비교 검증 필요.

### carrot_man.py와 sidecar의 SubMaster 중복

리팩토링 후에도 sidecar_slim.py의 SubMaster 8개 중 상당수가 carrot_man.py의 SubMaster 11개와 중복됨:

| 서비스 | carrot_man.py | sidecar_slim.py |
|--------|:---:|:---:|
| carState | ✅ | ✅ |
| selfdriveState | ✅ | ✅ |
| controlsState | ✅ | ✅ |
| longitudinalPlan | ✅ | ✅ |
| modelV2 | ✅ | ✅ |
| radarState | ✅ | ✅ |
| liveCalibration | ❌ | ✅ |
| carrotMan | ❌ (자체 발행) | ✅ |

6개가 중복 구독. 이건 v10 수정 불가 제약하에서는 피할 수 없는 비용이지만, 현재 28개보다는 큰 폭으로 감소.

### 추가 최적화 여지

| 아이디어 | 효과 | 복잡도 | 비고 |
|---------|------|-------|------|
| JSON 대신 msgpack/CBOR | 직렬화 크기 -40%, 속도 +30% | 중간 | Flutter `msgpack_dart` 패키지 존재 |
| zlib 압축 제거 | CPU -5% | 쉬움 | Wi-Fi 대역폭 충분하면 불필요 |
| 델타 업데이트 (변경분만 전송) | JSON -70% | 높음 | liveCalibration 등 1Hz 데이터에 효과적 |
| modelV2 다운샘플링 강화 | JSON -30% | 쉬움 | 33→16 포인트 (시각적 차이 미미) |
| HUD/Live 채널 분리 주기 | CPU -20% | 중간 | HUD는 5Hz, Live는 25Hz |


---

### Deferred: `_openpilotOverlayMode` dead 분기 간소화

> WebRTC 모드 제거 후 `_openpilotOverlayMode`는 항상 `true`를 반환.
> 14개 파일, 50+ 참조에 걸쳐 조건 분기가 남아있으나, 코드는 정상 동작함.
> **기능에 영향 없는 코스메틱 작업**이므로 우선순위 낮음.

**영향 파일:**
- `live_drive_canvas_sidecar_runtime_components.dart` — 12곳
- `live_drive_canvas_sidecar_components.dart` — 10곳
- `live_drive_canvas_overlay_sync_components.dart` — 3곳
- `live_drive_canvas_hud_components.dart` — 4곳
- `live_drive_canvas_camera_components.dart` — 3곳
- `live_drive_canvas_lifecycle_components.dart` — 2곳
- `live_drive_canvas_layout_components.dart` — 2곳
- 기타 6개 파일

**작업 내용:** `if (_openpilotOverlayMode)` → 항상 실행, `if (!_openpilotOverlayMode)` → 삭제.

---

### Deferred: `sidecarOverlay2d` dead code 제거

> sidecar.py에서 `overlay2d` 필드가 제거되었고, `_driveEnableExperimentalSidecarDecorations = false`이므로
> Flutter 측의 `sidecarOverlay2d` 관련 코드는 모두 dead code.
> **기능에 영향 없음** — 코드는 정상 동작 (null 경로로 안전하게 처리).

**제거 대상:**
- `_DriveOverlaySnapshot.sidecarOverlay2d` 필드 및 `copyWith` 파라미터 (`overlay_models_components.dart`)
- `_mergeSidecarOverlay2dTrackVerticesImpl()` 함수 (`overlay_sync_components.dart`)
- `_currentCameraOverlay2d()` 함수 (`overlay_components.dart`)
- `_buildNativeOverlayPayloadFromSidecar2d()` 함수 (`overlay_components.dart`)
- `_appendSidecarLeadAndRadarPolygons()` 관련 코드 (`overlay_components.dart`)
- `_decodeOverlayPoints()`, `_mapSourcePointsToCanvas()` 함수 (`overlay_components.dart`)
- `overlay_preview_components.dart`의 sidecarOverlay2d 참조
- `overlay_models_components.dart`의 `overlay2dRaw` 파싱 (줄 537-541)

---

### Deferred: `HudDriveSettingsService` dead 상수/메서드 정리

> `modeWebrtc` 상수, `getDefaultMode()`, `setDefaultMode()` 등이 남아있으나
> 항상 `openpilot_overlay`를 반환하므로 실질적 dead code.
> **기능에 영향 없음.**

**제거 대상:**
- `HudDriveSettingsService.modeWebrtc` 상수
- `getDefaultMode()` → 삭제 또는 inline
- `setDefaultMode()` → 삭제 (모드 변경 불가)
- `_hudDefaultMode` 변수 → 상수화 또는 삭제
- `hud_settings_screen.dart` → SharedPreferences 접근 제거

---

## 리팩토링 완료 현황 (2026-03-12)

| Phase | 내용 | 상태 |
|-------|------|------|
| **Phase 1** | sidecar.py 재작성 (3,773줄 → ~300줄) | ✅ 완료 |
| **Phase 2** | Flutter 서비스 정리 (camera/diag/hud/link_hud 삭제) | ✅ 완료 |
| **Phase 3** | Flutter Overlay 렌더링 | ✅ 이미 구현됨 확인 |
| **Phase 4** | WebRTC 제거 + 정리 | ✅ 핵심 완료, 코스메틱 deferred |

**빌드 상태: ✅ 통과** (flutter build apk --debug)
