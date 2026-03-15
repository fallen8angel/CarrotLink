# STOCK Mode YOLO Developer Playback (2026-03-15)

## 2026-03-16 최신 메모

- route 로그 playback은 이제 실제 native playback tick까지 들어간다.
  - 확인 로그: `runYoloDebugVideoFrame backend=... model=... positionMs=...`
- 따라서 "안 보임" 이슈는 더 이상 playback 경로 미진입이 아니라, 주로 model/runtime blocker 쪽으로 봐야 한다.
- playback 우측 상단에는 현재 아래 상태 배지가 추가돼 있다.
  - `QNN 변환 필요`
  - `모델 파일 없음`
  - `실행 확인`
  - `QNN 검증 완료`
- `YOLO26n QNN` / `YOLO26s QNN` 선택은 가능하지만, 현재 앱 번들에 실제 QNN-lowered `.pte`가 없어서 선택만으로는 박스가 뜨지 않는다.
- 최신 전체 handoff는 아래 문서를 본다.
  - `docs/architecture/yolo/STOCK_MODE_YOLO26_PROGRESS_HANDOFF_2026-03-16_KO.md`

## 목적

- `alive` 없이도 stock 주행 화면 안에서 YOLO/QNN 상태와 박스/라벨을 테스트한다.
- 기존 `live road camera` 경로를 망가뜨리지 않고, 나중에 통째로 제거하기 쉬운 구조를 유지한다.

## 경계

- 이 경로는 **developer-only offline playback source** 이다.
- production `stock live camera` 경로와 섞지 않는다.
- 공통으로 재사용하는 것은 아래뿐이다.
  - stock viewport 배치
  - zoom preset
  - YOLO 설정/상태 store
  - YOLO detection overlay widget

## 현재 구조

1. `features/yolo`
   - YOLO 설정/상태 저장
   - offline debug runner
   - detection overlay widget
2. `LiveDriveCanvas`
   - live source
   - developer offline playback source
   - 둘 중 하나만 화면에 올린다
3. `stock settings popup`
   - 일반 사용자는 `그래픽`만 본다
   - 개발자 모드일 때만 `YOLO` 그룹이 추가된다

## 현재 상태 반영 메모 (2026-03-15 night)

- developer playback 제어는 popup 안에만 두지 않고, stock 화면 우측 상단에
  빠른 제어 패널로도 노출한다.
  - 영상 선택
  - 오프라인 재생 시작/종료
  - 재생/일시정지
  - 상태 복사
  - 선택 해제
- 일시정지 시 마지막 YOLO 박스/라벨을 지우지 않는다.
  - 목적은 freeze-frame 디버깅이다.
- 재생 도중 다른 로그 영상을 선택할 때는 live/native source로 잠깐
  되돌아가지 않고, offline mode를 유지한 채 controller/session만
  안전하게 교체한다.
- in-flight YOLO tick이 남아 있을 수 있으므로, source 교체/중지 전에
  기존 tick이 비워질 시간을 짧게 기다린다.
- 늦게 도착한 예전 비디오의 frame 결과는 source epoch가 다르면 버린다.

## 현재 한계

- 지금 playback YOLO는 기존 openpilot lead/radar/path overlay처럼
  `camera frame id` 기준으로 frame-locked render를 하지 않는다.
- 구조는 아직 아래에 가깝다.
  1. Dart timer가 주기적으로 돈다
  2. native가 `MediaMetadataRetriever.getFrameAtTime(...)` 로 시점 프레임을 다시 뽑는다
  3. YOLO 1회 실행 결과를 box overlay로 올린다
- 그래서 체감상
  - 연속 추적보다 샘플 기반 갱신에 가깝고
  - 박스가 프레임마다 부드럽게 따라붙는 느낌은 아직 약하다.
- device에서는 offline path가 여전히 `libexecutorch_jni.so` 내부
  `xnnpack` delegate bring-up 쪽으로 빠지며 native crash가 날 수 있다.
  즉 설정값상 `executorch_qnn` 으로 보여도, 실제 native stack은 별도 확인이 필요하다.

## 다음 페이즈 시작점

- 다음 통합 작업의 첫 준비로, offline playback 결과 state에 아래 sync token을 남긴다.
  - `syncSource=developer_playback`
  - `playbackFrameId`
  - `playbackFramePtsUs`
  - `playbackFrameToken`
- 이 값들은 아직 기존 `DriveCanvas` overlay sync buffer에 직접 합류하지는 않지만,
  이후 playback path를 기존 frame-sync 파이프라인에 태울 때 기준 키로 사용한다.
- 목표는 아래 순서다.
  1. playback frame token을 공통 기준으로 확정
  2. seek/polling 중심 경로를 줄이고 decode-driven timestamp 기준으로 전환
  3. YOLO를 별도 debug overlay가 아니라 공통 overlay snapshot 레이어로 합치기
  4. 마지막으로 tracker/보간을 넣어 lead/radar처럼 더 부드럽게 보이게 만들기

## 런타임 분리 메모

- developer playback를 켜는 순간, 기존 `live native camera` 쪽 YOLO runtime은
  명시적으로 disable payload를 받아 먼저 내려간다.
- 이유는 같은 앱 프로세스 안에서 live/offline ExecuTorch delegate bring-up이
  겹치면 `libexecutorch_jni.so` 초기화 단계에서 native crash가 날 수 있기
  때문이다.
- offline runtime은 source 전환 직후 바로 뜨지 않고, 화면 교체 한 프레임 뒤에
  시작한다.
- `Module.loadMethod("forward")` 같은 eager method load는 피하고,
  첫 `forward()` 호출이 method init을 소유하도록 둔다.

## parser 메모

- 현재 offline/live 공용 parser는 road-facing 1차 객체만 유지한다.
  - `person`
  - `bicycle`
  - `car`
  - `motorcycle`
  - `bus`
  - `truck`
  - `traffic light`
- score 해석은 export/backend 차이를 흡수하기 위해 아래 순서로 시도한다.
  1. `direct`
  2. `direct_low`
  3. `sigmoid`
- 상태값에는 아래 parser 진단을 같이 남긴다.
  - `parserStrategy`
  - `parserScoreThreshold`
  - `parserAboveThresholdCount`
  - `parserMaxClassScore`
- 목적은 `0 detections` 상태를 그냥 빈 결과로 두지 않고,
  - threshold 문제인지
  - score decode 문제인지
  - 실제로 road-object candidate가 없는지
  를 개발자 도구와 playback overlay에서 바로 확인하는 것이다.

## 제거 기준

아래만 제거하면 developer playback 전체가 빠져야 한다.

- `lib/screens/drive/live_drive_canvas_dev_playback_components.dart`
- stock settings popup 안 `YOLO` 그룹
- `features/yolo/application/yolo_stock_debug_playback_store.dart`

이 작업은 아래를 건드리지 않는 것을 전제로 한다.

- native/web live camera source
- stock zoom preset / viewport placement
- 일반 stock graphics toggles

## 사용 흐름

1. 개발자 모드 활성화
2. stock 화면 우측 상단 빠른 제어 또는 `설정 > YOLO`
3. 영상 선택
4. `오프라인 재생` 활성화
5. 필요하면 `일시정지`로 freeze-frame 디버깅
6. 기존 stock 줌 버튼으로 같은 viewport 배율 테스트
7. YOLO 상태/토큰은 같은 메뉴 안에서 확인

## 주의

- 이 경로는 live sidecar/camera event를 소비하지 않는다.
- offline playback 활성화 중에는 live source용 상태 배너/notice가 화면을 덮지 않도록 suppress 한다.
- 목적은 `alive parity test harness`이지, 최종 사용자 기능 추가가 아니다.
