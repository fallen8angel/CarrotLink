# CarrotLink YOLO 코드 리뷰 (2026-03-17)

현재 코드베이스 기준 실제 코드 수준의 문제와 개선점 정리.
이 문서는 분석 스냅샷이며, 진행 handoff는 `STOCK_MODE_YOLO26_PROGRESS_HANDOFF_2026-03-16_KO.md`를 기준으로 한다.

---

## 1. 현재 진행 중 (uncommitted)

| 파일 | 변경 내용 | 상태 |
|------|-----------|------|
| `NativeDriveExecuTorchRuntime.kt` | `summarizeThrowable()` 추가 — module load 실패 시 cause chain까지 lastError에 기록 | 완료, 미커밋 |
| `NativeDriveVideoPlugin.kt` | `prepareOfflineRuntimeForPlayback()` 추가 — QNN updateConfig()를 main thread에서 실행 (CountDownLatch, 8s timeout) | 완료, 미커밋 |
| `live_drive_canvas_dev_playback_components.dart` | controller 초기화 완료 후 `_cameraLoading = false`, `_cameraError = null` 추가 — stale 로딩 오버레이 방지 | 완료, 미커밋 |

---

## 2. 실제 남은 코드 문제

### 2.1 `forcedRuntimeBackend` 데드코드 — [yolo_offline_debug_runner.dart:29-31]

```dart
if (effective.runtimeBackend == YoloRuntimeBackend.executorchQnn) {
    forcedRuntimeBackend = false;  // 항상 false 할당, 의미 없음
}
```

- `forcedRuntimeBackend`는 `_annotateOfflineSnapshot()`에서 주석 기록용으로만 쓰임
- 실제로 backend를 바꾸거나 설정에 영향을 주는 코드가 없음
- QNN offline playback 시 실제로 어떤 동작을 의도했는지 정의가 필요함
- **영향**: 오해를 유발하는 dead code. 현재는 동작 버그는 아님

### 2.2 sourceSize 하드코딩 3곳 — [yolo_offline_debug_runner.dart:68, 108, 150]

```dart
sourceSize: const Size(1928, 1208),  // 3곳 모두 동일
```

- `runImageFile()`, `runVideoFile()`, `runVideoFrameAtPosition()` 세 곳 모두 동일
- 실제 비디오 해상도가 다르면 detection 좌표계가 틀려짐
- 현재는 comma 기기 road camera가 1928×1208 고정이라 문제 없지만, 다른 영상 테스트 시 오좌표
- `runVideoFrameAtPosition()`은 호출 전 `controller.value.size`가 이미 있으므로 전달 가능
- **영향**: 오프라인 디버그 only. 지금 당장 운영 버그는 아님

### 2.3 `_bestTrackFor` matching score 비정규화 — [yolo_detection_overlay.dart:150-152]

```dart
final score = (iou * 1.35) +    // 1.35 > 1.0, 비정규화
    (closeness * 0.75) +
    (math.min(...) * 0.15);
// 이론 최대: 1.35 + 0.75 + 0.15 = 2.25
// minMatchScore: 0.18 (정규화 기준 없음)
```

- 가중치 합이 2.25이므로 `_minMatchScore = 0.18`의 실질 의미가 불명확
- 경계 케이스에서 track flipping 가능성 (수치만의 문제, 현재 동작에 큰 영향은 없을 수 있음)
- **영향**: 다중 객체 겹침 상황에서 박스 jitter 가능성

### 2.4 method channel timeout 없음 — [live_drive_canvas_yolo_components.dart:204-215]

```dart
final ok = await _nativeCameraControlChannel.invokeMethod<bool>(
    'updateYoloConfig', ...
);  // timeout 없음
```

- native 측이 hang하면 Dart await 무한 대기
- YOLO config 업데이트 중 native 데드락 시 UI freeze
- **영향**: 드문 케이스이나 발생 시 앱 freeze

---

## 3. 핵심 미해결 (운영 레벨)

### 3.1 live QNN: `qnn_dsp_transport_failed`

현재 단계:
- backendAvailable, backendEnvReady, 모델/metadata 로드 — 모두 통과
- `Module.load()`까지 진행, `forward()` 시 DSP device handle 오픈 실패
- 앱 코드 레벨에서 해결 가능한 범위를 넘어 HTP skel deploy / DSP 권한 레벨 문제일 수 있음

확인이 필요한 것:
- skel assets (libQnnHtpV75Skel.so 등)이 실제 기기 `/data/local/tmp` 등에 deploy 됐는지
- `online_prepare=true` 모델이 특정 SoC + QNN SDK 버전 조합에서 transport를 못 여는지
- 앱 외부에서 최소 QNN init 테스트로 앱 문제인지 DSP 문제인지 분리

### 3.2 developer playback QNN: main-thread warm-up 후 재검증 필요

- `prepareOfflineRuntimeForPlayback()` 적용됨 (2026-03-17)
- 실기기에서 `executorch_module_load_failed`가 다시 발생하는지 확인 필요

---

## 4. 작업 우선순위 제안

| 순위 | 항목 | 작업 유형 |
|------|------|-----------|
| 1 | developer playback QNN 재검증 (main-thread warm-up 이후) | 실기기 테스트 |
| 2 | `forcedRuntimeBackend` dead code 정리 또는 실제 구현 | 코드 수정 |
| 3 | `sourceSize` 하드코딩 → video metadata에서 추출하도록 수정 | 코드 수정 |
| 4 | live QNN `qnn_dsp_transport_failed` 앱 외부 분리 검증 | 실기기 테스트 |
| 5 | `updateYoloConfig` method channel에 timeout 추가 | 코드 수정 |
