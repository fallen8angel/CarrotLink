# CarrotLink Stock Mode YOLO26 QNN Bring-up Notes (2026-03-15)

최종 업데이트: 2026-03-17  
대상 경로: `E:\Carrot\CarrotLink`

## 1. 현재 결론

- 앱 쪽 QNN 슬롯 연결은 끝났다.
  - Flutter selector: `yolo26n_qnn`, `yolo26s_qnn`
  - native model catalog도 같은 이름으로 lookup 한다.
- 앱 번들에는 실제 QNN-lowered model과 companion metadata가 들어간다.
  - `assets/models/yolo26n_qnn.pte`
  - `assets/models/yolo26s_qnn.pte`
  - `assets/models/yolo26n_qnn.metadata.json`
  - `assets/models/yolo26s_qnn.metadata.json`
- local AAR + QNN runtime libs + skel assets 패키징 경로는 실제로 동작한다.
- live 기기 기준 현재 본질적 blocker는 `qnn_dsp_transport_failed`다.
- developer playback 쪽은 별도로 `executorch_module_load_failed`가 먼저 보일 수 있다.

즉 현재 QNN bring-up은 "모델/패키징 부재" 단계는 넘었고, "실제 기기 DSP bring-up / playback load 안정화" 단계에 들어와 있다.

## 2. 현재 앱 상태

### 2.1 패키징

현재 앱은 아래 조합을 기준으로 본다.

- `android/app/libs/executorch.aar`
- `libqnn_executorch_backend.so`
- `libQnnHtp.so`
- `libQnnSystem.so`
- `libQnnHtpPrepare.so`
- `libQnnHtpNetRunExtensions.so`
- `libQnnHtpV##Stub.so`
- `libQnnHtpV68Skel.so`
- `libQnnHtpV69Skel.so`
- `libQnnHtpV73Skel.so`
- `libQnnHtpV75Skel.so`
- `libQnnHtpV79Skel.so`

현재 런타임이 보고하는 대표 상태값:

- `backendAvailable`
- `backendReason`
- `backendPackagingMode`
- `backendNativeLibDir`
- `backendNativeLibs`
- `backendAssetFiles`
- `backendRuntimeDir`
- `backendEnvReady`

### 2.2 metadata 정합

QNN-lowered model은 `.pte`만 보는 것이 아니라 companion metadata도 같이 본다.

대표 확인값:

- `modelMetadataPath`
- `modelMetadataOutputName`
- `modelMetadataSoc`
- `modelMetadataQnnSdkVersion`
- `modelMetadataExecutorchRef`
- `modelMetadataOnlinePrepare`

대표 blocker:

- `qnn_model_metadata_missing`
- `qnn_model_metadata_invalid`
- `qnn_model_metadata_incomplete`
- `qnn_model_variant_mismatch`
- `qnn_sdk_version_mismatch`

## 3. 실기기 상태 해석

### 3.1 live road camera

현재 live 기기에서 많이 본 조합은 아래다.

- `backendAvailable=true`
- `backendEnvReady=true`
- `runtimeReady=true`
- 이후 `forward()` 시점에서 `qnn_dsp_transport_failed`

이 상태의 의미:

- 모델 lookup 성공
- metadata lookup 성공
- QNN runtime/skel 환경 준비 성공
- 하지만 DSP device handle 또는 skel load 단계에서 실패

즉 현재 live QNN blocker는 model asset 문제가 아니라 `QnnDsp transport / skel load` 계층이다.

### 3.2 developer playback

route replay에서는 live와 다른 형태의 실패가 먼저 보일 수 있다.

대표 예:

- `stage=module_load_failed`
- `blocker=executorch_module_load_failed`

2026-03-17 보정:

- offline playback 첫 QNN runtime 준비는 `prepareOfflineRuntimeForPlayback(...)`을 통해 main thread에서 한 번 warm-up 한다.
- `lastError`는 예외 클래스와 cause까지 더 직접적으로 남긴다.

즉 playback QNN은 아직 live QNN과 같은 실패 모양을 보장하지 않지만, 현재는 둘의 초기 조건 차이를 줄이는 중이다.

## 4. 운영 정책

- `Snapdragon Galaxy`
  - 1차 시도: `executorch_qnn`
  - 반복 fatal `qnn_*` blocker면 `executorch_xnnpack`으로 자동 폴백
  - 이 실패는 동일 기기에서 `7일 TTL`로 기억하고, 이후 다시 `QNN`을 재시도한다.
- `Exynos Galaxy`
  - 현재 앱 기준 기본 backend는 `executorch_xnnpack`
  - QNN은 대상 backend로 보지 않는다.
- 모델은 계속 `YOLO26n first`, `YOLO26s later`다.

## 5. 현재 단계에서 봐야 할 blocker

우선순위가 높은 blocker는 아래다.

- live bring-up
  - `qnn_dsp_transport_failed`
  - `qnn_delegate_init_failed`
- metadata / export 정합
  - `qnn_model_metadata_missing`
  - `qnn_model_variant_mismatch`
  - `qnn_sdk_version_mismatch`
- playback bring-up
  - `executorch_module_load_failed`

즉 지금은 `qnn_model_not_lowered` 같은 초기 bring-up 이전 단계보다, 실제 runtime 계층 blocker를 더 많이 본다.

## 6. 다음 작업

1. live 기기에서 `qnn_dsp_transport_failed`를 앱 밖 최소 QNN init과 분리 검증
2. developer playback에서 `executorch_module_load_failed` 재현 시 `lastError` 상세 수집
3. 성공/실패 기기별 QNN 상태 JSON 샘플 축적
4. QNN 성공 기기에서만 더 공격적으로 `YOLO26s` 확장 검토
