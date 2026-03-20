# Stock 주행 카메라/그래픽 전달 구조 및 `frameId` 분석

작성일: 2026-03-20  
대상: CarrotLink 앱 기준 Stock 주행 모드 (`c3/c4` 원본 수정 없음)

## 목적

이 문서는 아래를 정리한다.

- 콤마에서 CarrotLink로 **로드카메라**와 **그래픽 요소**가 어떤 경로로 전달되는지
- 실제 사용 로그 기준으로 **어느 경계에서 문제가 생기는지**
- 현재 기준으로 가장 큰 이슈인 **`frameId = null`** 의 위치

## 요약

- **로드카메라 영상**은 `ws://<host>:7766/ws/camera/road` 로 온다.
  - 전송은 `WebSocket + custom binary packet(meta JSON + H264 payload)` 구조다.
- **그래픽 요소(path/lane/lead 등)** 는 `ws://<host>:7766/ws/live` 로 온다.
  - 전송은 `WebSocket + msgpack/json` 이다.
- **HUD 텍스트/상태** 는 `ws://<host>:7766/ws/hud` 를 우선 사용하고, 필요 시 `ws://<host>:7000/ws/carstate` 를 fallback 으로 쓴다.
- 최근 `c4` 로그 기준으로 **그래픽 데이터 생성 자체가 안 되는 것은 아니다.**
  - `/ws/live` 는 대체로 생성/전달되고 있다.
  - 더 큰 문제는 `/ws/camera/road` 와 `frameId` 경로다.
- `frameId = null` 은 현재 로그상 **native parse 문제가 아니라, sidecar camera relay producer가 받는 raw frame 객체 단계부터 비어 있는 상태**로 보는 것이 가장 타당하다.

---

## 1. 실제 전달 경로

### 1-1. 로드카메라

경로:

- `ws://<host>:7766/ws/camera/road`

구성:

1. sidecar 가 콤마 내부 messaging 에서 camera encode stream 을 구독한다.
   - `livestreamRoadEncodeData`
   - `roadEncodeData`
2. sidecar 가 frame 을 packet 으로 포장한다.
   - `4-byte big-endian meta length`
   - `meta JSON`
   - `H264 payload`
3. 안드로이드 native 가 websocket packet 을 받아 `MediaCodec` 으로 디코드한다.
4. 디코드 완료 후 `camera_frame` 이벤트를 앱 내부에 올린다.

관련 코드:

- [E:\Carrot\CarrotLink\assets\sidecar\sidecar.py](E:/Carrot/CarrotLink/assets/sidecar/sidecar.py)
- [E:\Carrot\CarrotLink\android\app\src\main\kotlin\com\example\carrot_pilot_manager\NativeDriveVideoPlugin.kt](E:/Carrot/CarrotLink/android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveVideoPlugin.kt)

### 1-2. 그래픽 요소

경로:

- `ws://<host>:7766/ws/live`

구성:

1. sidecar 가 `SubMaster` 로 그래픽용 서비스를 읽는다.
   - `modelV2`
   - `liveCalibration`
   - `roadCameraState`
   - `wideRoadCameraState`
   - `carState`
   - `controlsState`
   - profile 에 따라 일부 추가
2. sidecar 가 `live payload` 를 만든다.
3. websocket 으로 브로드캐스트한다.
   - 인코딩: `json`, `zlib-json`, `msgpack`
4. CarrotLink 는 주로 `msgpack` 으로 받는다.
5. Flutter 에서 snapshot 을 만든 뒤 native overlay view 로 `updateOverlay(...)` 한다.

관련 코드:

- [E:\Carrot\CarrotLink\assets\sidecar\sidecar.py](E:/Carrot/CarrotLink/assets/sidecar/sidecar.py)
- [E:\Carrot\CarrotLink\lib\screens\drive\live_drive_canvas_sidecar_runtime_components.dart](E:/Carrot/CarrotLink/lib/screens/drive/live_drive_canvas_sidecar_runtime_components.dart)
- [E:\Carrot\CarrotLink\android\app\src\main\kotlin\com\example\carrot_pilot_manager\NativeDriveVideoPlugin.kt](E:/Carrot/CarrotLink/android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveVideoPlugin.kt)

### 1-3. HUD

경로:

- 우선: `ws://<host>:7766/ws/hud`
- fallback: `ws://<host>:7000/ws/carstate`

관련 코드:

- [E:\Carrot\CarrotLink\assets\sidecar\sidecar.py](E:/Carrot/CarrotLink/assets/sidecar/sidecar.py)
- [E:\Carrot\CarrotLink\android\app\src\main\kotlin\com\example\carrot_pilot_manager\OverlayHudSocketClient.kt](E:/Carrot/CarrotLink/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudSocketClient.kt)

---

## 2. 최근 로그 기준 결론

대상 로그:

- [E:\Carrot\logs\drive_diag_export_20260320_070447.json](E:/Carrot/logs/drive_diag_export_20260320_070447.json)
- [E:\Carrot\logs\drive_diag_export_20260320_070618.json](E:/Carrot/logs/drive_diag_export_20260320_070618.json)
- [E:\Carrot\logs\drive_diag_export_20260320_071027.json](E:/Carrot/logs/drive_diag_export_20260320_071027.json)
- [E:\Carrot\logs\camera_error_20260320_070956_561.log](E:/Carrot/logs/camera_error_20260320_070956_561.log)

### 2-1. `/ws/live` 가 안 만들어지는 것은 아님

정상 구간 로그에서는:

- `profile = p2c4`
- `sidecar.connected = true`
- `overlay.staleActive = false`
- `lastPublishedModelFrameId` 증가
- `modelV2`, `roadCameraState`, `controlsState` fresh

즉 **그래픽 payload 생성/전달은 대체로 정상**이다.

### 2-2. 사용자가 말한 “그래픽이 죽었다”는 실제 카메라 경로 장애와 맞는다

장애 구간 로그에서는:

- `socket_failure`
- `Connection refused`
- `cameraReady = false`
- `cameraRelay.road.frames = 0`
- `cameraRelay.road.service = ""`
- native 쪽 `packetsWindow = 0`, `decodedWindow = 0`, `codecConfigured = false`

즉 이 구간은 **실제로 `/ws/camera/road` 또는 그 내부 relay 경로가 멈춘 상태**로 보는 것이 맞다.

---

## 3. `frameId = null` 분석

현재 로그는 아래 4개를 함께 남긴다.

1. `roadCameraState.frameId`
2. `cameraRelay.road.rawFrame`
3. `cameraRelay.road.packedMeta`
4. `nativeCameraDiag.parsedFrameIdRaw`

최근 `c4` 로그에서 관찰된 패턴:

- `roadCameraState.frameId` 는 존재
- `cameraRelay.road.rawFrame.frameId = null`
- `cameraRelay.road.packedMeta.frameId = null`
- `nativeCameraDiag.parsedFrameIdRaw = null`

이 조합은 다음 의미를 가진다.

> `frameId` 는 native parse 단계에서 잃는 것이 아니라,  
> **sidecar relay producer 가 받은 raw frame 객체 단계부터 이미 비어 있다.**

즉 현재 가장 유력한 위치는:

- `camera relay producer input frame`

이지,

- websocket packet parse
- native JSON parse

가 아니다.

---

## 4. 왜 로그 수집을 추가했는가

이전 로그는 선택된 service 하나의 결과만 남겨서, 아래를 구분할 수 없었다.

- `livestreamRoadEncodeData` 만 `frameId = null` 인지
- `roadEncodeData` 도 같이 `null` 인지

그래서 현재는 후보 서비스별 raw 샘플도 남긴다.

추가된 필드:

- `sidecar.cameraRelay.road.serviceSamples.livestreamRoadEncodeData`
- `sidecar.cameraRelay.road.serviceSamples.roadEncodeData`

각각 포함:

- `frames`
- `lastFrameId`
- `nullFrameIdCount`
- `lastFrameAgeMs`
- `rawFrame`

### 해석 방법

#### 케이스 A

- `livestreamRoadEncodeData.rawFrame.frameId = null`
- `roadEncodeData.rawFrame.frameId >= 0`

의미:

> stable 모드에서 선택되는 livestream 쪽만 문제일 가능성이 크다.

#### 케이스 B

- `livestreamRoadEncodeData.rawFrame.frameId = null`
- `roadEncodeData.rawFrame.frameId = null`

의미:

> encode stream 원본 frame 객체 단계에서 공통적으로 frameId 가 비는 쪽이 더 유력하다.

---

## 5. 현재 판단

현재 구조상 가장 큰 이슈는 두 가지다.

1. **camera relay producer 에서 raw `frameId` 가 비는 문제**
2. **간헐적인 `7766` 카메라 relay outage / attach 실패**

반대로, 최근 로그 기준으로 **`/ws/live` 그래픽 생성 자체가 죽는 문제는 1순위가 아니다.**

---

## 6. 다음 로그에서 우선 볼 항목

다음 공유 로그에서는 아래만 먼저 보면 된다.

- `sidecar.cameraRelay.road.serviceSamples.livestreamRoadEncodeData`
- `sidecar.cameraRelay.road.serviceSamples.roadEncodeData`
- `sidecar.cameraRelay.road.rawFrame`
- `sidecar.cameraRelay.road.packedMeta`
- `nativeCameraDiag.parsedFrameIdRaw`
- `sidecar.frameIdRootCauseHint`

이 6개면 `frameId` 가:

- 선택 service 만 문제인지
- 전체 encode frame 원본 문제인지
- packet packing 문제인지

를 더 직접적으로 가를 수 있다.

---

## 결론

> 현재 CarrotLink Stock 주행 경로는  
> **카메라(`ws/camera`) / 그래픽(`ws/live`) / HUD(`ws/hud`)가 분리된 구조**이고,  
> 최근 `c4` 로그 기준으로는 **그래픽 생성 자체보다 카메라 relay와 `frameId` 경계가 더 핵심 문제**다.

> 특히 `frameId = null` 은 현재까지의 로그상  
> **sidecar relay producer 가 받는 raw frame 객체 단계에서 이미 비어 있는 쪽**으로 해석하는 것이 가장 타당하다.
