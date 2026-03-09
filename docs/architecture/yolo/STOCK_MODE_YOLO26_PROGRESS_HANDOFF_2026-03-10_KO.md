# CarrotLink Stock Mode YOLO26 진행상황 / Handoff (2026-03-10)

최종 분석일: 2026-03-10  
최종 업데이트: 2026-03-10  
대상 경로: `E:\CarrotLink\CarrotLink`

이 문서는 다음 PC에서 YOLO 작업을 바로 이어갈 수 있도록, 현재 구현 상태, 파일 구조, 동작 원리, 남은 작업을 한 번에 정리한 handoff 문서다.

관련 문서:

- `STOCK_MODE_YOLO26_OBJECT_DETECTION_FEASIBILITY_2026-03-10_KO.md`
- `STOCK_MODE_YOLO26_INTEGRATION_PLAN_2026-03-10_KO.md`

## 1. 현재 한 일과 남은 일

현재 진행률은 아래처럼 보는 게 맞다.

- 기반 공사 기준: 약 `45~50%`
- 실제 객체가 검출돼 화면에 자연스럽게 뜨는 완성 기능 기준: 약 `25~30%`

완료:

- YOLO 전용 문서 카테고리 생성
- `HUD debug` 내부 YOLO 토글 추가
- Flutter debug 상태 저장/복원
- Flutter -> Android native `updateYoloConfig` control channel 추가
- Android native video view 내부 `YOLO controller / runtime / frame / pixel sampler` 골격 추가
- 디코드 완료 프레임 기준 `frameId`, `ptsUs`, `source size` 전달
- `yolo_config`, `yolo_state` 이벤트 emit / fetch 추가
- `SurfaceView -> PixelCopy -> 저해상도 bitmap` POC pixel path 추가
- debug snapshot에서 native YOLO 상태 확인 가능

미완료:

- 실제 ExecuTorch Android 의존성 연결
- Qualcomm backend/QNN 패키징 경로 확정
- `.pte` 모델 asset 배치 및 로더
- bitmap -> tensor 전처리
- 실제 inference 실행
- detection output parsing
- detection payload 설계
- source pixel -> stock canvas 실제 box draw
- tracking / Kalman / confidence hysteresis / fade
- traffic light state stabilization
- 기기 벤치 / thermal gating / n-s 모델 선택

## 2. 목적과 범위

목적:

- sidecar를 수정하지 않고
- stock 주행모드에서 sidecar가 보내는 원격 카메라 화면 위에
- YOLO26 기반 객체감지를 얹는다.

핵심 원칙:

- sidecar는 그대로 둔다.
- 1차는 `road` 카메라 우선이다.
- 1차 모델은 `YOLO26n`이다.
- 런타임 목표는 `ExecuTorch + QNN backend`다.
- 1차는 `30fps full inference`가 아니라 `5~10Hz detect + 부드러운 overlay`다.
- 좌표계는 1차에서 `3D world projection`이 아니라 `2D source pixel -> placed canvas` 기준이다.

## 3. 현재 파일 구조와 역할

### 3.1 문서

- `docs/architecture/yolo/STOCK_MODE_YOLO26_OBJECT_DETECTION_FEASIBILITY_2026-03-10_KO.md`
  - 도입 가능성, 타깃 기기, 런타임 선택 근거
- `docs/architecture/yolo/STOCK_MODE_YOLO26_INTEGRATION_PLAN_2026-03-10_KO.md`
  - 구현 원칙, 좌표계, 토글 정책, smoothing 방향
- `docs/architecture/yolo/STOCK_MODE_YOLO26_PROGRESS_HANDOFF_2026-03-10_KO.md`
  - 현재 코드 상태와 TODO handoff

### 3.2 Flutter 쪽

- `lib/features/yolo/yolo.dart`
  - YOLO feature barrel export
- `lib/features/yolo/domain/entities/yolo_runtime_backend.dart`
  - 런타임 후보 enum
- `lib/features/yolo/presentation/models/yolo_debug_settings.dart`
  - debug 토글 모델

- `lib/screens/drive/live_drive_canvas_screen.dart`
  - YOLO debug state 보관
- `lib/screens/drive/live_drive_canvas_debug_popup_components.dart`
  - `YOLO Enabled / Boxes / Labels / TrafficLight / Stats` 토글 UI
- `lib/screens/drive/live_drive_canvas_overlay_sync_components.dart`
  - 토글 load/save
  - native YOLO config payload 생성
  - `updateYoloConfig` 전송
- `lib/screens/drive/live_drive_canvas_hud_components.dart`
  - native camera view 생성 시 YOLO config 초기 push
- `lib/screens/drive/live_drive_canvas_camera_components.dart`
  - native `yolo_config`, `yolo_state` 이벤트 수신
- `lib/screens/drive/live_drive_canvas_debug_actions_components.dart`
  - debug snapshot에 nativeYolo 요약 추가

### 3.3 Android native 쪽

- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveVideoPlugin.kt`
  - 카메라 디코드와 overlay의 메인 엔트리
  - YOLO control method / state fetch / frame feed 연결 지점
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveYoloConfig.kt`
  - YOLO config payload 파싱
  - `inputWidth`, `inputHeight`, `samplePeriodMs` 포함
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveYoloFrame.kt`
  - 디코드 완료 프레임 메타
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveYoloController.kt`
  - 프레임 샘플링 정책
  - pixel sampler + runtime orchestration
  - `yolo_state` snapshot 합성
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveYoloPixelSampler.kt`
  - `SurfaceView -> PixelCopy -> bitmap` 샘플 경로
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveYoloRuntime.kt`
  - 런타임 인터페이스
  - 현재는 `NativeDriveYoloStubRuntime`

## 4. 현재 동작 원리

현재 코드 기준 제어 흐름은 이렇다.

1. 사용자가 stock drive debug popup에서 YOLO 토글을 바꾼다.
2. Flutter가 `YoloDebugSettings`를 `SharedPreferences`에 저장한다.
3. Flutter가 native control channel로 `updateYoloConfig(viewId, yoloConfig)`를 보낸다.
4. `NativeDriveVideoView`가 config를 파싱해 `NativeDriveYoloController`와 overlay view에 전달한다.
5. native 디코더가 프레임을 렌더링할 때 `frameId`, `ptsUs`, `sourceWidth`, `sourceHeight`를 controller에 넘긴다.
6. controller는 `samplePeriodMs` 기준으로 샘플링 여부를 결정한다.
7. 샘플 대상이면 `NativeDriveYoloPixelSampler`가 `SurfaceView`에서 `PixelCopy`로 저해상도 bitmap을 만든다.
8. bitmap이 준비되면 현재는 stub runtime이 `pixelFramesConsumed`만 올리고, `stage=awaiting_executorch_session` 상태를 낸다.
9. 이 상태는 `yolo_state` 이벤트와 `getYoloState` method로 Flutter에서 확인할 수 있다.

즉 현재는 `디코드 프레임 -> 샘플링 -> pixel path ready`까지 들어간 상태고, 실제 추론만 아직 빠져 있다.

## 5. 중요한 구현 원칙

### 5.1 sidecar는 건드리지 않는다

- sidecar는 지금처럼 `ws/live`, `ws/hud`, `ws/camera/*`만 제공한다.
- 객체감지는 앱 내부에서만 처리한다.

### 5.2 frame sync 기준은 기존 `frameId`를 재사용한다

- detection 결과도 최종적으로는 `camera_frame` 기준 `frameId`에 맞춰야 한다.
- 현재 native controller도 rendered frame 시점의 `frameId`를 그대로 쓴다.

### 5.3 1차 좌표계는 `source pixel -> placed canvas`

- 1차 object detection은 `mapToScreen()` 계열 3D 투영을 직접 쓰지 않는다.
- 먼저 detection box를 source pixel로 복원하고,
- 그다음 stock 모드 video placement와 같은 규칙으로 canvas에 맵핑해야 한다.

### 5.4 `PixelCopy`는 POC용 경로다

- 장점:
  - 현재 `MediaCodec -> SurfaceView` 구조를 거의 안 깨고 pixel path를 열 수 있다.
  - 다음 단계 실험 속도가 빠르다.
- 한계:
  - 복사 비용과 latency가 있다.
  - 장기 최종형으로 고정할지는 미정이다.
- 결론:
  - 지금은 POC에 적합
  - 추후 더 직접적인 decoder pixel path가 가능하면 대체 후보

## 6. 현재 blocker

가장 큰 blocker는 아래 순서다.

1. ExecuTorch Android 런타임을 실제로 프로젝트에 넣지 않았다.
2. Qualcomm backend / QNN 경로를 앱 패키징에 어떻게 싣는지 확정하지 않았다.
3. `.pte` 모델 asset이 없다.
4. bitmap을 tensor로 바꾸는 전처리 코드가 없다.
5. output parser / detection payload / mapper / painter가 아직 없다.

즉 지금 상태는 “추론 전에 필요한 기반 공사”까지는 됐지만, “모델이 실제로 돈다”는 단계는 아니다.

## 7. 다음 PC에서 바로 확인할 항목

작업 시작 전에 아래를 확인하면 된다.

1. branch가 `dev_yolo`인지 확인
2. `docs/architecture/yolo/` 아래 3개 문서를 먼저 읽기
3. 아래 검증 명령으로 코드 상태 확인

검증 명령:

```powershell
dart analyze lib/features/yolo/yolo.dart `
  lib/features/yolo/presentation/models/yolo_debug_settings.dart `
  lib/screens/drive/live_drive_canvas_screen.dart `
  lib/screens/drive/live_drive_canvas_overlay_sync_components.dart `
  lib/screens/drive/live_drive_canvas_hud_components.dart `
  lib/screens/drive/live_drive_canvas_camera_components.dart `
  lib/screens/drive/live_drive_canvas_debug_actions_components.dart
```

```powershell
cd android
./gradlew.bat :app:compileDebugKotlin
```

실기기에서 보면 좋은 debug 포인트:

- YOLO 토글 ON 후 `nativeYolo=` 요약이 `pixelReady=true`로 바뀌는지
- `copySuccesses`가 증가하는지
- `stage`가 `awaiting_executorch_session`으로 바뀌는지

## 8. 다음 작업 TODO

우선순위 순서로 적는다.

### TODO-1. ExecuTorch Android 의존성/패키징 확정

- `android/app/build.gradle.kts`에 ExecuTorch 경로 추가
- 개발용과 Qualcomm backend 경로를 구분
- 가능하면 아래 두 단계로 나눈다
  - 1단계: API 검증용 기본 runtime
  - 2단계: Qualcomm backend/QNN path

완료 기준:

- app이 ExecuTorch API를 import해서 compile 가능

### TODO-2. 모델 asset 경로와 로더 추가

- `.pte` 모델을 어디에 둘지 결정
- Flutter asset 또는 native asset 경로 정리
- native에서 model file path를 안전하게 얻는 helper 추가

완료 기준:

- native runtime이 model file 존재 여부를 상태로 보고할 수 있음

### TODO-3. stub runtime을 ExecuTorch runtime으로 교체

- `NativeDriveYoloRuntime` 구현체 추가
- config update 시 세션 생성/해제 규칙 정리
- `runtimeReady`, `blocker`, `stage`를 실제 값으로 갱신

완료 기준:

- `yolo_state`에서 `executorch_session_missing` 대신 실제 세션 상태가 보임

### TODO-4. bitmap 전처리

- `Bitmap -> Float/UInt8 tensor` 경로 추가
- resize/normalize/channel order 확정
- `YOLO26n` export 형태와 맞추기

완료 기준:

- 샘플된 bitmap이 실제 model input tensor로 바뀜

### TODO-5. output parser / detection payload spec

- model output tensor shape를 기준으로 parser 작성
- class id, score, xyxy payload 설계
- 최소 payload는 아래 정도
  - `frameId`
  - `classId`
  - `label`
  - `score`
  - `x1,y1,x2,y2`
  - optional `trackId`

완료 기준:

- frameId 붙은 detection list가 native state 또는 channel로 나옴

### TODO-6. stock 좌표 매핑과 draw

- detection box를 source pixel 기준으로 복원
- stock `_buildVideoPlacement`와 같은 규칙으로 canvas에 투영
- `crop / fit / zoomOut` 세 모드에서 정합 확인

완료 기준:

- 실제 화면에 detection box가 뜨고 세 배율에서 크게 어긋나지 않음

### TODO-7. tracking / smoothing / traffic light stabilization

- IoU + motion 기반 tracking
- Kalman / constant velocity smoothing
- confidence hysteresis
- loss retention / fade-out
- traffic light color state smoothing

완료 기준:

- 박스가 과하게 깜빡이지 않음
- 신호등 state가 너무 늦지도, 너무 튀지도 않음

### TODO-8. 벤치 / 기기 gating / n-s 선택

- `S22 Ultra / S23 Ultra / S24 Ultra` 기준 latency 측정
- thermal/jank 관찰
- `YOLO26n` 기본
- `YOLO26s`는 통과 기기에서만 노출

완료 기준:

- 기기별 enable/disable 정책이 문서와 코드로 고정됨

## 9. 주의사항

- 현재 codebase는 YOLO 관련 변경이 `dev`에 아직 들어간 게 아니라 별도 snapshot 작업 중인 상태다.
- 다음 PC에서는 `dev_yolo` 브랜치에서 이어서 작업하는 게 맞다.
- `PixelCopy` 경로는 POC용이므로, 여기서 성능이 안 좋아도 전체 구조가 틀렸다고 보진 않는다.
- 진짜 어려운 구간은 “모델 로딩”보다 “결과를 stock 좌표계에 자연스럽게 정합시키는 일”이다.

## 10. 한 줄 결론

현재 상태는 `YOLO를 돌릴 준비가 된 native video scaffold + pixel sampling path`까지 왔다. 다음 작업의 본체는 `ExecuTorch session / parser / overlay mapping`이다.
