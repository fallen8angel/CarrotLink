# CarrotPilot 온로드 그래픽 전수 체크리스트 (2026-03-02)

최종 분석일: 2026-03-02  
원본 기준: `d:/CarrotLink/c3-v10-wip`  
앱 기준: `d:/CarrotLink/CarrotLink-dev`

## 1. 전수 기준(이번 문서의 "완전분석" 정의)

이번 전수 체크는 아래 3조건을 모두 만족하는 파일을 대상으로 수행했다.

1. 온로드 화면에 직접 그리거나(`paintEvent`, `draw*`, `ui_draw*`)
2. 온로드 화면 모드/표시를 제어하거나(`_current_carrot_display`, carrot command)
3. 온로드/HUD 데이터를 앱으로 전달 또는 소비하는 경로(`/stream`, `/ws/carstate`, 앱 파서)

## 2. 분류 체계

| 분류 ID | 영역 | 설명 |
|---|---|---|
| C0 | 상태/런타임 | `UIState`, `UIScene`, SubMaster 구독 |
| C1 | 온로드 렌더 코어 | 카메라/모델/알림/보더 |
| C2 | Carrot 전용 NVG 오버레이 | `carrot.cc` 클래스군 |
| C3 | 표시모드/입력 이벤트 | DISPLAY/RECORD, 터치 토글 |
| C4 | 맵/네비 오버레이 | map panel, speed viz, route 연동 |
| C5 | 녹화 인디케이터 | screen recorder 점멸점 |
| C6 | 사운드 체감 요소 | countdown 음성 알림 |
| C7 | 서버/웹 HUD 파이프라인 | `/stream`, `/ws/carstate`, web HUD |
| C8 | 앱 소비 파이프라인 | Flutter/Kotlin 파서 및 표시 |

## 3. 전수 체크리스트

### 3.1 C0 상태/런타임

- [x] C0-01 `UIScene` 핵심 필드 확인  
  파일: `selfdrive/ui/ui.h`  
  확인: `_current_carrot_display`, `_current_carrot_display_prev`, `carrot_experimental_mode`

- [x] C0-02 UI 상태 갱신 로직 확인  
  파일: `selfdrive/ui/ui.cc`  
  확인: `scene.carrot_experimental_mode = lp.getXState() == 4`, `scene.started` 계산

- [x] C0-03 SubMaster 구독 세트 확인  
  파일: `selfdrive/ui/ui.cc`  
  확인: `carrotMan`, `navInstructionCarrot`, `peripheralState`, `longitudinalPlan` 포함

### 3.2 C1 온로드 렌더 코어

- [x] C1-01 온로드 카메라 + 오버레이 렌더 진입 확인  
  파일: `qt/onroad/annotated_camera.cc`  
  확인: `CameraWidget::paintGL()`, `model.draw(...)`, `ui_draw(...)`

- [x] C1-02 온로드 창 레벨 보더 렌더 확인  
  파일: `qt/onroad/onroad_home.cc`  
  확인: `paintEvent` -> `ui_draw_border(...)`

- [x] C1-03 기본 모델 레이어 확인  
  파일: `qt/onroad/model.cc`  
  확인: lane lines, path, lead chevron draw

- [x] C1-04 기본 Alert 레이어 확인  
  파일: `qt/onroad/alerts.cc`  
  확인: alert 박스/텍스트 렌더

- [x] C1-05 기본 HUD 레이어 확인  
  파일: `qt/onroad/hud.cc`  
  확인: set speed/current speed

- [x] C1-06 실험모드 버튼 상태 연동 확인  
  파일: `qt/onroad/buttons.cc`  
  확인: `carrot_experimental_mode` OR 연동

- [x] C1-07 카메라 베이스 스트림 계층 확인  
  파일: `qt/widgets/cameraview.cc`  
  확인: Vision IPC 수신, YUV->RGB, 프레임 draw

### 3.3 C2 Carrot 전용 NVG 오버레이(`selfdrive/ui/carrot.cc`)

- [x] C2-01 오버레이 전체 draw order 확인  
  확인: `ui_draw(...)`에서 Path/Lane/Desire/BlindSpot/Plot/HUD/Date/Device/Alert 호출 순서

- [x] C2-02 `DrawPlot` 확인  
  확인: `ShowPlotMode` 기반 그래프(가속/스티어/리드 등 모드별 데이터)

- [x] C2-03 `PathEndDrawer` 확인
- [x] C2-04 `LaneLineDrawer` 확인 (`ShowLaneInfo`)
- [x] C2-05 `PathDrawer` 확인 (`ShowPathMode/Color/...`)
- [x] C2-06 `TurnInfoDrawer` 확인 (`xTurnInfo`, `xDistToTurn`, TBT 블록)
- [x] C2-07 `DesireDrawer` 확인 (턴/차선변경/blink)
- [x] C2-08 `BlindSpotDrawer` 확인 (BSD/차선변경 경고)
- [x] C2-09 `DrawCarrot::updateState` 확인 (`carrotMan` 필드 매핑)
- [x] C2-10 `DrawCarrot::drawHud` 확인 (속도/기어/갭/모드/LIMIT/APM/APN/신호/device card)
- [x] C2-11 `drawRadarInfo` 확인 (`ShowRadarInfo`)
- [x] C2-12 `drawDateTime` 확인 (`ShowDateTime`)
- [x] C2-13 `drawDeviceInfo` 확인 (`ShowDebugUI` 조건)
- [x] C2-14 `drawTpms2/3` 확인 (`ShowTpms`)
- [x] C2-15 `ui_draw_alert`, `ui_update_alert` 확인
- [x] C2-16 `BorderDrawer`/`ui_draw_border` 확인 (상하단 텍스트, 조향/가속 바)

### 3.4 C3 표시모드/입력 이벤트

- [x] C3-01 DISPLAY 명령 처리 확인  
  파일: `qt/onroad/onroad_home.cc`  
  확인: `DEFAULT/ROAD/MAP/FULLMAP/TOGGLE` -> `_current_carrot_display`

- [x] C3-02 화면 탭 입력으로 파라미터 토글 확인  
  파일: `qt/onroad/onroad_home.cc`  
  확인: `ShowDateTime`, `ShowDeviceState`, `MyDrivingMode`, `LongitudinalPersonality`

- [x] C3-03 RECORD 명령 처리 확인  
  파일: `qt/onroad/annotated_camera.cc`  
  확인: `RECORD START/STOP/TOGGLE` -> recorder 제어

- [x] C3-04 Home 사이드바/표시모드 연동 확인  
  파일: `qt/home.cc`  
  확인: `_current_carrot_display`에 따른 sidebar visibility

### 3.5 C4 맵/네비 오버레이

- [x] C4-01 MapPanel 표시 제어 확인  
  파일: `qt/maps/map_panel.cc`  
  확인: `requestVisible`, `mapPanelRequested` 연동

- [x] C4-02 MapWindow carrot 연동 확인  
  파일: `qt/maps/map.cc`  
  확인: `ActiveCarrot` 기반 nav 상태, `uiState()->scene._current_carrot_display = 3`

- [x] C4-03 Carrot speed visualization 레이어 확인  
  파일: `qt/maps/map.cc`  
  확인: `carrotSpeedSource`, `carrotSpeedLayer`, `/dev/shm/params`의 `CarrotSpeedViz`

- [x] C4-04 네비 instruction/ETA 위젯 확인  
  파일: `qt/maps/map_instructions.cc`, `qt/maps/map_eta.cc`  
  확인: 아이콘/차선/거리/ETA UI

### 3.6 C5 녹화 인디케이터

- [x] C5-01 레코더 오버레이 도트 렌더 확인  
  파일: `qt/screenrecorder/screenrecorder.cc`  
  확인: `paintEvent`, 빨강/검정 점멸, `toggle/start/stop`, 20분 로테이션

### 3.7 C6 사운드 체감 요소

- [x] C6-01 carrot countdown 사운드 규칙 확인  
  파일: `ui/soundd.py`  
  확인: `update_carrot_alert`, `leftSec` 기반 `audio10..1`, `longDisengaged` 매핑

### 3.8 C7 서버/웹 HUD 파이프라인

- [x] C7-01 WS 서버 엔드포인트 확인  
  파일: `selfdrive/carrot/carrot_server.py`  
  확인: `async def ws_carstate`, `/ws/carstate` 라우팅

- [x] C7-02 `ws_carstate` payload 필드 전수 확인  
  파일: `selfdrive/carrot/carrot_server.py`  
  확인: `vEgo`, `vSetKph`, `gear`, `gpsOk`, `cpuTempC`, `memPct`, `diskPct`, `diskLabel`, `tfGap`, `tfBars`, `driveMode`, `tlight`, `redDot`, `temp`, `speedLimitKph`, `speedLimitOver`, `apm`

- [x] C7-03 송신 주기 확인  
  파일: `selfdrive/carrot/carrot_server.py`  
  확인: `await asyncio.sleep(0.1)` (10Hz)

- [x] C7-04 WebRTC 요청 확인  
  파일: `selfdrive/carrot/web/app.js`  
  확인: `const url = "/stream"`, `cameras: ["road"]`

- [x] C7-05 웹 HUD WS 소비 확인  
  파일: `selfdrive/carrot/web/app.js`, `hud_card.js`  
  확인: `CAR_WS = new WebSocket(.../ws/carstate)`, `drivingHudUpdateFromCarPayload`, `window.DrivingHud.update(payload)`

### 3.9 C8 앱 소비 파이프라인

- [x] C8-01 Flutter WebRTC 화면 확인  
  파일: `lib/widgets/webrtc_drive_screen.dart`  
  확인: `http://<ip>:7000` 로드, 페이지에서 카메라 카드만 노출

- [x] C8-02 Flutter HUD 카드 WS 소비 확인  
  파일: `lib/widgets/home_hud_preview_card.dart`  
  확인: `ws://$ip:7000/ws/carstate`, `_HudSnapshot.fromWs`

- [x] C8-03 Android 네이티브 HUD WS 소비 확인  
  파일: `android/.../OverlayHudService.kt`  
  확인: `.url("ws://$host:7000/ws/carstate")`, `applyPayloadText(raw)`

## 4. `ws_carstate` 필드 상태 체크(현재 코드 기준)

| 필드 | 상태 | 현재값 성격 | 비고 |
|---|---|---|---|
| `vEgo`, `vSetKph`, `gear`, `gpsOk` | 사용중 | 실데이터 | 앱/웹에서 표시중 |
| `cpuTempC`, `memPct`, `diskPct`, `diskLabel` | 사용중 | 실데이터 | DISK/VOLT 토글 반영 |
| `tfGap`, `tfBars`, `driveMode` | 사용중 | 실데이터 | 모드/바 표시 반영 |
| `temp` | 사용중 | 실데이터 | source/speed/decel |
| `tlight` | 제한 | 현재 고정(`off`) | 확장 필요 |
| `redDot` | 제한 | 현재 고정(`False`) | 확장 필요 |
| `speedLimitKph`, `speedLimitOver` | 제한 | 현재 고정(`None/False`) | 확장 필요 |
| `apm` | 제한 | 현재 고정(공백) | 확장 필요 |

## 5. 결론(이번 체크리스트 기준)

1. 온로드 그래픽 핵심 체인 + 모드 제어 + 맵 연동 + 녹화점 + 오디오 + WS/앱 소비까지 전수 체크 완료.
2. "지금 바로 동일 구현 가능한 것"과 "서버 필드 확장 필요"의 경계가 명확해짐.
3. 이후 구현요구는 이 문서의 체크 ID(C0~C8)와 매트릭스 ID(E01~E23)를 함께 사용해 추적 가능.

## 6. 순차 구현요구 대응 규칙

앞으로 구현요구가 들어오면 아래 순서로 문서를 갱신한다.

1. 요구를 E-ID/C-ID에 매핑
2. 대상 파일 경로와 수정 후보 함수 지정
3. 데이터 계약 변경 여부(`ws_carstate`) 체크
4. 구현 후 체크 상태를 `완료/부분/대기`로 갱신
5. 리그레션 영향(맵/레코더/HUD/오디오)을 교차 기록
