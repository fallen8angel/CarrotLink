# CarrotLink Stock Mode YOLO26 진행상황 / Handoff (2026-03-16)

최종 분석일: 2026-03-17  
최종 업데이트: 2026-03-17  
대상 경로: `E:\Carrot\CarrotLink`

이 문서는 2026-03-17 기준 YOLO/QNN 작업의 실제 상태, 검증된 사실, 남은 작업, 다음 작업 순서를 빠르게 이어받기 위한 최신 handoff 문서다.

관련 문서:

- `docs/architecture/yolo/STOCK_MODE_YOLO26_OBJECT_DETECTION_FEASIBILITY_2026-03-10_KO.md`
- `docs/architecture/yolo/STOCK_MODE_YOLO26_INTEGRATION_PLAN_2026-03-10_KO.md`
- `docs/architecture/yolo/STOCK_MODE_YOLO26_QNN_BRINGUP_2026-03-15_KO.md`
- `docs/architecture/yolo/STOCK_MODE_YOLO_DEVELOPER_PLAYBACK_2026-03-15_KO.md`

## 1. 한눈에 보는 현재 상태

- generic `ExecuTorch` 경로는 실제 stock/live 및 developer playback에서 계속 사용 가능한 기준선이다.
- 앱 번들에는 이제 아래 QNN-lowered asset과 companion metadata가 실제로 들어간다.
  - `assets/models/yolo26n_qnn.pte`
  - `assets/models/yolo26s_qnn.pte`
  - `assets/models/yolo26n_qnn.metadata.json`
  - `assets/models/yolo26s_qnn.metadata.json`
- Android runtime은 `executorch_qnn`과 `executorch_xnnpack` 두 backend를 모두 가진다.
- 운영 정책은 SoC 기준이다.
  - `Snapdragon Galaxy`: `QNN` 우선
  - 반복 fatal `qnn_*` blocker면 `XNNPACK` 자동 폴백
  - 동일 기기에서 이 실패는 `7일 TTL`로 기억하고, 기간이 지나면 다시 `QNN`을 재시도한다.
  - `Exynos Galaxy`: 현재 앱 기준 `XNNPACK` 기본
- 모델 정책은 계속 `YOLO26n first`, `YOLO26s later`다.
  - 기본 허용 후보 SoC: `SM8550`, `SM8650`, `SM8750`, `Exynos 2400`

## 2. 현재 코드 기준으로 확정된 사실

### 2.1 공통 런타임/정책

- Android device profile을 읽어 backend와 기본 모델을 추천한다.
- `QNN` fatal blocker는 기기 단위로 기억된다.
- `qnn_*` 반복 실패 시 사용자는 즉시 `XNNPACK` 기준선으로 내려가고, 실패 기억은 영구 차단이 아니라 `7일` 뒤 자동 만료된다.

관련 코드:

- `lib/features/yolo/application/yolo_device_profile_service.dart`
- `lib/features/yolo/application/yolo_runtime_policy.dart`
- `lib/features/yolo/application/yolo_runtime_capability_store.dart`

### 2.2 live road camera 경로

아래는 실제 기기 검증으로 확인된 사실이다.

- QNN runtime 파일 패키징 자체는 통과했다.
  - `backendAvailable=true`
  - `backendEnvReady=true`
  - `backendPackagingMode=local_aar`
- 모델과 metadata도 실제로 잡힌다.
  - `modelPath`
  - `modelMetadataPath`
  - `modelMetadataQnnSdkVersion`
- 현재 live 기기 실검증 기준 최종 blocker는 `qnn_dsp_transport_failed`다.
- 즉 문제는 더 이상 `모델 파일 없음`, `metadata 없음`, `QNN bridge 누락`이 아니라 `QnnDsp transport / skel load` 계층으로 좁혀졌다.

실무 해석:

- live QNN 경로는 `Module.load()`까진 지나고, 실제 `forward()` 시점에서 DSP device handle을 여는 단계가 막히는 케이스가 핵심이다.
- 이 상태에선 `executorch_qnn`을 실사용 기본값으로 강제하면 안 되고, 운영은 자동 폴백 정책을 전제로 가져가야 한다.

관련 코드:

- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveExecuTorchRuntime.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveQnnRuntimeFiles.kt`

### 2.3 developer playback 경로

developer playback은 이제 아래 상태까지 올라온다.

- 실제 session state에 `syncSource=developer_playback`이 남는다.
- 실제 session mode에 `sessionMode=video_playback`이 남는다.
- route 영상 재생 중 native tick은 실제로 `runYoloDebugVideoFrame(...)` 경로까지 들어간다.

2026-03-17 기준 playback 쪽 최신 보정:

- developer playback 초기화 완료 뒤 `_cameraLoading`도 같이 내려서, 영상은 이미 보이는데 가운데 원형 로딩이 남는 stale overlay 문제를 줄였다.
- offline route playback의 첫 QNN `Module.load()`는 live 경로와 최대한 비슷하게, main thread에서 한 번 warm-up 하도록 보정했다.
- `module_load_failed`가 다시 나면 `lastError`에 예외 클래스와 cause까지 같이 남겨서 원인 분리가 더 쉬워졌다.

현재 playback에서 확인해야 할 대표 blocker:

- `executorch_module_load_failed`
- `qnn_model_metadata_missing`
- `qnn_model_variant_mismatch`
- `qnn_sdk_version_mismatch`
- `qnn_dsp_transport_failed`

관련 코드:

- `lib/screens/drive/live_drive_canvas_dev_playback_components.dart`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveVideoPlugin.kt`
- `lib/widgets/dashcam_player_screen.dart`

## 3. 지금 남아 있는 본질적 문제

### 3.1 live QNN

- 실기기 QNN live 경로의 핵심 미해결은 `qnn_dsp_transport_failed`다.
- 현재까지 좁혀진 원인은 `QnnDsp transport / skel load` 계층이다.
- 즉 앱 내부 model lookup/metadata/package 단계는 대부분 지나갔고, 남은 건 DSP bring-up 정합이다.

### 3.2 developer playback QNN

- playback에서는 live와 다른 timing/thread 조합 때문에 `Module.load()` 단계에서 먼저 막힐 수 있다.
- 현재는 first warm-up을 main thread로 옮겨 live와 최대한 맞췄지만, 이 경로는 여전히 검증 중이다.
- route replay에서 또 실패하면 우선 `stage`, `blocker`, `lastError`를 먼저 본다.

## 4. 운영 원칙

- 기본 사용자 경험은 `YOLO26n` 기준으로 맞춘다.
- `YOLO26s`는 상위 SoC에서만 기본 허용 후보로 본다.
- `QNN`은 Snapdragon에서만 1차 후보로 본다.
- `QNN`은 반복 fatal blocker가 확인되면 자동으로 `XNNPACK`으로 내려간다.
- 이 자동 강등은 영구 고정이 아니라, 같은 기기에서 `7일` 뒤 다시 `QNN`을 재시도한다.
- Exynos는 현재 앱 기준 `XNNPACK` 기본이다.

## 5. 다음 작업 우선순위

1. live QNN 실기기에서 `qnn_dsp_transport_failed`를 앱 밖 최소 QNN init과 분리 검증
2. developer playback에서 `executorch_module_load_failed`가 다시 나는지, main-thread warm-up 보정 후 재확인
3. QNN 성공 기기와 실패 기기의 상태 JSON 샘플 축적
4. `YOLO26s` 노출 기준을 실제 벤치 결과로 더 구체화

## 6. 빠른 확인 포인트

재개 시 아래만 먼저 보면 된다.

- 정책
  - `lib/features/yolo/application/yolo_runtime_policy.dart`
  - `lib/features/yolo/application/yolo_runtime_capability_store.dart`
  - `lib/features/yolo/application/yolo_device_profile_service.dart`
- 모델/variant
  - `lib/features/yolo/domain/entities/yolo_model_variant.dart`
  - `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveYoloModelCatalog.kt`
- live runtime
  - `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveExecuTorchRuntime.kt`
  - `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveQnnRuntimeFiles.kt`
- developer playback
  - `lib/screens/drive/live_drive_canvas_dev_playback_components.dart`
  - `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveVideoPlugin.kt`
  - `lib/widgets/dashcam_player_screen.dart`

## 7. 요약

현재 기준 요약은 아래 한 줄이면 충분하다.

- generic `ExecuTorch/XNNPACK`은 기준선으로 성립했다.
- QNN-lowered model/metadata/package는 앱에 실제로 들어갔다.
- live QNN의 본질적 blocker는 `qnn_dsp_transport_failed`다.
- developer playback QNN은 `module_load_failed` 가능성이 남아 있어 별도 검증 중이다.
- 운영 정책은 이미 `Snapdragon=QNN 우선, 실패 시 XNNPACK`, `Exynos=XNNPACK 기본`으로 보정됐다.
