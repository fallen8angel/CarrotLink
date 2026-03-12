# CarrotLink Stock Mode YOLO26 객체감지 도입 검토 (2026-03-10)

최종 분석일: 2026-03-10  
최종 업데이트: 2026-03-10  
분석 대상 경로: `D:\CarrotLink\CarrotLink-dev`

이 문서는 CarrotLink의 stock/live drive 화면에서, 기존 sidecar는 수정하지 않고 현재 앱이 받아서 표시하는 원격 주행카메라 영상 위에 YOLO26 기반 객체감지를 추가할 수 있는지 검토한 결과를 정리한다.

같이 봐야 하는 문서:

- `STOCK_MODE_YOLO26_INTEGRATION_PLAN_2026-03-10_KO.md`
- `STOCK_MODE_YOLO26_PROGRESS_HANDOFF_2026-03-10_KO.md`

전제:
- sidecar Python은 수정하지 않는다.
- sidecar는 지금처럼 주행정보와 카메라 스트림만 제공한다.
- 객체감지는 휴대폰 로컬 카메라가 아니라 sidecar에서 오는 `road` / `wideRoad` 카메라 스트림 기준이다.
- 성능이 부족한 기기는 자동 비활성화하거나 제한 모드로 내려도 된다.
- 1차 타깃 기기는 `Galaxy S22 Ultra` 이상급 Android 플래그십이다.

## 1. 결론

- 구현 가능: `예`
- sidecar 수정 필요: `아니오`
- 앱 내부 신규 구현 필요: `예`
- 1차 권장 경로: `Android native 디코드 경로 + ExecuTorch + QNN backend`
- 1차 권장 모델: `YOLO26n`
- 2차 선택 모델: `YOLO26s`
- 1차 목표: `실시간 30fps full inference`가 아니라 `5~10Hz 감지 + 부드러운 overlay`

2026-03-10 현재 구현 스냅샷:

- Flutter/Android 사이 YOLO config bridge는 이미 구현됨
- native video path 안에 `frame sampling`, `yolo_state`, `stub runtime` 골격이 있음
- `SurfaceView -> PixelCopy -> 저해상도 bitmap` POC 경로까지는 연결됨
- `ExecuTorch Module.load()` / 전처리 / 첫 `forward()`까지는 실제 기기에서 확인됨
- 첫 output shape `[1,84,3549]` 진단까지는 확인됨
- 1차 output parser 골격은 추가됨
- 아직 실제 stock canvas box draw / tracking / QNN-lowered runtime은 미구현

핵심 판단은 단순하다.

- 현재 앱은 이미 sidecar의 원격 H.264 카메라 스트림을 받아서 화면에 표시한다.
- sidecar는 그대로 두고도 앱 내부에서 객체감지를 얹을 수 있다.
- 다만 지금 앱 구조에는 ML 추론 런타임과 inference용 프레임 경로가 없으므로, 모델 파일만 추가해서 끝나는 작업은 아니다.

## 2. 코드에서 확인된 현재 구조

2026-03-10 기준 코드에서 확인된 사실은 아래와 같다.

### 2.1 카메라 입력은 이미 sidecar 원격 스트림이다

- WebView 경로는 `ws://<host>:7766/ws/camera/<road|wideRoad>`를 직접 사용한다.
- 관련 파일:
  - `lib/screens/drive/live_drive_canvas_camera_html_components.dart`
  - `lib/screens/drive/live_drive_canvas_screen.dart`

### 2.2 Android native 경로는 이미 H.264를 디코드해 화면에 표시한다

- `NativeDriveVideoPlugin.kt`는 `MediaCodec`으로 `video/avc`를 디코드한다.
- 디코드 결과는 `SurfaceView`로 출력된다.
- 관련 파일:
  - `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveVideoPlugin.kt`

### 2.3 frame sync에 필요한 `frameId`는 이미 존재한다

- sidecar는 카메라 패킷 메타에 `frameId`를 담아 보낸다.
- 앱은 `camera_frame` 이벤트로 해당 `frameId`를 받아 overlay 동기화에 사용한다.
- 관련 파일:
  - `assets/sidecar/carrotlink_sidecar.py`
  - `lib/screens/drive/live_drive_canvas_camera_components.dart`
  - `lib/screens/drive/live_drive_canvas_overlay_sync_components.dart`
  - `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveVideoPlugin.kt`

### 2.4 현재 앱에는 generic ExecuTorch bring-up 런타임이 있다

- Flutter 의존성에 별도 ML runtime은 여전히 없고, Android native 쪽에 `org.pytorch:executorch-android`가 추가됐다.
- 즉 YOLO는 Flutter pure Dart가 아니라 Android native side-channel에서만 돈다.
- 관련 파일:
  - `pubspec.yaml`
  - `android/app/build.gradle.kts`
  - `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveExecuTorchRuntime.kt`

### 2.5 stock 주행모드에서 그대로 재사용할 코드와 규칙

YOLO box overlay를 위해 새로 만들 필요가 없는 stock 모드 자산도 명시해 둔다.

1. `frameId` 단조 증가와 decode 후 emit 규칙

- native 경로는 패킷 메타의 `frameId`를 유지하고, decode output이 소비될 때 `camera_frame` 이벤트를 발생시킨다.
- 즉 detection 결과도 같은 `frameId`를 붙이면 기존 overlay sync 체계에 맞출 수 있다.
- 관련 파일:
  - `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveVideoPlugin.kt`
  - `lib/screens/drive/live_drive_canvas_camera_components.dart`
  - `lib/screens/drive/live_drive_canvas_overlay_sync_components.dart`

2. 최종 stock video placement

- 실제 화면에서 카메라가 차지하는 `left/top/width/height`는 이미 `_buildVideoPlacement(...)`에서 결정된다.
- detection box도 반드시 이 placement를 그대로 따라야 한다.
- 관련 파일:
  - `lib/screens/drive/live_drive_canvas_layout_components.dart`
  - `lib/screens/drive/live_drive_canvas_overlay_math_components.dart`

3. source pixel -> canvas remap 경로

- YOLO 2D detection box는 `car-space`가 아니라 `source pixel` 좌표로 나온다.
- 따라서 1차 구현은 world projection보다 `source-to-canvas placement`를 재사용하는 게 맞다.
- 관련 파일:
  - `lib/screens/drive/live_drive_canvas_overlay_components.dart`

4. frame gap / stale gate 문화

- 현재 stock 모드는 이미 model/camera frame gap을 추적하고, mismatch가 클 때 overlay를 차단하는 문화가 있다.
- detection도 같은 정책을 따라야 한다.
- 관련 파일:
  - `lib/screens/drive/live_drive_canvas_overlay_sync_components.dart`
  - `docs/architecture/remote_ar/STOCK_MODE_LEAD_RADAR_ALIGNMENT_CHECKLIST_2026-03-09_KO.md`

5. 무엇을 1차에서 재사용하지 않을지

- `mapToScreen()` 계열 3D world projection은 lane/path/lead/radar 같은 car-space overlay용이다.
- pure 2D object detection box는 1차에선 여길 직접 쓰지 않는다.
- 다만 이후 detection 결과를 lead/radar/path와 융합할 때는 같은 frame sync 기준 위에서 연결 가능하다.

## 3. sidecar를 안 건드릴 때 쉬워지는 점

이 요구사항은 아래 복잡도를 줄여준다.

- `CameraX` / `camera2` 연동이 필요 없다.
- 휴대폰 카메라 권한/기종별 센서 포맷 대응이 필요 없다.
- 카메라 포즈/센서 동기화 문제를 새로 만들지 않는다.
- 기존 stock/live drive UX를 유지할 수 있다.
- sidecar가 이미 보내는 `frameId`를 그대로 이용해 detection 결과와 overlay를 동기화할 수 있다.

즉 현재 문제는 "카메라를 어디서 가져오나"가 아니라 아래 하나로 좁혀진다.

`sidecar H.264 스트림을 앱에서 디코드한 뒤, inference용 픽셀 프레임을 어떻게 얻어 YOLO에 먹일 것인가`

## 4. sidecar를 안 건드려도 남는 핵심 구현

### 4.1 inference용 프레임 경로 추가

현재 구현은 "화면 표시용 디코드" 중심이다.

- WebView 경로는 `<video>` / `<canvas>`로 렌더링한다.
- native 경로는 `MediaCodec -> SurfaceView`로 렌더링한다.

하지만 모델은 압축된 H.264가 아니라 디코드된 픽셀 프레임이 필요하다. 따라서 앱 내부에 아래 중 하나가 새로 필요하다.

- 디코드된 프레임을 inference용 버퍼로 복사하는 경로
- 별도 저해상도 inference용 디코더 경로
- 또는 GPU texture / image reader 기반 inference 경로

2026-03-10 현재 구현 메모:

- 1차 POC용으로는 `SurfaceView -> PixelCopy -> 저해상도 bitmap` 샘플러를 붙였다.
- 이 경로는 기존 `MediaCodec -> SurfaceView` 파이프라인을 유지한 채 pixel path를 여는 데 유리하다.
- 다만 최종형으로 고정할지는 아직 미정이며, latency/thermal 측정 후 유지 여부를 결정한다.

### 4.2 inference runtime 추가

현재 앱엔 generic ExecuTorch path가 이미 들어가 있고, 최종 목표 backend는 QNN이다.
따라서 실제 남은 선택은 아래로 좁혀진다.

- generic ExecuTorch를 계속 쓸지
- Qualcomm/QNN-lowered path를 별도로 둘지
- 또는 둘 다 두고 기기/상태별 fallback을 둘지

### 4.3 detection 결과 bridge 추가

모델 결과는 Flutter 전체로 대량 raw tensor를 보내는 게 아니라, 최소 semantic box payload만 보내는 방식이 맞다.

예시:

- `frameId`
- `classId`
- `label`
- `score`
- `x1,y1,x2,y2` 또는 center/size
- optional `trackId`

### 4.4 overlay layer 추가

현재 drive canvas는 이미 overlay를 다층으로 그리고 있다. 객체감지 결과도 같은 철학으로 얹는 게 맞다.

- 카메라 원본 위
- 기존 lead/radar/path/HUD와 충돌하지 않는 별도 layer
- `road` 우선, `wideRoad`는 2차

## 5. 권장 아키텍처

### 5.1 비권장 경로

아래 경로는 1차로 권장하지 않는다.

- Flutter pure Dart inference
- 화면 전체 스크린샷을 떠서 객체감지
- WebView에 그려진 최종 합성 화면을 다시 읽어 모델 입력으로 사용

이유:

- 성능 낭비가 크다.
- 기존 overlay/HUD가 모델 입력에 섞여 오검출이 늘 수 있다.
- S22 Ultra 이상급이라도 장시간 안정성이 떨어질 가능성이 높다.

### 5.2 권장 경로

1차 권장 구조는 아래와 같다.

1. sidecar H.264 스트림 수신은 기존 유지
2. Android native에서 디코드
3. 같은 native 경로에서 저해상도 inference용 프레임 생성
4. YOLO26 inference 실행
5. 결과 box payload만 Flutter 또는 native overlay로 전달
6. 기존 `frameId`와 맞춰 화면에 draw

이 구조의 장점:

- sidecar 무수정
- 기존 video pipeline 재사용
- 기존 frame sync 재사용
- 기기별 성능 등급화가 쉬움
- Flutter에는 가벼운 detection 결과만 올릴 수 있음

## 6. 모델 정책

2026-03-10 기준 Ultralytics 문서에서 확인한 YOLO26 detection 모델 규모는 아래와 같다.

- `YOLO26n`: `2.4M params`, `5.4B FLOPs`
- `YOLO26s`: `9.5M params`, `20.7B FLOPs`
- `YOLO26m`: `20.4M params`, `68.2B FLOPs`

이 문서 기준 판단:

- 1차 모바일 대상은 `YOLO26n`
- `YOLO26s`는 상위기기 선택 옵션
- `YOLO26m` 이상은 1차 범위에서 제외

중요:

- 위 수치는 공식 모델 표에서 확인한 사실이다.
- 실제 `S22 Ultra / S23 Ultra / S24 Ultra`에서의 FPS와 발열은 아직 이 코드베이스에서 측정하지 않았다.
- 따라서 기기별 실사용 가능성은 아래 7장의 "운영 정책"처럼 `벤치 후 활성화`가 맞다.

## 7. 현재 기술적 판단

현재 코드와 실기기 검증 기준 판단은 아래로 정리한다.

- stock/openpilot 그래픽 무결성은 절대 우선이다.
- YOLO는 `fail-open side-channel`이어야 한다.
- 현재 generic ExecuTorch path는 충분히 열렸고, 다음 blocker는 parser/payload/draw다.
- QNN은 최종 목표가 맞지만, parser/draw가 없는 상태에서 먼저 QNN만 붙여도 사용자 체감은 완성되지 않는다.
- 따라서 구현 순서는 `graphics guardrail 고정 -> parser/payload/draw -> tracking/stale gate -> QNN-lowered runtime`이 맞다.

## 8. 기기 정책

이 장은 코드 확인 결과가 아니라 2026-03-10 시점의 기기 스펙과 현재 앱 구조를 바탕으로 한 운영 판단이다.

### 8.1 1차 지원 정책

- `S22 Ultra`: `YOLO26n` 기본, `YOLO26s`는 벤치 통과 시만 허용
- `S23 Ultra`: `YOLO26n` 기본, `YOLO26s` 선택 허용 후보
- `S24 Ultra`: `YOLO26n`/`YOLO26s` 모두 후보

### 8.2 기본 동작 정책

- 최초 설치 후 첫 실행 또는 설정 진입 시 짧은 벤치마크 실행
- 평균 inference 시간, frame drop, thermal signal, UI jank를 측정
- 기준 미달이면 detection 기능 비활성화 또는 `n`으로 강등
- 사용자에게는 `성능 우선` / `정확도 우선` 정도만 노출

### 8.3 1차 성능 목표

- input size: `320` 또는 `416`
- detect rate: `5~10Hz`
- overlay render: 기존 화면 주사율 유지
- 박스 움직임은 smoothing / tracking으로 보정

## 8. runtime 선택 검토 및 결정

2026-03-10 기준 공식 문서로 확인한 export/runtime 선택지는 아래와 같다.

- Ultralytics export: `ONNX`, `TensorFlow Lite`, `NCNN`, `ExecuTorch`
- Android inference runtime 후보:
  - `ExecuTorch + Qualcomm backend`
  - `LiteRT / TensorFlow Lite`
  - `ONNX Runtime Mobile + QNN`
  - `NCNN`

### 8.1 비교 대상 중 이번 범위에서 중요한 둘

이번 요구사항에서 핵심 비교 대상은 아래 둘이다.

- `ExecuTorch + Qualcomm backend`
- `ONNX Runtime Mobile + QNN`

이유:

- 1차 타깃 기기가 `S22 Ultra ~ S24 Ultra`의 고급 Android 기기다.
- 성능이 부족한 기기는 자동 비활성화해도 된다.
- 따라서 범용 fallback보다 `Qualcomm 최적화 path`의 실효성이 크다.

### 8.2 `ExecuTorch + Qualcomm backend`가 가지는 장점

- ExecuTorch Android는 공식 AAR와 Maven Central 통합 경로를 제공한다.
- Qualcomm backend는 Qualcomm AI Engine Direct를 사용하며, 문서상 QNN으로도 표기된다.
- 문서상 이 backend는 Hexagon processor 쪽으로 AI computation을 delegate 할 수 있다.
- Qualcomm backend 가이드는 `torch.export`, quantization, QNN delegate lowering, ExecuTorch `.pte` export 흐름을 명시한다.
- 문서상 지원 SoC 목록에 `SM8750 (Snapdragon 8 Elite)`도 포함되어 있다.
- 이번 타깃 기기군이 Snapdragon 상위기기 중심이므로 방향성이 잘 맞는다.

### 8.3 `ExecuTorch + Qualcomm backend`의 주의점

- backend별 `.pte` 산출과 QNN SDK 버전 정합을 신경 써야 한다.
- 지원되지 않는 연산은 QNN으로 완전히 내려가지 않을 수 있다.
- 따라서 `NPU가 직접 계산한다`는 방향은 맞지만, 실제 전체 graph가 얼마나 QNN에 내려가는지는 모델 변환 결과와 벤치로 확인해야 한다.
- 즉 성능 향상 가능성은 매우 높지만, 이 문서 단계에서 `폭발적으로 빨라진다`를 확정 사실로 적지는 않는다.

### 8.4 `ONNX Runtime Mobile + QNN`은 어떻게 보나

- ORT + QNN도 여전히 유효한 대안이다.
- 다만 이번 범위에선 `PyTorch -> torch.export -> ExecuTorch -> QNN backend` 흐름이 더 직접적이고, Qualcomm 최적화 경로도 더 선명하다.
- 따라서 ORT + QNN은 2차 fallback / 비교 benchmark 대상으로 내린다.

### 8.5 1차 선택

이 문서의 1차 선택은 아래로 고정한다.

- primary runtime: `ExecuTorch + QNN backend`
- primary model: `YOLO26n`
- optional high-end model: `YOLO26s`

선정 이유:

- PyTorch 계열 모델을 `torch.export` 기반으로 내보내는 흐름과 맞다.
- Qualcomm AI Engine Direct / QNN backend 경로가 문서상 명시되어 있다.
- Android AAR 통합 경로가 공식 문서상 분명하다.
- Snapdragon 상위기기 타깃과 잘 맞는다.
- unsupported device는 자동 비활성화 정책으로 처리할 수 있다.

### 8.6 보류 및 fallback

- `ONNX Runtime Mobile + QNN`은 2차 fallback / 비교 benchmark 후보
- `LiteRT` / `NCNN`은 3차 fallback 후보로 문서화만 유지

아래 조건이 생기면 재검토한다.

- `S22 Exynos`까지 적극 지원해야 할 때
- Qualcomm 외 기기 지원 범위를 넓혀야 할 때
- ExecuTorch + QNN에서 graph lowering 비율이 낮을 때
- ExecuTorch + QNN 실제 latency/thermal/jank가 기대에 못 미칠 때

## 9. 현재 문서 기준 비범위

이 문서는 아래 항목을 아직 확정하지 않는다.

- 어떤 객체 클래스를 검출할지
- box 디자인 / color system
- tracking 알고리즘 세부
- detection 결과를 Flutter overlay로 그릴지 native overlay로 그릴지 최종 확정
- road / wideRoad 동시 지원 여부
- background service에서 상시 detection을 돌릴지 여부

## 10. 1차 PoC 완료 기준

- sidecar 무수정 상태에서 road camera detection 동작
- 앱이 표시하는 주행영상 위에 detection box 정상 표시
- `frameId` 기준으로 box와 영상 sync가 크게 어긋나지 않음
- 지원 기기에서 장시간 주행 시 앱이 과도하게 끊기지 않음
- 미지원 기기에서는 기능이 안전하게 꺼짐

## 11. 다음 문서로 분리할 항목

이 문서는 feasibility 초안이다. 상세 통합 방향은 아래 문서로 분리한다.

- `docs/architecture/yolo/STOCK_MODE_YOLO26_INTEGRATION_PLAN_2026-03-10_KO.md`

추가로 아래 문서를 이후 별도로 분리하는 것이 맞다.

- `YOLO26 Android native integration plan`
- `YOLO26 detection overlay payload spec`
- `YOLO26 on-device benchmark matrix`
- `YOLO26 feature gating / thermal degrade checklist`

## 12. 외부 참고 자료

2026-03-10 확인 기준:

- Ultralytics YOLO26 모델 문서  
  https://docs.ultralytics.com/models/yolo26/
- Ultralytics export 문서  
  https://docs.ultralytics.com/modes/export/
- ExecuTorch Android  
  https://docs.pytorch.org/executorch/stable/using-executorch-android.html
- ExecuTorch Qualcomm backend  
  https://docs.pytorch.org/executorch/stable/backends-qualcomm.html
- ONNX Runtime QNN Execution Provider  
  https://onnxruntime.ai/docs/execution-providers/QNN-ExecutionProvider.html
- Google LiteRT Android  
  https://ai.google.dev/edge/litert/android
- Google LiteRT NPU 개요  
  https://ai.google.dev/edge/litert/next/npu
- Samsung Galaxy S22 Ultra spec sheet  
  https://image-us.samsung.com/SamsungUS/samsungbusiness/pdfs/datasheet/Galaxy_S22_Ultra_Spec_Sheet.pdf
- Samsung Galaxy S23 Series 공식 소개  
  https://news.samsung.com/global/take-your-passions-further-with-the-new-samsung-galaxy-s23-series-designed-for-a-premium-experience-today-and-beyond/1000
- Samsung Galaxy S24 Ultra specs  
  https://www.samsung.com/ph/smartphones/galaxy-s24-ultra/specs/

## 13. 내 의견

- 이 기능은 "객체감지 자체"보다 "현재 video pipeline에 inference를 어디에 끼워 넣느냐"가 본질이다.
- sidecar를 건드리지 않는 조건은 오히려 좋다. 경계가 명확해진다.
- 1차는 `road + YOLO26n + 320/416 + 5~10Hz`가 맞다.
- `YOLO26s`는 상위기기용 선택 옵션으로 두되, 벤치 통과 후 노출이 안전하다.
- runtime은 1차에 `ExecuTorch + QNN backend`를 고정하는 게 맞다.
- 다만 graph lowering 비율과 실제 실기기 benchmark를 반드시 같이 기록해야 한다.
- 문서/코드 모두에서 "확인된 사실"과 "벤치 전 판단"을 계속 분리해서 관리해야 한다.
