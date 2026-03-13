# CarrotLink Producer/Consumer Map (2026-03-11)

## 목적
- `road 영상 producer`, `그래픽 producer`, `HUD producer`, `app consumer`를 CarrotLink 기준으로 한 문서에서 바로 대응시킨다.
- 증상이 `영상만 나옴`, `그래픽만 비음`, `HUD 값만 비음`, `webrtc만 이상함`일 때 어디부터 봐야 하는지 빠르게 좁힌다.
- `D:\CarrotLink\c3-v10-wip` 원본 producer와 `D:\CarrotLink\CarrotLink-dev` side-load/app consumer 구조를 같은 표에 고정한다.

## 한 줄 요약
- 원본 openpilot는 `영상`, `그래픽용 상태`, `HUD 의미`를 각각 다른 계층에서 만든다.
- CarrotLink는 그걸 대체하지 않고 읽어와 다시 정합해서 그린다.
- 최종 권장 구조는 `camera relay + single data broker`다.

## 기준 저장소
- 원본: `D:\CarrotLink\c3-v10-wip`
- 앱: `D:\CarrotLink\CarrotLink-dev`
- 분석일: 2026-03-11

## 1. 1:1 매핑 표

| 구분 | 원본 producer | 원본 핵심 파일 | CarrotLink relay | 앱 consumer | 비고 |
| --- | --- | --- | --- | --- | --- |
| Road 영상, native/UI 원형 | `camerad` + VisionIPC | `selfdrive/ui/qt/widgets/cameraview.cc`, `selfdrive/ui/qt/onroad/annotated_camera.cc` | `assets/sidecar/camera.py` | `NativeDriveVideoPlugin.kt`, `live_drive_canvas_camera_components.dart` | stock mode camera path |
| Road 영상, WebRTC | `livestreamRoadEncodeData` -> WebRTC | `system/webrtc/device/video.py`, `system/webrtc/webrtcd.py` | 없음, 원본 direct | `live_drive_canvas_camera_html_components.dart` | `5001/stream` 사용 |
| 그래픽 상태 producer | `modeld`, `radard`, `calibrationd`, `selfdrived`, `card` | `selfdrive/modeld/modeld.py`, `selfdrive/controls/radard.py`, `selfdrive/locationd/calibrationd.py`, `selfdrive/selfdrived/selfdrived.py`, `selfdrive/car/card.py` | `data broker`, 현재 구현은 `assets/sidecar/sidecar.py` | `live_drive_canvas_overlay_sync_components.dart`, `live_drive_canvas_overlay_components.dart` | `modelV2`, `radarState`, `liveCalibration`, `carState`, `selfdriveState` 중심 |
| 원본 onroad draw 기준 | `carrot.cc` | `selfdrive/ui/carrot.cc` | 직접 relay 없음 | parity 비교 기준만 사용 | 지금 c3-v10의 실제 onroad 기준 |
| HUD 의미 producer | `DrawCarrot::updateState/drawHud`, stock 참고 `hud.cc` | `selfdrive/ui/carrot.cc`, `selfdrive/ui/qt/onroad/hud.cc` | `data broker`의 `hud` stream, 현재 구현은 `assets/sidecar/sidecar.py` owner + `assets/sidecar/hud.py` thin proxy | `lib/features/hud/*`, `adaptive_hud_host.dart` | compatibility 제거만 남음 |
| HUD compatibility | sidecar core compatibility HUD | 없음 | `assets/sidecar/sidecar.py` `/ws/hud` | 유지 중인 compatibility endpoint, 앱 기본 경로에서는 제외됨 | wire cleanup 대상 |
| Optional/diag | openpilot optional state | `deviceState`, `gpsLocation*`, `carrotMan`, `navInstructionCarrot` publisher들 | `data broker`의 `diag` stream, 현재 구현은 `assets/sidecar/sidecar.py` snapshot owner + `assets/sidecar/diag.py` thin server | drive debug/runtime/health UI | 기본 그래픽 source of truth는 아님 |

## 2. Road 영상 producer

### 2.1 원본 openpilot 쪽
- onroad UI 자체는 `AnnotatedCameraWidget::paintEvent(...)`가 카메라 프레임을 먼저 그린다.
- 관련 파일:
  - `selfdrive/ui/qt/widgets/cameraview.cc`
  - `selfdrive/ui/qt/onroad/annotated_camera.cc`

### 2.2 WebRTC 경로
- 원본 encoded road video는 `livestreamRoadEncodeData` 서비스로 나간다.
- WebRTC 쪽 파일:
  - `system/webrtc/device/video.py`
  - `system/webrtc/webrtcd.py`
- 앱은 `webrtc` 모드에서 이 경로를 직접 본다.

### 2.3 CarrotLink stock 모드 경로
- camera relay:
  - `assets/sidecar/camera.py`
  - `assets/sidecar/camera.sh`
- 앱 consumer:
  - `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveVideoPlugin.kt`
  - `lib/screens/drive/live_drive_canvas_camera_components.dart`
  - `lib/screens/drive/live_drive_canvas_camera_html_components.dart`

### 2.4 포트
- WebRTC: `5001`
- stock camera relay: `7768`

주의:
- `camera`는 최종 구조에서도 별도 owner를 유지하는 것이 맞다.
- binary/video transport와 telemetry transport를 합치면 backpressure와 지연 관리가 나빠진다.

## 3. 그래픽 producer

### 3.1 원본 producer 계층
- `modeld.py`
  - `modelV2`, `cameraOdometry`
- `radard.py`
  - `radarState`
- `calibrationd.py`
  - `liveCalibration`
- `card.py`
  - `carState`
- `selfdrived.py`
  - engage/event/state 관리

즉 앱이 path/lane/lead/radar를 다시 그릴 때의 실제 입력은 `carrot.cc`가 아니라, 그 아래 producer service들이다.

### 3.2 원본 draw 기준
- 현재 c3-v10에서 실제 onroad draw 기준은 `selfdrive/ui/carrot.cc`
- `qt/onroad/model.cc`, `qt/onroad/hud.cc`는 참고용 원형 코드다.

### 3.3 CarrotLink relay
- 최종 권장:
  - `single data broker`
- 현재 구현:
  - `assets/sidecar/sidecar.py`
  - `assets/sidecar/sidecar.sh`
- 현재 broker 성격의 sidecar core가 읽는 핵심 서비스 묶음:
  - `carState`
  - `selfdriveState`
  - `controlsState`
  - `longitudinalPlan`
  - `liveCalibration`
  - `modelV2`
  - `radarState`
  - `roadCameraState`
  - `wideRoadCameraState`

### 3.4 앱 consumer
- `lib/screens/drive/live_drive_canvas_overlay_sync_components.dart`
- `lib/screens/drive/live_drive_canvas_overlay_components.dart`
- `lib/screens/drive/live_drive_canvas_screen.dart`

### 3.5 핵심 규칙
- `영상만 보이고 그래픽이 안 보인다`면 아래 셋 중 하나다.
  1. 원본 producer가 `modelV2/liveCalibration/roadCameraState`를 순간 invalid/stale로 냄
  2. `sidecar.py`가 `ws/live` payload를 못 만들거나 늦게 냄
  3. 앱 sync가 strict frame lock으로 그 프레임을 버림

## 4. HUD producer

### 4.1 원본 의미 기준
- 실제 c3-v10 의미 기준:
  - `selfdrive/ui/carrot.cc`
- stock 참고 원형:
  - `selfdrive/ui/qt/onroad/hud.cc`

즉 HUD 값 parity를 볼 때는 `hud.cc`만 보면 안 되고 `carrot.cc`의 `updateState/drawHud` 쪽을 같이 봐야 한다.

### 4.2 CarrotLink relay
- 최종 권장:
  - `data broker`의 `hud` logical stream
- 현재 구현:
  - owner:
    - `assets/sidecar/sidecar.py`
  - dedicated wrapper:
    - `assets/sidecar/hud.py`
    - `assets/sidecar/hud.sh`
  - compatibility HUD path:
    - `assets/sidecar/sidecar.py`

### 4.3 앱 consumer
- `lib/features/hud/data/datasources/hud_remote_stream_data_source.dart`
- `lib/features/hud/data/mappers/hud_remote_payload_mapper.dart`
- `lib/features/hud/data/repositories/hud_repository_impl.dart`
- `lib/features/hud/application/hud_controller.dart`
- `lib/features/hud/presentation/widgets/adaptive_hud_host.dart`
- `lib/features/hud/presentation/models/hud_adaptive_display_model.dart`

### 4.4 포트
- primary HUD relay: `7767`
- compatibility HUD relay: `7766` (`app 기본 경로에서는 제외`, thin proxy/broker migration용)

주의:
- 현재 `7767`과 `7766/ws/hud` 이원화는 과도기 구조다.
- 다만 upstream openpilot 구독 owner는 이미 `sidecar.py` 하나만 남긴 상태다.
- 최종적으로는 wire contract도 하나로 줄이는 것이 맞다.

## 5. app consumer 구조

### 5.1 영상
- native path:
  - `NativeDriveVideoPlugin.kt`
- HTML/WebRTC path:
  - `live_drive_canvas_camera_html_components.dart`

### 5.2 그래픽
- overlay snapshot sync:
  - `live_drive_canvas_overlay_sync_components.dart`
- actual painter / projection:
  - `live_drive_canvas_overlay_components.dart`

### 5.3 HUD
- HUD feature:
  - `lib/features/hud/*`

### 5.4 진단
- runtime transport:
  - `live_drive_canvas_sidecar_transport_components.dart`
  - `live_drive_canvas_sidecar_runtime_components.dart`

## 6. 포트와 역할

| 포트 | 제공자 | 용도 |
| --- | --- | --- |
| `5001` | openpilot WebRTC | webrtc road video |
| `7766` | `sidecar.py` | core live overlay, compatibility HUD, health/profile |
| `7767` | `hud.py` | dedicated HUD semantic stream, 현재는 broker thin proxy |
| `7768` | `camera.py` | stock camera relay |
| `7769` | `diag.py` | optional/debug/diag snapshot server, 현재는 broker snapshot thin server |

추가:
- app websocket client는 이제 `role/session` query를 함께 보낸다.
- 현재 기본 role은 `drive_overlay`, `home_hud`다.

## 7. 증상별 우선 확인 경로

### 7.1 영상은 나오는데 그래픽이 비는 경우
1. `selfdrive/modeld/modeld.py`
2. `selfdrive/locationd/calibrationd.py`
3. `assets/sidecar/sidecar.py`
4. `NativeDriveVideoPlugin.kt`
5. `live_drive_canvas_overlay_sync_components.dart`

### 7.2 HUD 값만 비는 경우
1. `selfdrive/ui/carrot.cc`
2. `assets/sidecar/hud.py`
3. `hud_remote_payload_mapper.dart`
4. `hud_repository_impl.dart`
5. `hud_adaptive_display_model.dart`

### 7.3 webrtc만 이상한 경우
1. `system/webrtc/device/video.py`
2. `system/webrtc/webrtcd.py`
3. `live_drive_canvas_camera_html_components.dart`

## 8. 지금 기준의 source of truth
- road 영상 producer 기준: `cameraview.cc`, `annotated_camera.cc`, `webrtcd.py`, `video.py`
- 그래픽 producer 기준: `modeld.py`, `radard.py`, `calibrationd.py`, `card.py`, `selfdrived.py`
- 원본 draw parity 기준: `carrot.cc`
- HUD 의미 기준: `carrot.cc` + 참고용 `hud.cc`
- 앱 consumer 기준: `sidecar.py`, `camera.py`, `hud.py`, `NativeDriveVideoPlugin.kt`, `live_drive_canvas_overlay_sync_components.dart`, `lib/features/hud/*`

## 9. 현재 코드 재검토 기준 판단

현재 구현은 `camera 분리` 방향은 맞다.

하지만 최종형으로는 아래가 더 맞다.
- `camera.py`는 유지
- `sidecar.py`가 single data broker 역할을 맡음
- `hud.py`, `diag.py`는 openpilot를 다시 직접 구독하지 않고 broker logical stream 또는 thin wrapper로 정리

즉 최종 권장 구조는:
- `camera relay`
- `data broker`
  - `overlay`
  - `hud`
  - `diag`

이 구조가 현재 코드에서 가장 낮은 경합 리스크와 가장 명확한 owner 규칙을 준다.
