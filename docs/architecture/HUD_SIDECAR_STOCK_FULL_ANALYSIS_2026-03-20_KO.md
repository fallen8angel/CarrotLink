# HUD / Sidecar / Stock 주행모드 전체 코드 분석

> 분석 일자: 2026-03-20
> 분석 대상: `lib/features/hud/`, `lib/services/sidecar_service.dart`, `lib/screens/drive/`, 관련 서비스 전체
> 분석 범위: HUD 데이터 파이프라인, Sidecar 프로세스 관리, Stock 주행 화면(LiveDriveCanvas) 전체

---

## 목차

1. [전체 아키텍처 개요](#1-전체-아키텍처-개요)
2. [HUD 시스템](#2-hud-시스템)
   - [데이터 흐름](#21-데이터-흐름)
   - [OriginalHudSnapshot 엔티티](#22-originalhudSnapshot-엔티티)
   - [PayloadMapper 듀얼 포맷](#23-payloadmapper-듀얼-포맷)
   - [Fallback 메트릭스](#24-fallback-메트릭스)
   - [Vehicle Core Carry-Forward](#25-vehicle-core-carry-forward)
   - [HudModule DI/풀링](#26-hudmodule-di풀링)
   - [SharedRuntimeManager](#27-sharedruntimemanager)
   - [프레젠테이션 레이어](#28-프레젠테이션-레이어)
3. [Sidecar 시스템](#3-sidecar-시스템)
   - [프로필 체계](#31-프로필-체계)
   - [Variant/Repo Flavor 감지](#32-variantrepo-flavor-감지)
   - [Health Check](#33-health-check)
   - [Profile Switch In-Place](#34-profile-switch-in-place)
   - [배포/리비전 관리](#35-배포리비전-관리)
4. [Stock 주행모드 (LiveDriveCanvas)](#4-stock-주행모드-livedrivecanvas)
   - [파일 구조](#41-파일-구조)
   - [주행 모드 진입 흐름](#42-주행-모드-진입-흐름)
   - [SidecarPhase 상태 머신](#43-sidecarphase-상태-머신)
   - [오버레이 렌더링](#44-오버레이-렌더링)
   - [카메라-모델 프레임 동기화](#45-카메라-모델-프레임-동기화)
   - [Camera Attach 복구 로직](#46-camera-attach-복구-로직)
   - [Lifecycle 관리](#47-lifecycle-관리)
5. [서비스 계층 정리](#5-서비스-계층-정리)
6. [코드 품질 관찰](#6-코드-품질-관찰)
7. [파일 인덱스](#7-파일-인덱스)

---

## 1. 전체 아키텍처 개요

CarrotLink는 Flutter(Dart) + Android Native(Kotlin) 하이브리드 앱으로, openpilot 기반 자율주행 장치(comma)를 원격 관리합니다. **Feature-based Clean Architecture**를 채택합니다.

### 핵심 계층 구조

```
┌─ Presentation ─────────────────────────────────────────────┐
│  AdaptiveHudHost / AdaptiveHudPanel / LiveDriveCanvasScreen │
├─ Application ──────────────────────────────────────────────┤
│  HudController / HudModule / SharedRuntimeManager           │
├─ Data ─────────────────────────────────────────────────────┤
│  DataSources → Mappers → Repositories                       │
├─ Domain ───────────────────────────────────────────────────┤
│  Entities (OriginalHudSnapshot 등) / Repository interface   │
├─ Services ─────────────────────────────────────────────────┤
│  SidecarService / SSHService / HudDriveSettingsService 등    │
└────────────────────────────────────────────────────────────┘
```

### 데이터 통신 프로토콜

| 채널 | 프로토콜 | 포트 | 용도 |
|---|---|---|---|
| HUD 스트림 | WebSocket + msgpack | 7766, 7767 | 차량 상태 데이터 (~10Hz) |
| Overlay 스트림 | WebSocket + msgpack | 7766 | AR 오버레이 데이터 (~30fps) |
| 카메라 스트림 | WebSocket + H.264 | 7766 | 실시간 카메라 영상 |
| Health API | HTTP REST | 7766 | 사이드카 상태 확인 |
| 진단 API | HTTP REST | 7769 | 디버그 진단 |
| Fallback 메트릭스 | SSH | 22 | CPU/메모리/디스크 폴링 |

---

## 2. HUD 시스템

### 2.1 데이터 흐름

```
[Sidecar Python on comma]
    ↓ WebSocket (ws://device:7766/ws/hud, msgpack 인코딩)
    ↓
HudRemoteStreamDataSource          ← 7766/7767 후보 자동 전환, reconnect 루프
    ↓ HudRemoteStreamEvent
HudRemotePayloadMapper             ← semantic/legacy 포맷 자동 분기
    ↓ OriginalHudSnapshot
HudSnapshotAssembler               ← fallback merge 적용
    ↓ OriginalHudSnapshot (merged)
HudRepositoryImpl                  ← 세션 관리, vehicle core carry-forward
    ↓ Stream<OriginalHudSnapshot>
HudController (ChangeNotifier)     ← bindLive/bindPreview/seedLiveSnapshot
    ↓
AdaptiveHudHost → AdaptiveHudPanel ← 최종 UI 렌더링
```

**병렬 경로 (Fallback):**
```
SSHService → HudSshFallbackMetricsAdapter → HudFallbackMetricsDataSource (8초 poll)
    ↓ HudFallbackMetricsSample
HudSnapshotAssembler.applyFallback() → primary snapshot에 merge
```

### 2.2 OriginalHudSnapshot 엔티티

**파일:** `lib/features/hud/domain/entities/original_hud_snapshot.dart`

마스터 데이터 모델. Immutable value object + `copyWith` 패턴. 12개 하위 상태 객체를 포함:

| 하위 상태 | 파일 | 주요 필드 |
|---|---|---|
| `HudSourceInfo` | (inline) | transport, deviceHost, endpointPort, endpointPath, receivedAtMs |
| `HudVehicleState` | (inline) | speedClusterKph, setSpeedClusterKph, speedClusterMps, setSpeedClusterMps, gearText, longActive, latActive |
| `HudGapState` | (inline) | personalityRaw, displayValue, barCount |
| `HudMetaState` | (inline) | isPreview, isFallbackMetricsApplied, missingFields, staleReasons, quality |
| `HudTempControlState` | `hud_temp_control_state.dart` | mode(hidden/apply/eco), label, speedKph, sourceRaw, applySpeedKph, cruiseTargetKph, isDecel |
| `HudDriveModeState` | `hud_drive_mode_state.dart` | code(1=ECO,2=SAFE,3=NORM,4=FAST), nameOriginal, kind |
| `HudLimitState` | `hud_limit_state.dart` | mode(hidden/limit/camera), label, displaySpeedKph, roadLimitSpeedKph, cameraLimitSpeedKph, cameraSignType, isOverLimit, shouldBlink |
| `HudConnectivityState` | `hud_connectivity_state.dart` | activeCarrot, badgeMode(hidden/apn/apm), badgeLabel |
| `HudSignalState` | `hud_signal_state.dart` | trafficStateLp, trafficStateCarrot, visualState(red/green/yellow/off), redDot |
| `HudGpsState` | `hud_gps_state.dart` | hasFix, provider |
| `HudDeviceMetricsState` | `hud_device_metrics_state.dart` | cpuTempAvgC, cpuTempMaxC, memUsagePct, diskUsedPct, freeSpacePct, voltV, metricPrimaryMode |
| `HudVisibilityState` | `hud_visibility_state.dart` | showDeviceState, showDateTimeMode |

### 2.3 PayloadMapper 듀얼 포맷

**파일:** `lib/features/hud/data/mappers/hud_remote_payload_mapper.dart`

#### Semantic 포맷 감지 기준
```dart
bool _looksLikeSemanticSnapshot(Map<String, dynamic> raw) {
  return raw['vehicle'] is Map || raw['tempControl'] is Map;
}
```

#### Semantic 매핑
구조화된 JSON 그대로 → 각 하위 entity에 대응. `_asDouble`, `_asInt`, `_asBool` 등 안전한 타입 변환.

#### Legacy 매핑
flat 구조 (`vEgo`, `vEgoCluster`, `gear`, `speedLimitKph` 등) → semantic entity로 변환.

속도 변환 우선순위:
```
speedClusterKph → vEgoKph → vEgoClusterKph(=vEgoCluster*3.6) → vEgoKph(=vEgo*3.6)
```

#### DriveModeState 빌더

| Code | Name | Kind |
|---|---|---|
| 1 | ECO | eco |
| 2 | SAFE | safe |
| 3 (default) | NORM | normal |
| 4 | FAST | fast |

코드가 없으면 nameOriginal/kind 텍스트에서 추론.

#### TempControl 빌더 (3단계 판정)

1. **apply**: `sourceRaw`이 있고 `applySpeedKph`가 있으면 → mode=apply
2. **eco**: `cruiseTargetKph`와 `setSpeedClusterKph` 차이가 ≥0.5이면 → mode=eco
3. **hidden**: 그 외

#### LimitState 빌더

- 모드 자동 감지: `cameraLimitSpeedKph > 0` → camera, `roadLimitSpeedKph > 0` → limit, 없으면 hidden
- `isOverLimit` 계산: `currentSpeedKph > (resolvedDisplay + 2.0)`
- `shouldBlink`: camera 모드이면 항상 true

#### SignalState 빌더

`visualState` 정규화: red/stop→red, green/go→green, yellow/amber→yellow, off/none/""→off (단, redDot이면 red)

### 2.4 Fallback 메트릭스

**파일:** `lib/features/hud/data/adapters/hud_ssh_fallback_metrics_adapter.dart`

SSH를 통해 CPU 온도/메모리/디스크 사용량을 8초 주기로 폴링. WebSocket HUD 스트림에 해당 값이 null일 때만 merge.

**Merge 정책** (`lib/features/hud/data/mappers/hud_fallback_merge_policy.dart`):
- cpuTempAvgC/MaxC, memUsagePct, diskUsedPct 각각 null인 필드만 대체
- merge 시 `meta.isFallbackMetricsApplied = true`, `quality = 'degraded'`

### 2.5 Vehicle Core Carry-Forward

**파일:** `lib/features/hud/data/repositories/hud_repository_impl.dart` (L203-257)

C4 프로필(`p1c4`)은 carState를 생략할 수 있어, 이전 스냅샷의 speed/gear 값을 **1.5초(1500ms)** 이내로 carry-forward:

- `speedClusterKph`가 null이고 이전 값이 있으면 이전 값 유지
- `setSpeedClusterKph` 동일
- gear가 'U'/'X'/'' 이고 이전 gear가 유효하면 이전 값 유지

### 2.6 HudModule (DI/풀링)

**파일:** `lib/features/hud/application/hud_module.dart`

#### Repository 풀링
- SSH 인스턴스를 키로 `_HudRepositoryPoolEntry` 맵에 저장
- 참조 카운트 관리 → 모든 lease 해제 후 **30초 grace period** → dispose

#### Controller 풀링
- 동일 구조, **45초 grace period**
- Controller는 내부적으로 Repository lease를 소유

#### ensureLiveTransport()
```dart
static Future<HudTransportBootstrapResult> ensureLiveTransport(
  SSHService sshService,
  {String profile = SidecarService.hudBootstrapProfile}
)
```
→ `SidecarService.shared.ensureRunning(ssh, profile: profile)` 호출하여 사이드카 부팅.

### 2.7 SharedRuntimeManager

**파일:** `lib/features/hud/application/hud_runtime_manager.dart`

앱 전역 런타임 매니저. ChangeNotifier를 상속하여 Provider로 공유.

#### HUD 스트림 관리
- `HudModule.acquireSharedController()` 통해 컨트롤러 획득
- SSH 연결 변경 감지 → `_ensureBound()` → `bindLive(host)`
- HUD Feature 설정 변경 감지 → 활성/비활성 전환

#### Overlay 스트림 관리

**독립 Isolate 워커** (`_overlayRuntimeWorkerMain`):
```
ws://device:7766/ws/live?encoding=msgpack&camera=road&role=drive_overlay&session=app_overlay_{gen}
```

- zlib 압축 + msgpack 디코딩 (fallback: plain UTF-8 JSON)
- 연결 끊어지면 350ms 후 재시도 (무한 루프)
- SendPort를 통해 메인 isolate에 frame/connected 이벤트 전달

#### 프레임 버퍼
- **220프레임** ring buffer (`_overlayByModelFrame` + `_overlayFrameOrder`)
- `modelFrameId` 기반 인덱싱
- `OverlayStreamFrame`: host, payload, modelFrameId, roadFrameId, wideRoadFrameId, receivedAtMs, sequence

#### 앱 라이프사이클
- foreground → background: **15초** grace 후 overlay worker 정지
- background → foreground: 즉시 `_ensureBound()` + overlay stream restart

#### HUD Snapshot 캐시
- host별 최신 스냅샷 최대 **4개** 유지 (LRU)
- 새 host 바인딩 시 캐시된 스냅샷으로 즉시 seed

### 2.8 프레젠테이션 레이어

#### HudAdaptiveDisplayModel
**파일:** `lib/features/hud/presentation/models/hud_adaptive_display_model.dart`

`OriginalHudSnapshot` → 표시용 문자열/불리언으로 변환하는 ViewModel.

주요 변환:
- driveMode: ECO→에코, SAFE→안전, FAST→고속, NORM→일반
- limit: 과속중/구간/CAM/LIMIT + 속도
- connectivity: APN/APM 배지
- signal: 적색/녹색/황색/off
- compatibilityHint: 지연/대기 상태 한글 메시지
- `_isSemanticLive()`: transport가 sidecar_hud이고 2.5초 이내 수신이면 true
- `_shouldShowAssistContext()`: longActive 또는 속도 > 1km/h이면 보조 정보 표시
- Camera alert blink: 1600ms 주기, 800ms부터 ON

#### HudLayoutProfile
**파일:** `lib/features/hud/presentation/models/hud_layout_profile.dart`

4단계 density × 4가지 surface 조합으로 폰트/패딩/레이아웃 자동 결정:

| Density | 기준 (heightWeightedShortest) | 속도 폰트 |
|---|---|---|
| micro | < 190 | 74px |
| compact | 190~280 | 90px |
| regular | 280~420 | 110px |
| spacious | > 420 | 128px |

Surface: `homePreview`, `driveInline`, `driveOverlay`, `preview`

#### AdaptiveHudHost
**파일:** `lib/features/hud/presentation/widgets/adaptive_hud_host.dart`

- SharedRuntimeManager가 있으면 AnimatedBuilder로 직접 구독
- 없으면 HudControllerBuilder로 독립 컨트롤러 생성
- `syncNativeOverlay: true`일 때 NativeOverlayHudService와 스냅샷 동기화

---

## 3. Sidecar 시스템

**파일:** `lib/services/sidecar_service.dart` (~1200줄)

원격 comma 장치에서 실행되는 Python 프로세스(`sidecar.py`)를 SSH를 통해 관리.

### 3.1 프로필 체계

| 프로필 | 상수명 | Graphics | Vehicle | Full | 주 용도 |
|---|---|---|---|---|---|
| `p0` | - | - | O | - | 최소 부트스트랩 |
| `p1` | `hudBootstrapProfile` | - | O | - | C3 HUD 부트스트랩 |
| `p1c4` | `c4HudBootstrapProfile` | O | - | - | C4 HUD 부트스트랩 |
| `p2d` | `driveRuntimeProfile` | O | O | - | C3 Drive 런타임 |
| `p2c4` | `c4DriveRuntimeProfile` | O | O | - | C4 Drive 런타임 |
| `p2` | `fullRuntimeProfile` | O | O | O | Full 런타임 |
| `p3`, `p4` | - | O | O | O | 확장 런타임 |

**프로필 선택 로직:**
```
요청 프로필이 bootstrap이면:
  repoFlavor == c4 → p1c4
  그 외 → p1

Drive 진입 시:
  repoFlavor == c4 → p2c4
  그 외 → p2d
```

**서비스별 필요 조건:**

| 프로필 그룹 | 필요 조건 |
|---|---|
| Bootstrap (p0/p1) | vehicleReady OR hudReady |
| C4 Bootstrap (p1c4) | graphicsReady |
| Drive (p2d/p2c4) | graphicsReady AND vehicleReady AND controlsReady |
| Full (p2/p3/p4) | driveReady AND radarState fresh |

### 3.2 Variant/Repo Flavor 감지

#### Variant 감지 순서 (`_resolveSidecarVariant`)
1. `$BASE/.variant` 파일 읽기
2. git branch 이름에 `c4` 포함 → `c4_safe`
3. `process_config.py`에 `PythonProcess("ui")` 있으면 → `c4_safe`
4. 기본값: `default`

#### Repo Flavor 감지 순서 (`_resolveRemoteRepoFlavor`)
1. git branch에 `c4` → `c4`, `c3` → `c3`
2. `process_config.py`: `PythonProcess("ui")` → `c4`, `NativeProcess("ui")` → `c3`
3. 기본값: `unknown`

모두 **60초 TTL** 캐싱.

### 3.3 Health Check

**엔드포인트:** `http://127.0.0.1:7766/health`

```json
{
  "kind": "carrotlink_sidecar_broker_v1",
  "ok": true,
  "profile": "p2d",
  "variant": "default",
  "hudReady": true,
  "graphicsReady": true,
  "vehicleReady": true,
  "controlsReady": true,
  "driveReady": true,
  "fullReady": false,
  "liveReady": true,
  "cameraReady": true,
  "serviceHealth": {
    "modelV2": {"isFresh": true},
    "liveCalibration": {"isFresh": true},
    "roadCameraState": {"isFresh": true},
    "carState": {"isFresh": true},
    "controlsState": {"isFresh": true},
    "radarState": {"isFresh": false}
  }
}
```

**검증 로직 (`_healthMatchesExpected`):**

1. `kind == carrotlink_sidecar_broker_v1` 확인
2. `ok == true` 확인
3. 프로필/variant 일치 확인
4. 서비스 freshness 복합 판정:
   - `graphicsReady = graphicsReady || (liveReady && (cameraReady || freshVisionCore))`
   - `vehicleReady = vehicleReady || (hudReady && carState.isFresh)`
   - `controlsReady = controlsReady || controlsState.isFresh`
   - `driveReady = graphicsReady && vehicleReady && controlsReady`
   - `fullReady = driveReady && radarState.isFresh`

**End-to-end 검증:** SSH health + TCP 소켓 reachability (포트 7766, 800ms timeout)

### 3.4 Profile Switch In-Place

실행 중인 사이드카에 프로필 전환 요청:

```
POST http://127.0.0.1:7766/profile
Body: {"profile": "p2d"}
```

전환 후 200ms 간격으로 최대 20회 health polling → 안정 대기.

### 3.5 배포/리비전 관리

#### 리비전 계산
```
schema = "carrotlink-sidecar-rev-v4\npy={sha256(sidecar.py)}\nsh={sha256(sidecar.sh)}\n"
revision = sha256(schema)
```

#### ensureRunning() 흐름
```
1. variant/repoFlavor 해석
2. 프로필 resolve (bootstrap이면 C3/C4에 따라 p1/p1c4)
3. cooldown (20초) 이내면:
   a. end-to-end health 확인 → OK면 return
   b. 6초 grace polling → OK면 return
   c. 아니면 full ensure
4. full ensure:
   a. local/remote revision 비교
   b. 일치 + healthy → return
   c. 일치 + remote healthy but 클라이언트 도달 불가 → stop + restart
   d. 불일치 → SIDECAR_INSTALL_REQUIRED 예외
   e. 일치 + unhealthy → start()
```

#### 의존성 관리
`msgpack` Python 패키지를 `$BASE/pydeps/` 디렉토리에 `pip install --target` 설치.

#### Legacy 정리
이전 버전 sidecar 파일/프로세스 자동 정리 (마커 파일 기반, 기본 비활성화).

---

## 4. Stock 주행모드 (LiveDriveCanvas)

### 4.1 파일 구조

**메인 파일:** `lib/screens/drive/live_drive_canvas_screen.dart` (~450줄 state 선언)

**18개 part 파일:**

| 파일명 | 역할 |
|---|---|
| `live_drive_canvas_sidecar_components.dart` | SharedRuntimeManager 연결, overlay frame 소비, WS 연결 상태 관리 |
| `live_drive_canvas_sidecar_bootstrap_components.dart` | 최초 deploy, revision 검증, auto-bootstrap |
| `live_drive_canvas_sidecar_runtime_components.dart` | 복구 스케줄링, adaptive camera quality, flavor hint 해석 |
| `live_drive_canvas_sidecar_transport_components.dart` | HTTP 클라이언트 (sidecar:7766, camera:7766, diag:7769) |
| `live_drive_canvas_overlay_components.dart` | `_DriveOverlayPainter` CustomPainter, 3D→2D 투영, EMA 스무딩 |
| `live_drive_canvas_overlay_models_components.dart` | `_DriveOverlaySnapshot` 모델 (path, lanes, leads, radar, nav) |
| `live_drive_canvas_overlay_sync_components.dart` | 카메라-모델 프레임 동기화, provisional sync, stale detection |
| `live_drive_canvas_overlay_math_components.dart` | 3x3 행렬 연산 (`_M3`), rotation from Euler, 좌표 변환 |
| `live_drive_canvas_camera_components.dart` | 네이티브 카메라 attach/detach, error grace, recovery |
| `live_drive_canvas_camera_html_components.dart` | WebView 카메라 폴백 |
| `live_drive_canvas_camera_diag_components.dart` | 카메라 진단 데이터 수집, tmux 세션 캡처 |
| `live_drive_canvas_hud_components.dart` | portrait/landscape HUD 패널 배치, viewport zoom preset |
| `live_drive_canvas_lifecycle_components.dart` | foreground/background 전환, wakelock, orientation lock |
| `live_drive_canvas_yolo_components.dart` | YOLO 디텍션 오버레이, 네이티브 config push |
| `live_drive_canvas_layout_components.dart` | adaptive layout 계산 |
| `live_drive_canvas_dev_playback_components.dart` | 개발자용 오프라인 비디오 재생 |
| `live_drive_canvas_diag_logging_components.dart` | 진단 로그 파일 기록 |
| `live_drive_canvas_plot_components.dart` | 디버그 플롯 렌더링 |
| `live_drive_canvas_settings_popup_components.dart` | 설정 팝업 (그래픽/YOLO 탭) |

### 4.2 주행 모드 진입 흐름

```
LiveDriveCanvasScreen(hostIp)
  ↓ initState()
  ├─ _loadHudDefaultMode() → 항상 openpilot_overlay
  ├─ _loadHudDebugLayerToggles() → SharedPreferences에서 AR 레이어 토글 복원
  ├─ _applyHudModeRuntime()
  │   ├─ _clearSidecarRecoverySchedule()
  │   ├─ _startAdaptiveCameraQualityLoop()
  │   ├─ _setNativeCameraAttachReady(false) → 사이드카 연결 전
  │   ├─ _loadCameraSource(force: true) → 카메라 WebSocket URL 구성
  │   └─ _ensureSidecarRuntime(reason: 'mode_apply')
  │       ├─ revision 검증 → mismatch 시 deploy
  │       ├─ SidecarService.ensureRunning(ssh, profile: p2d/p2c4)
  │       └─ SharedRuntimeManager.ensureOverlayStream(camera: road)
  └─ _attachSharedOverlayRuntime(runtime)
      └─ overlayStreamListenable 구독 시작
```

### 4.3 SidecarPhase 상태 머신

```
                  ┌─────────────────────────────┐
                  ↓                             │
idle ──→ deploying ──→ starting ──→ verifying ──→ running
                                       │
                                       ↓
                                    failed
                                       │
              stopping ←───────────────┘
                  │
                  ↓
                idle
```

- **idle**: 초기 상태, 사이드카 미실행
- **deploying**: sidecar.py/sidecar.sh 업로드 중
- **starting**: tmux 세션에서 sidecar.sh 실행 중
- **verifying**: health check 대기 (6초 grace, 350ms 간격 polling)
- **running**: 정상 동작
- **stopping**: 백그라운드/모드 전환으로 중지 중
- **failed**: 부팅 실패

### 4.4 오버레이 렌더링

#### `_DriveOverlayPainter`

Canvas에 다음 요소를 그림:
- **Path fill**: 주행 경로 (model path / lateral path 선택)
- **Lane lines**: 차선 (좌/우)
- **Road edges**: 도로 가장자리
- **Lead 1/2**: 선행 차량 표시 (EMA 스무딩, alpha=0.72)
- **Radar badge/vector**: 레이더 감지 차량
- **Stop distance**: TF 정지 거리
- **State text**: 주행 상태 텍스트
- **Stock top-right**: 원본 openpilot 우상단 정보
- **Lane metrics**: 차선 메트릭
- **Debug plot**: 디버그 그래프
- **Nav path/TBT**: 네비게이션 경로 및 회전 안내

#### 3D → 2D 투영 파이프라인

```
calibrationRpy (3 floats)
    → _rotationFromEuler() → deviceFromCalib (3x3 rotation)
    → _viewFromDevice × (wideFromDevice ×) deviceFromCalib = viewFromCalib
    → _intrinsicForSource() × viewFromCalib = calibTransform
    → 3D 점 (x, y, z) → calibTransform 적용 → 2D 화면 좌표 (px, py)
```

카메라 intrinsic:
- Road camera: focal = 2648, cx = 964, cy = 604 (1928×1208 기준)
- Wide camera: focal = 567, cx = 964, cy = 604

#### 프레임 보간

`_renderTicker`에서 매 프레임:
1. `_renderFromSnapshot` → `_renderToSnapshot` 선형 보간 (t = elapsed / duration)
2. 보간 duration: `smoothedSyncInterval * 0.45` (6ms~50ms 클램프)
3. Path animation: 속도에 비례하는 시퀀스 (감속 시 역방향, aEgo < -1.0)

#### Native Overlay Push

MethodChannel `carrotlink/native_drive_video_control`:
- `updateOverlay`: 직렬화된 overlay payload 전송 (16.6ms 쓰로틀)
- `clearOverlay`: 오버레이 초기화
- signature hash로 중복 push 방지

### 4.5 카메라-모델 프레임 동기화

#### 핵심 메커니즘

overlay 스트림의 `modelFrameId`와 카메라의 `roadFrameId`를 매칭:

```dart
_DriveOverlaySnapshot? _findSyncedSnapshot(int cameraFrameId, {required int maxDelta}) {
  // 정확 매칭 시도
  final exact = _overlayByModelFrame[cameraFrameId];
  if (exact != null) return exact;
  // ±maxDelta 범위에서 가장 가까운 프레임 검색
  for (var delta = 1; delta <= maxDelta; delta++) { ... }
}
```

`maxDelta`: 라이브 기본값 = **8프레임**

#### 동기화 상태 판정 흐름 (`_publishOverlaySynced`)

```
1. cameraFrameId 없음?
   ├─ provisional sync 활성 → 최신 overlay 그대로 publish
   ├─ graphicsReady 상태 → 최신 overlay publish
   ├─ strictFrameLock + 120ms 초과 → stale 상태로 최신 overlay publish
   └─ strictFrameLock 없으면 → 최신 overlay 그냥 publish

2. cameraFrameId 있음?
   ├─ synced snapshot 찾음 → 정상 publish + stale 해제
   ├─ 못 찾음 + provisional sync → 최신 overlay publish
   ├─ 못 찾음 + synthetic sync → 최신 overlay publish
   ├─ 못 찾음 + graphicsReady → 최신 overlay publish
   └─ 못 찾음 + stale timeout → holdLastGood 또는 degraded publish
```

#### Provisional Sync

사이드카 연결 직후 / 카메라 attach 직후 **4초 동안** 프레임 동기화 없이 overlay 표시. 네이티브 프레임 3개 이상 안정되면 종료.

#### Stale Detection

overlay가 120ms 이상 업데이트 안 되면 stale 상태 진입 → `_overlayStaleActive = true`.
900ms 이상 stale이면 degraded publish로 전환.

### 4.6 Camera Attach 복구 로직

#### CameraAttachPhase 상태

```
idle → surfaceReady → socketConnecting → socketConnected → waitingFirstFrame → streaming
                                                                    ↓
                                                                 retrying
```

#### 복구 정책

| 조건 | 동작 |
|---|---|
| 첫 프레임 미수신 9초 초과 | `_forceRestartNativeCameraAttach()` |
| 복구 시도 간 cooldown | 12초 |
| 소켓 에러 startup 6초 이내 | suppress (사이드카 아직 부팅 중) |
| transient 에러 | 5초 후 에스컬레이션 |
| codec configured but no sync frame | synthetic sync 모드 판단 |
| degraded fallback | 카메라 없어도 overlay만 렌더링 (2.2초 대기 후) |

#### Adaptive Camera Quality

`POST /camera_quality` → `{mode: "stable"}` — 저지연 모드 고정. 사이드카 연결 시 자동 동기화.

### 4.7 Lifecycle 관리

#### Background 전환

```
didChangeAppLifecycleState(paused/inactive)
    → 3.2초 debounce (lifecycleSuspendDelay)
    → _suspendForBackground()
        ├─ 카메라 suspend
        ├─ adaptive quality loop 정지
        ├─ display refresh rate 복원
        ├─ 45초 후 사이드카 프로세스 stop (backgroundProcessKeepAlive)
        └─ 15초 후 UI 리셋 (backgroundUiResetGrace)
```

#### Resume 전환

```
didChangeAppLifecycleState(resumed)
    → _resumeFromBackground()
        ├─ orientation lock 복원
        ├─ display high refresh 활성화
        ├─ UI 리셋 전이면: 카메라 reattach + sidecar re-ensure
        └─ UI 리셋 후면: _applyHudModeRuntime() (전체 재초기화)
```

#### 추가 기능
- **Wakelock**: 주행 화면 진입 시 화면 꺼짐 방지
- **Orientation**: landscape + portrait 허용, 주행 화면에서 landscape 우선
- **Display tuning**: Android MethodChannel로 고주사율 모드 제어

---

## 5. 서비스 계층 정리

| 서비스 | 파일 | 역할 |
|---|---|---|
| `HudDriveSettingsService` | `lib/services/hud_drive_settings_service.dart` | 주행 모드 설정 (WebRTC 제거됨, 항상 openpilot_overlay) |
| `HudFeatureSettingsService` | `lib/services/hud_feature_settings_service.dart` | HUD/Stock 기능 전체 on/off (`hud_stock_feature_enabled_v1`) |
| `NativeOverlayHudService` | `lib/services/native_overlay_hud_service.dart` | Android WindowManager 오버레이 (현재 `isSupported=false`) |
| `SidecarService` | `lib/services/sidecar_service.dart` | 원격 Python 프로세스 관리 (~1200줄) |
| `SSHService` | `lib/services/ssh_service.dart` | SSH 연결/명령 실행 |
| `HudInstallProgressService` | `lib/services/hud_install_progress_service.dart` | 사이드카 설치 진행 상태 UI |

---

## 6. 코드 품질 관찰

### 잘 된 부분

- **Clean Architecture** 구조가 일관적 (domain/data/application/presentation 명확 분리)
- 모든 entity가 **immutable + copyWith** 패턴 → 안전한 상태 관리
- **스트림 기반 반응형** 데이터 흐름 (StreamController → broadcast)
- **참조 카운트 풀링**으로 리소스 누수 방지 (HudModule)
- **Semantic/Legacy 듀얼 포맷** 자동 감지 → 하위 호환성 유지
- 프레임 동기화 로직이 매우 정교 (provisional sync, stale detection, carry-forward, degraded fallback)
- Sidecar 프로필 체계가 C3/C4 디바이스 차이를 잘 추상화
- 오버레이 렌더링에서 **EMA 스무딩** + **프레임 보간**으로 부드러운 AR 표시
- Lifecycle 관리가 세밀 (debounce, grace period, keepalive 각각 분리)

### 개선 가능 부분

- `_LiveDriveCanvasScreenState`에 **~150개 인스턴스 변수** — part 파일로 코드를 분리했지만 단일 State 객체에 모든 상태 집중. State 객체 분리 또는 별도 상태 관리 패턴 검토 필요.
- `NativeOverlayHudService.isSupported = false`인데 관련 코드가 남아있음 (잠재적 dead code)
- `SidecarService`에 SSH shell script가 inline 문자열로 포함 → 테스트/디버깅 어려움. 별도 asset 또는 template 분리 고려.
- `_LiveDriveCanvasScreenState`의 static const들이 prefix 없이 혼재하여 검색/분류 어려움.
- Overlay push signature hash가 30개 이상 필드를 `Object.hashAll`로 결합 → 변경 사유 추적 어려움.

---

## 7. 파일 인덱스

### HUD Feature (`lib/features/hud/`)

```
hud.dart                                          # barrel export
application/
  hud_controller.dart                             # ChangeNotifier, bindLive/bindPreview
  hud_controller_state.dart                       # immutable state (snapshot, isLoading, host, error)
  hud_module.dart                                 # DI, pool 관리, ensureLiveTransport
  hud_runtime_manager.dart                        # SharedRuntimeManager (app-scope), overlay isolate
data/
  adapters/
    hud_ssh_fallback_metrics_adapter.dart          # SSH → HudFallbackMetricsSample 변환
  datasources/
    hud_fallback_metrics_data_source.dart          # 8초 poll stream
    hud_preview_data_source.dart                   # 프리뷰 모드 합성 데이터
    hud_remote_stream_data_source.dart             # WebSocket 7766/7767 스트림
  logging/
    hud_stream_log_writer.dart                     # 스트림 진단 로그
  mappers/
    hud_fallback_merge_policy.dart                 # CPU/MEM/DISK null 필드만 대체
    hud_remote_payload_mapper.dart                 # semantic/legacy 듀얼 매핑
    hud_snapshot_assembler.dart                    # 조합 + degrade
  models/
    hud_fallback_metrics_sample.dart               # SSH fallback 데이터 모델
    hud_remote_stream_event.dart                   # WS 이벤트 wrapper
  repositories/
    hud_repository_impl.dart                       # 세션 관리, carry-forward
  serializers/
    hud_snapshot_json_serializer.dart              # JSON 직렬화
domain/
  entities/
    hud_connectivity_state.dart                    # activeCarrot, badgeMode
    hud_device_metrics_state.dart                  # cpu, mem, disk, volt
    hud_drive_mode_state.dart                      # code, nameOriginal, kind
    hud_gps_state.dart                             # hasFix, provider
    hud_limit_state.dart                           # mode, speed, isOverLimit
    hud_signal_state.dart                          # trafficState, visualState, redDot
    hud_temp_control_state.dart                    # mode, label, speedKph, isDecel
    hud_visibility_state.dart                      # showDeviceState, showDateTimeMode
    original_hud_snapshot.dart                     # 마스터 모델 (12개 하위 상태)
  repositories/
    hud_repository.dart                            # abstract interface
presentation/
  models/
    hud_adaptive_display_model.dart                # snapshot → display ViewModel
    hud_layout_profile.dart                        # density × surface 레이아웃 결정
  widgets/
    adaptive_hud_host.dart                         # runtime/controller 바인딩
    adaptive_hud_panel.dart                        # 최종 UI 렌더링
    adaptive_hud_drive_inline_sections.dart         # portrait 인라인 HUD 섹션
    adaptive_hud_drive_inline_surface.dart          # portrait 인라인 HUD 표면
    adaptive_hud_drive_overlay_sections.dart        # landscape 오버레이 HUD 섹션
    adaptive_hud_drive_overlay_surface.dart         # landscape 오버레이 HUD 표면
    adaptive_hud_home_preview_surface.dart          # 홈 프리뷰 HUD 표면
    adaptive_hud_home_sections.dart                 # 홈 HUD 섹션
    adaptive_hud_primitives.dart                    # 공용 UI 원시 컴포넌트
    hud_controller_builder.dart                     # builder 패턴 위젯
```

### Drive Screen (`lib/screens/drive/`)

```
live_drive_canvas_screen.dart                      # 메인 (enum, state 선언, ~450줄)
live_drive_canvas_sidecar_components.dart           # SharedRuntimeManager 연결
live_drive_canvas_sidecar_bootstrap_components.dart # 최초 deploy/revision 검증
live_drive_canvas_sidecar_runtime_components.dart   # 복구, quality, flavor hint
live_drive_canvas_sidecar_transport_components.dart # HTTP 클라이언트
live_drive_canvas_overlay_components.dart           # CustomPainter (3D→2D)
live_drive_canvas_overlay_models_components.dart    # _DriveOverlaySnapshot
live_drive_canvas_overlay_sync_components.dart      # 프레임 동기화
live_drive_canvas_overlay_math_components.dart      # 행렬 연산 (_M3)
live_drive_canvas_camera_components.dart            # 네이티브 카메라 attach
live_drive_canvas_camera_html_components.dart       # WebView 폴백
live_drive_canvas_camera_diag_components.dart       # 카메라 진단
live_drive_canvas_hud_components.dart               # HUD 패널 배치
live_drive_canvas_lifecycle_components.dart         # foreground/background
live_drive_canvas_yolo_components.dart              # YOLO 오버레이
live_drive_canvas_layout_components.dart            # adaptive layout
live_drive_canvas_dev_playback_components.dart      # 개발자 재생
live_drive_canvas_diag_logging_components.dart      # 진단 로그
live_drive_canvas_plot_components.dart              # 디버그 플롯
live_drive_canvas_plot_models_components.dart       # 플롯 모델
live_drive_canvas_settings_popup_components.dart    # 설정 팝업
```

### Services (`lib/services/`)

```
sidecar_service.dart                               # 원격 Python 프로세스 관리 (~1200줄)
hud_drive_settings_service.dart                    # 주행 모드 설정
hud_feature_settings_service.dart                  # HUD/Stock 기능 on/off
native_overlay_hud_service.dart                    # Android 오버레이 (비활성화)
hud_install_progress_service.dart                  # 설치 진행 상태
ssh_service.dart                                   # SSH 연결/명령
```
