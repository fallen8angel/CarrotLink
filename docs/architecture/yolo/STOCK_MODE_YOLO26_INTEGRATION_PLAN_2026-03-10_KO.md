# CarrotLink Stock Mode YOLO26 통합 계획 (2026-03-10)

최종 분석일: 2026-03-10  
최종 업데이트: 2026-03-17  
대상 경로: `E:\Carrot\CarrotLink`

이 문서는 `stock` 주행모드 원격 카메라 화면 위에 YOLO26 객체감지를 얹을 때의 1차 통합 계획을 정리한다. 원래 문서는 계획 문서지만, 아래 2026-03-17 보정으로 현재 운영 정책과 구현 현실을 같이 반영한다.

같이 봐야 하는 문서:

- `STOCK_MODE_YOLO26_OBJECT_DETECTION_FEASIBILITY_2026-03-10_KO.md`
- `STOCK_MODE_YOLO26_PROGRESS_HANDOFF_2026-03-10_KO.md`

전제:
- sidecar는 수정하지 않는다.
- 앱은 sidecar의 `ws/camera/{road|wideRoad}` 스트림과 `ws/live` 주행 payload를 그대로 사용한다.
- 1차 목적은 사용자가 체감하는 `부드러움`, `가독성`, `좋은 그래픽 경험`이다.
- 1차 모델은 `YOLO26n`이다.
- `YOLO26s`는 벤치 통과 후 병행 옵션으로 확장한다.

비가역 원칙:

- 기존 stock/openpilot 그래픽의 무결성은 절대 깨지면 안 된다.
- YOLO는 반드시 `fail-open side-channel`로 붙는다.
- YOLO가 늦거나, stale하거나, parser가 실패하면 `YOLO box만 버리고` 기존 그래픽은 유지한다.

## 1. 1차 목표

- stock 주행화면 위에 도로 객체를 안정적으로 감지해 그린다.
- 감지 주기보다 렌더링이 더 부드럽게 느껴지도록 temporal smoothing을 넣는다.
- `crop / fit / zoomOut` 세 가지 stock 배율에서 box 정합이 유지된다.
- HUD/lead/radar/path와 시각적으로 충돌하지 않는다.
- 기능 활성화는 기존 `HUD debug layer` 토글 체계 안에 넣는다.

## 2. 객체 범위

1차 객체 범위는 아래처럼 고정한다.

- 차량 계열:
  - 승용차
  - 트럭
  - 버스
- 이륜/경량 계열:
  - 오토바이
  - 자전거
- 보행자 계열:
  - 사람
- 신호 관련:
  - 신호등

비고:

- lane/path/lead/radar는 기존 stock overlay 로직이 이미 있으므로 YOLO의 1차 대상이 아니다.
- 도로 표지판, 콘, 동물, 특수 장애물은 2차 범위다.

## 3. 사용자 체감 품질 원칙

객체감지 기능의 1차 성공 기준은 `정확도 숫자`보다 `사용자가 보기 편하고 믿을 수 있게 느끼는가`다.

### 3.1 부드러움

- detection은 `5~10Hz`여도 된다.
- render는 기존 화면 주사율을 유지한다.
- 감지 결과는 tracker + temporal smoothing으로 보간한다.

### 3.2 그래픽 품질

- box는 단순 사각형만 쓰지 않고, 두께/코너/label spacing을 scale-aware로 조정한다.
- class별 색 규칙은 고정하되, fill alpha는 과하지 않게 제한한다.
- 교차로/야간 화면에서 신호등과 보행자 라벨이 특히 잘 읽히도록 설계한다.

### 3.3 안정감

- 낮은 confidence의 box가 프레임마다 깜빡이는 상황을 줄여야 한다.
- 잠깐 사라진 객체는 즉시 delete하지 말고 짧은 retention 후 fade-out한다.
- traffic light state는 box 위치 smoothing과 신호 상태 smoothing을 분리한다.

## 4. temporal smoothing / tracking 정책

1차 권장 정책:

1. detection -> tracking -> smoothing -> rendering 순서
2. tracking key는 `class + IoU + motion` 기반
3. 위치/크기는 Kalman filter 또는 유사 constant-velocity filter 사용
4. confidence는 hysteresis 적용
5. track loss 시 `120~250ms` 정도 유지 후 fade-out

세부 권장:

- `car/truck/bus`:
  - 박스 center와 size를 smoothing
  - 상대속도 체감이 크므로 과도한 filter 지연은 금지
- `person/motorcycle`:
  - jitter가 크므로 Kalman gain을 조금 더 강하게
- `traffic light`:
  - box 위치는 smoothing
  - `red/green/yellow` state는 majority vote 또는 짧은 hysteresis 사용
  - 상태 전환은 너무 늦게 반영하면 안 되므로 state smoothing은 별도 상수 사용

주의:

- `Kalman`은 box geometry용으로 쓰고, semantic state를 그대로 묶지 않는다.
- 신호 상태는 geometry smoothing보다 더 보수적으로 설계한다.

### 4.1 draw gating 원칙

- detection은 `frameId` 또는 그에 준하는 rendered timestamp 기준으로 stale 판정을 둔다.
- stale detection은 fade-out 또는 drop만 하고, 기존 overlay sync는 건드리지 않는다.
- YOLO는 tracker가 있더라도 기존 `strictFrameLock` 경로를 우회/변경하지 않는다.

## 5. stock 좌표/맵핑 원칙

YOLO 객체감지는 1차에서 `3D world projection`이 아니라 `2D source pixel -> placed canvas` 문제로 다룬다.

### 5.1 재사용할 기존 경로

- 최종 stock video placement:
  - `lib/screens/drive/live_drive_canvas_layout_components.dart`
- source-to-canvas placement:
  - `lib/screens/drive/live_drive_canvas_overlay_components.dart`
- video placement math:
  - `lib/screens/drive/live_drive_canvas_overlay_math_components.dart`
- frame sync:
  - `lib/screens/drive/live_drive_canvas_camera_components.dart`
  - `lib/screens/drive/live_drive_canvas_overlay_sync_components.dart`
  - `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveVideoPlugin.kt`

### 5.2 1차 좌표계

1차 detection 좌표계는 아래 순서로 고정한다.

1. inference input 좌표
2. source pixel 좌표
3. stock video placed canvas 좌표

즉 1차는:

- `YOLO box -> source pixel`
- `source pixel -> placed canvas`

이 두 단계만 사용한다.

### 5.3 1차에서 직접 쓰지 않을 경로

아래 경로는 1차 pure object detection box에 직접 쓰지 않는다.

- `_buildTransform`
- `_mapToScreen`
- `car-space -> source pixel` 3D projection

이 경로는 lane/path/lead/radar처럼 world-aware overlay용이다.

### 5.4 배율 모드 대응

현재 stock 주행화면은 아래 배율을 사용한다.

- `crop`
- `fit`
- `zoomOut`

YOLO box는 세 경우 모두 아래 규칙을 따른다.

- 추론 결과는 source pixel로 복원
- 최종 draw는 `_buildVideoPlacement(...)` 결과와 같은 배치 규칙 사용
- overlay가 local canvas 안에서 추가 pan을 다시 먹지 않도록 유지

### 5.5 frame sync

- detection result는 반드시 `frameId`를 가진다.
- draw 시 `camera_frame`과의 차이를 기록한다.
- stale / frame gap이 크면 hide 또는 alpha down 한다.
- YOLO sampling용 synthetic id는 내부 추론/샘플링 전용으로만 쓰고,
- 기존 화면 sync용 `camera_frame` 이벤트에는 절대 섞지 않는다.

## 6. UI/토글 정책

현재 stock 주행모드에는 `HUD debug layer` 계열 토글 묶음이 이미 있다.

관련 코드:

- pref key:
  - `lib/screens/drive/live_drive_canvas_screen.dart`
- load/save:
  - `lib/screens/drive/live_drive_canvas_overlay_sync_components.dart`
- debug popup layer switches:
  - `lib/screens/drive/live_drive_canvas_debug_popup_components.dart`
- painter layer wiring:
  - `lib/screens/drive/live_drive_canvas_layout_components.dart`

1차 정책:

- YOLO 활성화는 별도 일반 설정이 아니라 `HUD debug mode` 내부 토글로 시작
- 기존 토글 세트에 아래 키를 추가

권장 1차 토글:

- `yoloEnabled`
- `yoloBoxes`
- `yoloLabels`
- `yoloTrafficLights`
- `yoloDebugStats`

초기 기본값:

- `yoloEnabled=false`
- 나머지도 `false`

이유:

- 성능/발열 특성을 실기기에서 먼저 검증해야 한다.
- 기존 overlay debug 문화와 잘 맞는다.
- 불안정한 초기 상태가 일반 사용자 UX에 바로 노출되지 않는다.

## 7. 모델/런타임 정책

1차 고정안:

- model:
  - `YOLO26n`
- runtime:
  - `ExecuTorch + QNN backend`

현재 구현 상태 보정:

- 현재 앱은 generic `ExecuTorch/XNNPACK` 기준선까지는 실제 사용 가능 상태다.
- 현재 앱은 `executorch_qnn`과 `executorch_xnnpack` 두 backend를 모두 가진다.
- QNN-lowered model과 metadata도 앱 번들에 실제로 들어간다.
- 다만 live 기기 기준 QNN의 본질적 blocker는 `qnn_dsp_transport_failed`다.
- developer playback 쪽은 별도로 `executorch_module_load_failed` 가능성이 남아 있다.
- 따라서 운영은 `QNN only`가 아니라, `Snapdragon=QNN 우선 + 실패 시 XNNPACK`, `Exynos=XNNPACK 기본`으로 가져가는 것이 맞다.
- parser/draw/tracking은 backend와 독립적으로 유지하고, backend 교체가 overlay 정합을 깨지 않게 하는 원칙은 그대로 유지한다.

2차 확장안:

- `YOLO26s`
- 기기 벤치 통과 시만 활성

운영 규칙:

- `YOLO26n`으로 시작
- 실제 기기에서 latency/thermal/UI jank가 허용 범위면 `s`를 병행 제공
- 기기 성능에 따라 `n/s`를 선택하거나 `s`를 숨김

즉 전략은:

- `n first`
- `s later in parallel`

## 8. ExecuTorch + QNN 적용 원칙

현재 선택은 아래 흐름으로 고정한다.

1. PyTorch 계열 모델 준비
2. `torch.export` 기반 export graph 생성
3. 필요 시 quantization 적용
4. Qualcomm backend로 lowering / compilation
5. ExecuTorch `.pte` 산출
6. Android native runtime에서 `.pte` 실행

주의:

- Qualcomm backend는 Qualcomm AI Engine Direct를 사용하며, 문서상 QNN으로도 표기된다.
- 문서상 Hexagon 쪽 delegate가 가능하지만, 실제 전체 모델이 QNN에 얼마나 내려가는지는 산출/벤치로 확인해야 한다.
- 따라서 `NPU 활용`은 목표이자 강한 기대치이지만, 실제 성능 평가는 반드시 기기 측정으로 확정한다.

1차 구현 방향:

- `YOLO26n + ExecuTorch + QNN backend`
- 추후 benchmark 통과 기기에서 `YOLO26s` 병행
- ORT + QNN은 fallback / 비교 benchmark 용도로만 유지

현 시점 추가 원칙:

- generic ExecuTorch path와 QNN path를 논리적으로 분리한다.
- parser / projection / draw / tracking은 backend와 독립적으로 동작해야 한다.
- backend 교체가 기존 overlay 정합에 영향을 주면 구조가 잘못된 것으로 본다.

## 9. 신호등 인식과 openpilot 활용 여지

이 항목은 `지금 바로 가능한가`와 `향후 구조 확장 여지가 있는가`를 분리해서 본다.

### 8.1 현재 코드 기준 결론

- `앱 내부 표시/HUD 활용`: 가능
- `앱에서 검출한 신호등 값을 openpilot 쪽 주행판단에 즉시 반영`: 현재 구조에선 바로는 불가

### 8.2 이유

현재 구조는 기본적으로 `device/sidecar -> app` 단방향 소비 구조다.

- sidecar는 `ws/live`, `ws/hud`, `ws/camera`로 데이터를 앱에 보낸다.
- 앱에서 sidecar로 보내는 실시간 perception 입력 채널은 현재 없다.
- 확인된 관리용 API는 `profile`, `camera_quality` 정도다.

즉, 앱에서 신호등을 인식해도 현재 구조만으로는 그 값을 openpilot의 live planner/model 입력으로 되돌려 넣을 채널이 없다.

### 8.3 향후 활용 여지는 있다

향후 확장 여지는 있다. 다만 형태는 아래가 더 현실적이다.

1. `직접 neural model 입력`보다는 `planner hint / semantic signal`로 사용
2. device 쪽에 새 입력 채널 정의
3. app-side detection 결과를 hysteresis/validation 후 upstream 전달
4. device 측에서 `trafficState` 유사 semantic으로 소비

즉 더 현실적인 미래 경로는:

- `app YOLO signal -> validated semantic signal -> planner/policy hint`

이지,

- `app YOLO output -> openpilot end-to-end model tensor 직접 주입`

가 아니다.

### 8.4 문서상 판단

이 문서 기준 판단은 아래로 고정한다.

- 향후 활용 여지: `있음`
- 현재 단계 우선순위: `HUD/overlay 표시`
- 2차 우선순위: `semantic signal export contract 설계`
- 3차 우선순위: `device 측 planner 연동 검토`

## 10. 권장 모듈 구조

1차 구현은 `Android native runtime + Flutter feature shell`로 나누는 것이 맞다.

### 9.1 Flutter 쪽

권장 폴더:

- `lib/features/yolo/`

권장 역할:

- `application/`
  - enable/disable 상태
  - benchmark 결과
  - 기기 gating 정책
- `domain/`
  - detection entity
  - tracked object entity
  - traffic light semantic entity
- `presentation/`
  - debug toggle state
  - box style policy
  - overlay painter/native bridge payload

### 9.2 Android native 쪽

권장 역할:

- `YoloRuntime`
  - ORT/QNN 세션 관리
- `YoloFrameSampler`
  - inference용 저해상도 프레임 생성
- `YoloTracker`
  - temporal smoothing / Kalman / retention
- `YoloOverlayMapper`
  - source pixel -> placed canvas 변환
- `YoloBenchmark`
  - warmup / latency 측정 / device gating

### 9.3 기존 stock 코드와의 결합 경계

- video decode:
  - `NativeDriveVideoPlugin.kt`
- overlay sync:
  - `live_drive_canvas_overlay_sync_components.dart`
- debug toggle UI:
  - `live_drive_canvas_debug_popup_components.dart`
- final overlay placement:
  - `live_drive_canvas_layout_components.dart`
  - `live_drive_canvas_overlay_components.dart`

원칙:

- YOLO 추론과 tracking은 native에 최대한 모은다.
- Flutter는 토글, 상태, 요약 표시, lightweight overlay shell에 집중한다.
- 2D mapping 수식은 기존 stock placement 규칙과 분리되지 않게 유지한다.

## 11. 단계별 실행 순서

1. `HUD debug` 내부 `yoloEnabled` 토글과 native config bridge 추가
2. `YOLO26n + ExecuTorch/QNN + road camera` 최소 런타임 경로 구축
3. source pixel -> stock canvas mapping 고정
4. class별 box/label 스타일 추가
5. tracking + Kalman + fade 정책 추가
6. traffic light semantic stabilization 추가
7. benchmark 통과 기기에서 `YOLO26s` 옵션 오픈

### 11.1 현재 구현 상태 (2026-03-10)

완료:

- Flutter debug 토글에서 YOLO 설정을 저장/로드한다.
- native `MethodChannel`로 YOLO config를 전달한다.
- Android native video view 내부에 `YoloController` / `YoloRuntime` 골격이 있다.
- 디코드 완료 프레임의 `frameId`, `ptsUs`, `sourceWidth/height`를 runtime controller로 전달한다.
- `SurfaceView -> PixelCopy -> 416x416 bitmap` 기반 pixel sampler를 붙였다.
- native에서 `yolo_state` snapshot을 emit / fetch 할 수 있다.
- Flutter debug snapshot에서 native YOLO 상태를 바로 확인할 수 있다.

아직 미구현:

- 실제 ExecuTorch `.pte` 로드
- QNN backend lowering 결과 실행
- detection result payload / tracker / overlay draw

임시 구현됨:

- `SurfaceView -> PixelCopy -> 저해상도 bitmap` 경로로 pixel sampler를 붙였다.
- 이 경로는 sidecar/decoder 구조를 크게 바꾸지 않는 POC용이다.
- 장기적으로는 더 직접적인 decoder pixel path가 가능하면 교체 검토 대상이다.

현재 가장 큰 blocker:

- Pixel sampler는 열렸지만, 아직 ExecuTorch 세션과 전처리 파이프라인이 없다.
- 따라서 현재 상태는 `pixel path ready`까지이고, 실제 detection inference는 아직 아니다.

진행률 해석:

- 기반 공사 기준: 약 `45~50%`
- 실제 객체가 검출돼 화면에 그려지는 기능 완성 기준: 약 `25~30%`

## 12. 1차 완료 기준

- `car / truck / bus / motorcycle / person / traffic light`가 기본적으로 검출된다.
- box가 눈에 띄게 깜빡이지 않는다.
- `crop / fit / zoomOut`에서 위치가 크게 틀어지지 않는다.
- `frameId` 기준 정합이 유지된다.
- `HUD debug mode`에서 켜고 끌 수 있다.
- 신호등 검출은 표시용으로 의미 있게 보이지만, 아직 openpilot planner 입력으로는 연결하지 않는다.

## 13. 내 의견

- 1차의 경쟁력은 `더 많은 클래스`보다 `더 안정적인 box 경험`이다.
- Kalman/filtering은 선택이 아니라 필수에 가깝다.
- 신호등은 박스만 그리는 것보다 `state stabilization` 품질이 더 중요하다.
- planner 연동은 분명 여지가 있지만, 현재 구조에선 `reverse live channel`이 없으므로 별도 계약 설계가 먼저다.
- 구조적으로는 `features/yolo` + `native runtime modules` 분리가 장기 유지보수에 가장 안전하다.
- 현재 선택은 `ExecuTorch + QNN backend`가 맞지만, 실기기 benchmark가 설계 판단을 뒤집을 수도 있으므로 fallback 경로는 문서에 계속 남겨둔다.
