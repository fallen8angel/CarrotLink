# STOCK Mode YOLO Developer Playback (2026-03-15)

최종 업데이트: 2026-03-17  
대상 경로: `E:\Carrot\CarrotLink`

이 문서는 stock 주행화면 안에서 route replay를 이용해 YOLO 상태를 개발자 전용으로 검증하는 playback 경로를 정리한다.

## 1. 목적

- `alive` 없이도 stock 주행 화면 안에서 YOLO/QNN 상태와 박스/라벨을 테스트한다.
- live road camera 경로를 망가뜨리지 않고, developer-only playback source를 별도 유지한다.
- 공통으로 재사용하는 것은 stock viewport, zoom preset, YOLO 설정/상태 store, detection overlay다.

## 2. 현재 구조

developer playback은 아래 성격으로 본다.

- source: offline route video
- sync source: `developer_playback`
- session mode: `video_playback`
- tick owner: native playback runner
- 목적: 실사용 기능이 아니라 debug harness

핵심 파일:

- `lib/screens/drive/live_drive_canvas_dev_playback_components.dart`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveVideoPlugin.kt`
- `lib/widgets/dashcam_player_screen.dart`

## 3. 2026-03-17 기준으로 확인된 사실

### 3.1 playback 경로는 실제 native까지 들어간다

- route replay 시작 시 실제 native playback tick이 돈다.
- 상태에는 아래 값이 남는다.
  - `syncSource=developer_playback`
  - `sessionMode=video_playback`
  - `playbackFrameId`
  - `playbackFramePtsUs`
  - `playbackFrameToken`

즉 지금 playback 이슈는 더 이상 "경로 자체가 안 탄다"가 아니라, model/runtime bring-up 단계로 보는 것이 맞다.

### 3.2 상태 배지 해석

현재 playback 우측 상단 배지는 아래 흐름으로 읽으면 된다.

- `모델 파일 없음`
- `QNN 런타임 없음`
- `모델 로드 실패`
- `추론 실패`
- `실행 확인`
- `QNN 검증 완료`

대표적으로:

- `stage=module_load_failed`, `blocker=executorch_module_load_failed`
  - `모델 로드 실패`
- `stage=backend_unavailable`
  - `QNN 런타임 없음`
- `stage=awaiting_detection_payload`, `runtimeReady=true`
  - `실행 확인`
- `stage=overlay_payload_ready`, `runtimeReady=true`
  - `QNN 검증 완료`

## 4. 최신 보정

### 4.1 가운데 원형 로딩 문제

route replay에서 영상은 이미 보이는데 가운데 원형 로딩이 남는 문제는 playback 자체 로더가 아니라 `_cameraLoading` overlay가 stale하게 남는 문제였다.

2026-03-17 보정:

- playback controller 초기화가 끝나면 `_developerPlaybackLoading` 뿐 아니라 `_cameraLoading`도 같이 내린다.
- 즉 영상이 보이기 시작한 뒤 full-screen loading spinner가 계속 남는 경로를 줄였다.

### 4.2 QNN first load 보정

playback에서 `executorch_qnn`을 사용할 때, 첫 `Module.load()` 또는 runtime warm-up이 live보다 다른 thread/timing에서 시작될 수 있었다.

2026-03-17 보정:

- offline playback의 첫 QNN runtime 준비는 `prepareOfflineRuntimeForPlayback(...)`을 통해 main thread에서 한 번 warm-up 하도록 맞췄다.
- 목적은 live bring-up과 초기 조건을 최대한 맞추는 것이다.

### 4.3 오류 메시지 가시성

`module_load_failed`가 다시 발생하면 이제 `lastError`에 예외 클래스와 cause까지 포함되도록 보강했다.

즉 route replay에서 다시 실패하면 우선 아래를 본다.

- `stage`
- `blocker`
- `lastError`

## 5. 현재 한계

- developer playback은 여전히 debug harness다.
- live camera처럼 frame-locked render를 완전히 공유하지는 않는다.
- route replay에서 `executorch_qnn`은 live와 다른 타이밍으로 인해 `Module.load()` 단계에서 먼저 막힐 수 있다.
- live에서 대표 blocker가 `qnn_dsp_transport_failed`라면, playback에서는 `executorch_module_load_failed`가 먼저 보일 수도 있다.

즉 playback의 실패는 live와 완전히 같은 실패 모양을 보장하지 않는다. 다만 현재는 둘의 초기 조건 차이를 줄이는 방향으로 계속 맞추는 중이다.

## 6. 사용 흐름

1. 개발자 모드 활성화
2. stock 화면에서 route 영상 선택
3. `오프라인 재생` 시작
4. 필요 시 `일시정지`로 freeze-frame 디버깅
5. 상태 복사
6. `stage`, `blocker`, `lastError`, detection count 확인

## 7. 지금 문서 기준 판단

- playback은 이제 실제 runtime 진단용으로 쓸 수 있다.
- 다만 `executorch_qnn` playback은 아직 기준선이 아니라 bring-up 확인용이다.
- 안정적인 기준선 비교는 여전히 generic `ExecuTorch/XNNPACK`이 더 적합하다.
