# C3 Stock Onroad Graphics/HUD Reference (2026-03-10)

## 문서 목적

- `D:\CarrotLink\c3-v10-wip`의 stock onroad 그래픽/HUD 원본 구조를 한 문서로 고정한다.
- 이후 AI나 신규 작업자가 `path/lane/lead/radar/HUD/nav`를 수정할 때, 어떤 파일을 기준으로 봐야 하는지 바로 판단할 수 있게 한다.
- CarrotLink 쪽 구현이 원본과 어긋날 때, 비교 기준을 다시 찾느라 원본 저장소를 전부 재탐색하는 비용을 줄인다.

## 이 문서를 먼저 읽어야 하는 작업

- stock 모드 주행 그래픽 parity
- stock HUD semantic parity
- lead/radar box 정합
- carrotMan 기반 TBT/제한속도/신호등 표시
- 원본 onroad draw order 확인

## 분석 기준

- 원본 저장소: `D:\CarrotLink\c3-v10-wip`
- 앱 저장소: `D:\CarrotLink\CarrotLink-dev`
- 분석일: 2026-03-10

## 한 줄 결론

- 이 브랜치에서 실제 onroad 그래픽/HUD의 주 렌더러는 `selfdrive/ui/carrot.cc`다.
- `qt/onroad/model.cc`, `qt/onroad/hud.cc` 같은 stock Qt renderer는 코드상 남아 있지만, 현재 브랜치 기준 실사용 경로는 아니다.

---

## 1. 원본 렌더 진입 경로

원본 onroad 화면 진입은 아래 순서다.

1. `selfdrive/ui/main.cc`
2. `selfdrive/ui/qt/window.cc`
3. `selfdrive/ui/qt/home.cc`
4. `selfdrive/ui/qt/onroad/onroad_home.cc`
5. `selfdrive/ui/qt/onroad/annotated_camera.cc`

실제 프레임 그리기 핵심은 `AnnotatedCameraWidget::paintEvent(...)`다.

여기서 순서는 아래다.

1. road/wide road 카메라 프레임 draw
2. `model.draw(...)`
3. `ui_draw(s, &model, width(), height())`

중요:

- `model.draw(...)`는 stock Qt path/lane/lead painter 경로다.
- `ui_draw(...)`는 `selfdrive/ui/carrot.cc`의 NanoVG 오버레이 집합 렌더 경로다.

## 2. 현재 브랜치에서 실제로 살아 있는 렌더 경로

### 2.1 실제 활성 경로

- 카메라 프레임: `selfdrive/ui/qt/widgets/cameraview.cc`
- 최종 onroad 오버레이: `selfdrive/ui/carrot.cc`
- border/상하단 상태줄: `selfdrive/ui/carrot.cc`의 `ui_draw_border(...)`

### 2.2 사실상 비활성인 stock Qt renderer

- `selfdrive/ui/qt/onroad/model.cc`
  - `ModelRenderer::draw(...)` 초반에 조기 `return`이 있다.
  - 따라서 stock path/lane/road edge/lead chevron painter는 현재 브랜치에서 바로 그려지지 않는다.
- `selfdrive/ui/qt/onroad/annotated_camera.cc`
  - `dmon.draw(...)`, `hud.updateState(...)`, `hud.draw(...)`가 주석 처리되어 있다.
  - 즉 stock Qt HUD/driver monitoring overlay도 현재는 화면 경로에서 빠져 있다.

결론:

- 화면에서 보이는 stock onroad 그래픽은 `carrot.cc` 쪽을 먼저 봐야 한다.
- `qt/onroad` 계열은 "원형 참고 코드"로는 중요하지만, "지금 화면에 왜 이렇게 보이느냐"의 1차 답은 아니다.

---

## 3. 원본 데이터 파이프라인

### 3.1 modeld -> modelV2

핵심 파일:

- `selfdrive/modeld/parse_model_outputs.py`
- `selfdrive/modeld/fill_model_msg.py`
- `selfdrive/modeld/modeld.py`

여기서 생성되는 핵심 출력:

- `modelV2.position`
- `modelV2.velocity`
- `modelV2.acceleration`
- `modelV2.laneLines`
- `modelV2.laneLineProbs`
- `modelV2.roadEdges`
- `modelV2.roadEdgeStds`
- `modelV2.leadsV3`
- `modelV2.meta`

CarrotLink에서 stock path/lane/lead를 다시 구현하거나 맞출 때는 이 필드 의미를 그대로 따라가야 한다.

### 3.2 radard -> radarState

핵심 파일:

- `selfdrive/controls/radard.py`

이 브랜치의 `radard.py`는 단순 `leadOne/leadTwo`만 만드는 게 아니다.

- `leadOne`, `leadTwo`
- `leadLeft`, `leadRight`
- `leadsLeft`, `leadsCenter`, `leadsRight`
- `leadsCutIn`
- `leadsLeft2`, `leadsRight2`
- cut-in / center lead 재선정
- corner radar 보정

즉 CarrotLink에서 lead/radar overlay parity를 맞출 때는 `leadOne`만 보면 부족하다.

### 3.3 UIState -> scene

핵심 파일:

- `selfdrive/ui/ui.h`
- `selfdrive/ui/ui.cc`

여기서 유지되는 핵심 상태:

- calibration matrix
- panda / ignition / started
- metric 여부
- `scene.carrot_experimental_mode`
- `scene._current_carrot_display`
- `scene.map_on_left`

카메라 배치와 wide/narrow 선택에도 이 상태가 연결된다.

---

## 4. 실제 그리기 책임 분해

`selfdrive/ui/carrot.cc` 안에서 실제 그리기 책임은 아래처럼 나뉜다.

### 4.1 유틸 계층

- `ui_draw_text`
- `ui_draw_line`
- `ui_draw_image`
- `ui_fill_rect`

역할:

- NanoVG 텍스트, 다각형, 아이콘, 카드 배경 공통 렌더

### 4.2 경로/차선/리드 관련

- `PathDrawer`
  - 주행 path polygon과 애니메이션/특수 색 모드
- `LaneLineDrawer`
  - lane line / road edge
- `PathEndDrawer`
  - 전방 lead box, radar/vision distance badge, desired distance marker
- `DesireDrawer`
  - lane change / turn / blinker 아이콘
- `BlindSpotDrawer`
  - blind spot barrier

중요:

- 전방 차량 box parity는 `PathEndDrawer`를 먼저 봐야 한다.
- 차선/path parity는 `PathDrawer`, `LaneLineDrawer`를 먼저 봐야 한다.

### 4.3 HUD/상태 카드

- `DrawCarrot::updateState(...)`
  - HUD semantic 입력 정리
- `DrawCarrot::drawHud(...)`
  - 좌하단 HUD 카드
- `DrawCarrot::drawRadarInfo(...)`
  - 좌우/중앙 radar target 속도/거리/벡터
- `DrawCarrot::drawDateTime(...)`
  - 시간/날짜
- `DrawCarrot::drawDeviceInfo(...)`
  - 상단 디바이스 debug text
- `drawTpms*`
  - TPMS 4륜 표시

중요:

- HUD 값 의미 parity는 `DrawCarrot::updateState`와 `DrawCarrot::drawHud`를 같이 봐야 한다.
- 단순히 `drawHud`의 텍스트만 복제하면 값 우선순위가 틀어질 수 있다.

### 4.4 내비/TBT

- `TurnInfoDrawer`
  - `xTurnInfo`, `xDistToTurn`, `xSpdLimit`, `xSpdDist`, `szTBTMainText`, `szPosRoadName`
  - carrotMan 기반 turn/TBT/제한속도/road name 표현
- `DrawCarrot::drawNaviPath(...)`
  - nav path point 표시

중요:

- TBT, CAM, 제한속도, 경로점 관련 원본 기준은 `carrotMan` 필드다.
- CarrotLink에서 이 영역을 parity 맞출 때 `carState`만 봐서는 안 된다.

### 4.5 draw order

`ui_draw(...)` 기준 실제 draw order는 아래다.

1. `drawCarrot.updateState`
2. `drawCarrot.drawNaviPath`
3. `drawPath.draw`
4. `drawLaneLine.draw`
5. `drawPathEnd.draw`
6. `drawDesire.draw`
7. `drawPlot.draw`
8. `drawBlindSpot.draw`
9. `drawCarrot.drawRadarInfo`
10. `drawCarrot.drawHud`
11. `drawCarrot.drawDebug`
12. `drawCarrot.drawDateTime`
13. `drawCarrot.drawDeviceInfo`
14. `drawTpms*`
15. `drawTurnInfo.draw`
16. animated text
17. alert

즉 HUD보다 아래에 path/lane/lead가 있고, TBT/alert는 그보다 위쪽에 온다.

---

## 5. stock parity 작업 시 어떤 파일을 기준으로 봐야 하나

### 5.1 주행 path/lane/road edge

먼저 볼 파일:

- `D:\CarrotLink\c3-v10-wip\selfdrive\ui\carrot.cc`
  - `PathDrawer`
  - `LaneLineDrawer`

보조 참조:

- `D:\CarrotLink\c3-v10-wip\selfdrive\modeld\fill_model_msg.py`
- `D:\CarrotLink\c3-v10-wip\selfdrive\ui\qt\onroad\annotated_camera.cc`

### 5.2 lead/radar box

먼저 볼 파일:

- `D:\CarrotLink\c3-v10-wip\selfdrive\ui\carrot.cc`
  - `PathEndDrawer`
  - `DrawCarrot::drawRadarInfo`
- `D:\CarrotLink\c3-v10-wip\selfdrive\controls\radard.py`

보조 참조:

- `D:\CarrotLink\c3-v10-wip\selfdrive\ui\qt\onroad\model.cc`
  - 기본 chevron renderer 참고용

### 5.3 좌하단 HUD 카드

먼저 볼 파일:

- `D:\CarrotLink\c3-v10-wip\selfdrive\ui\carrot.cc`
  - `DrawCarrot::updateState`
  - `DrawCarrot::drawHud`

보조 참조:

- `D:\CarrotLink\CarrotLink-dev\docs\architecture\carrotpilot\CARROTPILOT_ORIGINAL_ONROAD_HUD_ANALYSIS_2026-03-07_KO.md`

### 5.4 TBT/제한속도/내비

먼저 볼 파일:

- `D:\CarrotLink\c3-v10-wip\selfdrive\ui\carrot.cc`
  - `TurnInfoDrawer`
  - `DrawCarrot::drawNaviPath`

보조 참조:

- `carrotMan` payload를 만드는 원본 side/server 경로

---

## 6. CarrotLink 구현과 연결할 때의 실무 규칙

### 규칙 1. stock 원본 비교 기준을 `qt/onroad/hud.cc`로 잡지 않는다.

- 이 파일은 "표준 Qt HUD" 참고용이다.
- 현재 c3-v10 브랜치에서 실제 사용자가 보는 HUD parity 기준은 `carrot.cc`다.

### 규칙 2. lead/radar는 `leadOne`만 보고 끝내지 않는다.

- `leadLeft`, `leadRight`, `leadsCenter`, `leadsCutIn`, `leadTwo` 정책이 화면에 직접 연결된다.
- parity 작업은 `radard.py`와 `carrot.cc`를 같이 봐야 한다.

### 규칙 3. HUD 의미는 `drawHud` 화면만이 아니라 `updateState`의 변수 우선순위까지 따라간다.

- `apply_speed`
- `apply_source`
- `active_carrot`
- `trafficState`
- `cruiseTarget`
- `myDrivingMode`

이 우선순위를 놓치면 표시는 비슷해도 의미가 달라진다.

### 규칙 4. draw order를 무시하면 "비슷한데 이상한 화면"이 된다.

- path/lane/lead 위에 HUD
- HUD 위에 turn/TBT/alert
- border는 별도 `ui_draw_border(...)`

### 규칙 5. 원본 c3-v10에서 실제 사용 안 하는 경로를 parity 기준으로 고르면 시간이 낭비된다.

대표 예:

- `qt/onroad/model.cc`는 참고용
- `qt/onroad/hud.cc`는 참고용
- 주 기준은 `carrot.cc`

---

## 7. CarrotLink docs에서 같이 봐야 하는 문서

### 7.1 HUD 의미

- `docs/architecture/carrotpilot/CARROTPILOT_ORIGINAL_ONROAD_HUD_ANALYSIS_2026-03-07_KO.md`

### 7.2 요소별 구현 가능성 / 현재 구현 수준

- `docs/architecture/carrotpilot/CARROTPILOT_ONROAD_ELEMENT_MATRIX_2026-03-02_KO.md`

### 7.3 lead/radar 정합

- `docs/architecture/carrotpilot/STOCK_MODE_LEAD_RADAR_ALIGNMENT_CHECKLIST_2026-03-09_KO.md`

### 7.4 YOLO/object detection처럼 stock video placement를 재사용하는 작업

- `docs/architecture/yolo/STOCK_MODE_YOLO26_OBJECT_DETECTION_FEASIBILITY_2026-03-10_KO.md`
- `docs/architecture/yolo/STOCK_MODE_YOLO26_INTEGRATION_PLAN_2026-03-10_KO.md`

---

## 8. AI용 빠른 읽기 순서

stock onroad parity 관련 요청을 받았을 때는 아래 순서로 읽는 것이 가장 빠르다.

1. 이 문서
2. `CARROTPILOT_ORIGINAL_ONROAD_HUD_ANALYSIS_2026-03-07_KO.md`
3. `CARROTPILOT_ONROAD_ELEMENT_MATRIX_2026-03-02_KO.md`
4. `STOCK_MODE_LEAD_RADAR_ALIGNMENT_CHECKLIST_2026-03-09_KO.md`
5. 실제 코드
   - CarrotLink: `lib/screens/drive/*`, `lib/features/hud/*`, `android/app/src/main/kotlin/*`
   - 원본: `c3-v10-wip/selfdrive/ui/carrot.cc`, `radard.py`, `modeld/*`

## 9. 유지 규칙

- 원본 c3-v10에서 `carrot.cc`, `annotated_camera.cc`, `radard.py`, `modeld/fill_model_msg.py` 구조가 크게 바뀌면 이 문서를 먼저 갱신한다.
- CarrotLink 쪽 stock parity 설계 문서는 이 문서를 source of truth로 링크한다.
- 새 handoff 문서를 쓸 때도 "현재 원본 기준 렌더러는 `carrot.cc`"라는 결론을 반복 확인한다.
