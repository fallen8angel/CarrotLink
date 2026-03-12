# CarrotLink Stock Mode YOLO26 진행상황 / Handoff (2026-03-10)

최종 분석일: 2026-03-10  
최종 업데이트: 2026-03-10  
대상 경로: `D:\CarrotLink\CarrotLink-dev`

이 문서는 다음 PC에서 YOLO 작업을 바로 이어갈 수 있도록, 현재 구현 상태, 파일 구조, 동작 원리, 남은 작업을 한 번에 정리한 handoff 문서다.

관련 문서:

- `STOCK_MODE_YOLO26_OBJECT_DETECTION_FEASIBILITY_2026-03-10_KO.md`
- `STOCK_MODE_YOLO26_INTEGRATION_PLAN_2026-03-10_KO.md`

## 1. 현재 한 일과 남은 일

현재 진행률은 아래처럼 보는 게 맞다.

- 기반 공사 기준: 약 `60~65%`
- 실제 객체가 검출돼 화면에 자연스럽게 뜨는 완성 기능 기준: 약 `35~40%`

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
- `android/app/build.gradle.kts`에 `org.pytorch:executorch-android:1.1.0` 연결
- `NativeDriveExecuTorchRuntime` 추가
- model locator 추가
  - direct file path
  - app/internal/external/tmp path
  - Android/Flutter asset extract path
- app runtime 기본 경로를 stub에서 ExecuTorch loader skeleton으로 전환
- model 미존재 / module load 실패 / preprocess 미구현 상태를 `yolo_state`로 구분 보고
- `frameId=-1`인 road stream에서도 synthetic rendered frame id로 YOLO sampler가 돌도록 보강
- 실제 기기 확인 기준
  - `framesSeen / sampled / copies / pixelReady` 증가 확인
  - `awaiting_model_asset` 상태에서 더 이상 `framesSeen=0`에 머물지 않음
- 로컬 Windows export 환경 정리
  - 전용 venv(`.venv-yolo-export`) 생성
  - `torch 2.9.1 + executorch 1.0.0 + ultralytics 8.3.234` 조합 확인
  - `tools/flatbuffers/flatc.exe` 확보
- `scripts/export_yolo_executorch.py` 추가
  - `yolo26n.pt -> yolo26n.pte` 성공
  - `yolo26s.pt -> yolo26s.pte` 성공
- 현재 앱 패키징 상태
  - `assets/models/yolo26n.pte` 생성 완료
  - `pubspec.yaml`에 `assets/models/yolo26n.pte` 등록 완료
- 실제 inference bring-up 기준
  - `Module.load()` 성공
  - `bitmap -> float tensor(CHW)` 전처리 성공
  - 첫 `forward()` 성공
  - 첫 output shape `[1,84,3549]` 확인
- output parser 1차 골격 추가
  - `[1,84,N]`, `[84,N]`, `[1,N,84]` 계열 shape 파싱
  - confidence filter + class-aware NMS
  - top detection preview를 `yolo_state`로 노출
- pre-YOLO 그래픽 무결성 회귀 보정
  - 기준 커밋: `fda3066` (2026-03-10 YOLO 작업 시작 직전)
  - YOLO용 synthetic frame id가 기존 `camera_frame` sync에 섞이지 않게 분리
  - pending backlog 계산도 visual sync 기준으로 복원

미완료:

- Qualcomm backend/QNN 패키징 경로 확정
- 진짜 Qualcomm/QNN-lowered `.pte` export / load / 기기 검증
- detection payload 설계
- source pixel -> stock canvas 실제 box draw
- tracking / Kalman / confidence hysteresis / fade
- traffic light state stabilization
- 기기 벤치 / thermal gating / n-s 모델 선택

보류/주의:

- 현재 Ultralytics ExecuTorch export는 Python 쪽에서 XNNPACK 기반 `.pte`를 만든다.
- 앱 debug payload는 아직 `runtimeBackend='executorch_qnn'` 문자열을 보내지만, 실제 Android runtime은 아직 QNN delegate를 쓰지 않는다.
- 즉 현재 단계의 `.pte`는 "generic ExecuTorch bring-up + parser bring-up"용으로 보는 게 맞다.
- YOLO가 stale / fail / parser mismatch여도 기존 stock/openpilot 그래픽은 절대 흔들리면 안 된다.

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
  - `NativeDriveYoloStubRuntime`는 fallback / reference용
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveExecuTorchRuntime.kt`
  - ExecuTorch Android `Module.load()` 기반 runtime skeleton
  - model locator / asset extract / blocker 상태 보고

## 4. 현재 동작 원리

현재 코드 기준 제어 흐름은 이렇다.

1. 사용자가 stock drive debug popup에서 YOLO 토글을 바꾼다.
2. Flutter가 `YoloDebugSettings`를 `SharedPreferences`에 저장한다.
3. Flutter가 native control channel로 `updateYoloConfig(viewId, yoloConfig)`를 보낸다.
4. `NativeDriveVideoView`가 config를 파싱해 `NativeDriveYoloController`와 overlay view에 전달한다.
5. native 디코더가 프레임을 렌더링할 때 `frameId`, `ptsUs`, `sourceWidth`, `sourceHeight`를 controller에 넘긴다.
6. controller는 `samplePeriodMs` 기준으로 샘플링 여부를 결정한다.
7. 샘플 대상이면 `NativeDriveYoloPixelSampler`가 `SurfaceView`에서 `PixelCopy`로 저해상도 bitmap을 만든다.
8. bitmap이 준비되면 runtime은 model path를 찾고, 있으면 `Module.load()`를 수행한다.
9. load 성공 후에는 `bitmap -> float tensor(CHW)` 전처리를 수행한다.
10. `forward()` 결과에서 첫 tensor shape/dtype/preview를 추출한다.
11. 현재 parser 골격은 `[1,84,N]` 계열 output을 읽어 top detection preview까지 만든다.
12. 이 상태는 `yolo_state` 이벤트와 `getYoloState` method로 Flutter에서 확인할 수 있다.

즉 현재는 `디코드 프레임 -> 샘플링 -> pixel path -> model load -> preprocess -> forward -> parser preview`까지 들어간 상태고, 실제 stock canvas draw만 아직 빠져 있다.

## 5. 중요한 구현 원칙

### 5.1 sidecar는 건드리지 않는다

- sidecar는 지금처럼 `ws/live`, `ws/hud`, `ws/camera/*`만 제공한다.
- 객체감지는 앱 내부에서만 처리한다.

### 5.2 frame sync 기준은 기존 `frameId`를 재사용한다

- detection 결과도 최종적으로는 `camera_frame` 기준 `frameId`에 맞춰야 한다.
- 현재 native controller는 YOLO sampling용 synthetic id를 내부적으로 쓸 수 있지만,
- 기존 화면 sync용 `camera_frame` 이벤트는 실제 source `frameId`가 있을 때만 유지한다.
- 즉 YOLO 실험 때문에 기존 그래픽 sync 경로를 바꾸지 않는 것이 원칙이다.

### 5.3 그래픽 무결성은 fail-open이다

- 기존 stock/openpilot 그래픽은 항상 authoritative path다.
- YOLO가 느리거나, parser가 비어 있거나, backend가 실패해도 기존 그래픽은 그대로 보여야 한다.
- frame mismatch / stale detection / parser 오류가 나면 detection box만 hide 또는 drop 한다.
- YOLO 때문에 `strictFrameLock` 경로가 흔들리면 그 구현은 잘못된 것으로 본다.

### 5.4 1차 좌표계는 `source pixel -> placed canvas`

- 1차 object detection은 `mapToScreen()` 계열 3D 투영을 직접 쓰지 않는다.
- 먼저 detection box를 source pixel로 복원하고,
- 그다음 stock 모드 video placement와 같은 규칙으로 canvas에 맵핑해야 한다.

### 5.5 `PixelCopy`는 POC용 경로다

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

1. generic ExecuTorch 경로는 열렸지만, 진짜 Qualcomm/QNN lowered runtime 경로는 아직 아니다.
2. output parser는 1차 골격만 있고, draw 가능한 detection payload 계약이 아직 없다.
3. source pixel -> placed canvas box projection과 native overlay draw가 아직 없다.
4. tracking / hysteresis / stale gate가 아직 없다.

즉 지금 상태는 “모델이 실제로 돈다”는 단계는 지났고, “draw-safe parser / projection / overlay” 단계가 현재 blocker다.

## 7. 다음 PC에서 바로 확인할 항목

작업 시작 전에 아래를 확인하면 된다.

1. 현재 작업 branch와 `origin/dev` snapshot 기준이 어디인지 확인
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
- model이 있으면 `forwardSuccesses`가 증가하는지
- 현재는 `stage=awaiting_overlay_projection`, `blocker=overlay_draw_missing`까지 가는지
- `parsedDetectionCount`와 `parsedDetectionsPreview`가 비는지/채워지는지

## 8. 다음 작업 TODO

우선순위 순서로 적는다.

### TODO-1. detection payload 계약 확정

- parser 결과를 런타임 내부 preview 문자열이 아니라 구조화된 detection payload로 만든다
- 최소 필드는 아래로 고정한다
  - `frameId`
  - `classId`
  - `label`
  - `score`
  - `left/top/right/bottom`
- stale 판단에 필요한 timestamp/frame gap도 포함 검토

완료 기준:

- native runtime이 top detection들을 구조 payload로 유지 가능

### TODO-2. source pixel -> placed canvas projection 추가

- 현재 parser box는 `input 416x416` 좌표 기준이다
- 이를 `source pixel`로 복원하고
- stock video placement 규칙으로 `placed canvas`에 맵핑하는 함수를 정한다

완료 기준:

- crop / fit / zoomOut에서 같은 객체가 같은 위치에 자연스럽게 맞음

### TODO-3. native overlay draw 추가

- native overlay layer에 YOLO box / label draw를 추가한다
- 기본 정책은 `yoloEnabled && yoloBoxes`일 때만
- draw는 기존 overlay보다 보수적으로, 충돌 시 YOLO가 양보한다

완료 기준:

- parser 결과가 실제 box로 보이되, 기존 path/lane/lead/radar와 충돌하지 않음

### TODO-4. graphics fail-open / stale gate 추가

- detection frame이 camera/model frame과 너무 벌어지면 box를 drop 한다
- YOLO stale/오류가 발생해도 기존 overlay는 유지한다
- YOLO 때문에 stock 그래픽이 깜박이면 regression으로 간주한다

완료 기준:

- YOLO ON/OFF/실패 상황 모두에서 기존 그래픽은 안정적

### TODO-5. Qualcomm/QNN 실 runtime 경로 확정

- Qualcomm backend/QNN용 export/lowering 경로를 따로 정리한다
- generic ExecuTorch `.pte`와 QNN-lowered `.pte`를 구분한다
- 앱은 지원 기기에서만 QNN을 시도하고, 실패 시 generic path 또는 YOLO off로 fallback 한다

완료 기준:

- 실기기에서 진짜 QNN path 여부를 로그/상태로 구분 가능

### TODO-6. tracking / smoothing / traffic light stabilization

- IoU + motion 기반 tracking
- Kalman / constant velocity smoothing
- confidence hysteresis
- loss retention / fade-out
- traffic light color state smoothing

완료 기준:

- 박스가 과하게 깜빡이지 않음
- 신호등 state가 너무 늦지도, 너무 튀지도 않음

### TODO-7. 벤치 / 기기 gating / n-s 선택

- `S22 Ultra / S23 Ultra / S24 Ultra` 기준 latency 측정
- thermal/jank 관찰
- `YOLO26n` 기본
- `YOLO26s`는 통과 기기에서만 노출

완료 기준:

- 기기별 enable/disable 정책이 문서와 코드로 고정됨

## 9. 주의사항

- YOLO scaffold와 runtime skeleton 변경은 `dev`에도 snapshot이 들어간 상태일 수 있으니, 다음 PC에서는 현재 HEAD와 `origin/dev`를 먼저 확인한다.
- 별도 실험을 크게 벌릴 때만 분기 브랜치를 추가로 따는 게 안전하다.
- `PixelCopy` 경로는 POC용이므로, 여기서 성능이 안 좋아도 전체 구조가 틀렸다고 보진 않는다.
- 진짜 어려운 구간은 “모델 로딩”보다 “결과를 stock 좌표계에 자연스럽게 정합시키는 일”이다.

## 10. 한 줄 결론

현재 상태는 `generic ExecuTorch bring-up + parser preview`까지 왔다. 다음 작업의 본체는 `detection payload / source-to-canvas projection / fail-open draw / QNN path`다.
