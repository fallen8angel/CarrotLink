# CarrotPilot 온로드 화면 요소 구현 가능성 매트릭스 (2026-03-02)

최종 분석일: 2026-03-02  
분석 대상:
- 원본: `d:/CarrotLink/c3-v10-wip`
- 앱: `d:/CarrotLink/CarrotLink-dev`

## 1. 문서 목적

이 문서는 CarrotPilot 온로드(주행) 화면의 그래픽/텍스트 요소를 기준으로,
CarrotLink 앱에서 어떤 항목을 "지금 바로", "필드 확장 후", "렌더 스트림 전환 시" 구현할 수 있는지 정밀 분류한다.

## 2. 현재 렌더링 구조 요약

### 2.1 원본(CarrotPilot) 렌더링

원본 온로드 화면은 장치 내부에서 직접 렌더링된다.

- 카메라 프레임: `selfdrive/ui/qt/onroad/annotated_camera.cc`
- 모델/오버레이: `model.draw(...)` + `ui_draw(...)`
- 주요 집합 렌더 진입: `selfdrive/ui/carrot.cc`의 `ui_draw(...)`

핵심 호출 지점:
- `CameraWidget::paintGL()` (`annotated_camera.cc`)
- `model.draw(...)` (`annotated_camera.cc`)
- `ui_draw(s, &model, width(), height())` (`annotated_camera.cc`)

`ui_draw(...)`에서 실제로 아래 요소들이 그려진다:
- 경로/차선/로드엣지/차로끝/의도 아이콘
- HUD 카드(속도/기어/갭/주행모드/제한속도/APM/APN 등)
- 레이더 정보 오버레이
- 날짜/시간
- 디바이스 상태
- 경고(alert)
- 디버그 텍스트

### 2.2 현재 앱(CarrotLink) 표시 경로

- 카메라: WebRTC (웹뷰 기반)
  - `lib/widgets/webrtc_drive_screen.dart`
  - `selfdrive/carrot/web/app.js`에서 `/stream`로 road 카메라 요청
- HUD 데이터: `ws://<ip>:7000/ws/carstate`
  - 서버: `selfdrive/carrot/carrot_server.py`
  - 앱: `lib/widgets/home_hud_preview_card.dart`, `OverlayHudService.kt`

즉, 현재 구조는 "카메라 영상 + 제한된 상태값(WS)" 조합이다.

## 3. 구현 수준 정의

- `L1`: 현재 코드/데이터로 즉시 구현 가능
- `L2`: 서버(`ws_carstate`) 필드 확장 후 구현 가능
- `L3`: 원본 렌더 스트림(합성 프레임) 도입 또는 대규모 재구현 필요

## 4. 화면 요소 매트릭스

| ID | 요소 | 원본 구현 위치 | 현재 데이터 소스 | 수준 | 비고 |
|---|---|---|---|---|---|
| E01 | 로드 카메라 영상 | `annotated_camera.cc` + webrtc | `/stream` road track | L1 | 이미 구현됨 |
| E02 | 현재 속도 | `drawHud` | `ws_carstate.vEgo` | L1 | 앱에서 km/h 변환 표시 |
| E03 | 설정 속도 | `drawHud` | `ws_carstate.vSetKph` | L1 | 이미 파싱됨 |
| E04 | 적용 속도/소스(eco 등) | `drawHud` | `ws_carstate.temp` | L1 | source/speed/is_decel 사용 |
| E05 | 기어(D/N/R/단수) | `drawHud` | `ws_carstate.gear` | L1 | 이미 파싱됨 |
| E06 | GPS 상태 | `drawHud` | `ws_carstate.gpsOk` | L1 | OK/미고정 표시 가능 |
| E07 | 갭 숫자/바 | `drawHud` | `ws_carstate.tfGap/tfBars` | L1 | 이미 파싱됨 |
| E08 | 주행모드(Eco/Safe/Normal/Sport) | `drawHud` | `ws_carstate.driveMode` | L1 | 이미 파싱됨 |
| E09 | CPU/MEM/DISK/VOLT | `drawHud`, `drawDeviceInfo` | `ws_carstate.cpuTempC/memPct/diskPct/diskLabel` | L1 | DISK/VOLT 토글 포함 |
| E10 | 날짜/시간 | `drawDateTime` | 앱 로컬 시계 or 신규 WS | L1/L2 | 로컬 렌더 가능, 원본과 완전동기는 L2 |
| E11 | 신호등 점(red/green) | `drawHud` | `ws_carstate.tlight` | L2 | 현재 서버는 `off` 고정값 |
| E12 | 빨간 점(redDot) | `drawHud` | `ws_carstate.redDot` | L2 | 현재 서버는 `False` 고정값 |
| E13 | 제한속도 박스/CAM 경고 | `drawHud`, `drawSpeedLimit` | `speedLimitKph/speedLimitOver` + sign type/dist | L2 | 현재 서버는 `None/False` 고정값 |
| E14 | APM/APN 표시 | `drawHud` | `ws_carstate.apm` 또는 상태코드 | L2 | 현재 서버는 공백 고정값 |
| E15 | 상단 플롯 그래프 | `DrawPlot` | 별도 시계열 필드 필요 | L2 | 데이터/샘플링 규격 추가 필요 |
| E16 | 레이더 객체 속도/거리 오버레이 | `drawRadarInfo` | 투영 좌표 + 값 필요 | L2/L3 | 서버에서 좌표까지 계산해 주면 L2 |
| E17 | 차선/경로/로드엣지 | `drawPath`, `drawLaneLine` | 모델 좌표/투영점 필요 | L3 | 재구현 난도 높음 |
| E18 | 차로끝/차선변경 의도 아이콘 | `drawPathEnd`, `drawDesire` | desire/lane-change 상태 + 좌표 | L2/L3 | 간단 아이콘은 L2, 위치투영은 L3 |
| E19 | 블라인드스팟 바리어 | `drawBlindSpot` | 좌/우 blindspot + 투영좌표 | L2/L3 | 단순 경고 아이콘은 L2 가능 |
| E20 | 턴/TBT 대형 블록 | `drawTurnInfo` | carrotMan 계열 필드 필요 | L2 | xTurnInfo, xDistToTurn 등 노출 필요 |
| E21 | Alert 텍스트 1/2 | `ui_draw_alert` | alert 텍스트/레벨 필드 필요 | L2 | 현재 ws_carstate 미포함 |
| E22 | 상하단 보더 디버그 텍스트 | `ui_draw_border` | 여러 sm/params 필드 필요 | L2 | 문자열 합성 필드로 축약 가능 |
| E23 | TPMS 4륜 | `drawTpms*` | TPMS 필드 필요 | L2 | 현재 ws_carstate 미포함 |

## 5. 현재 `ws_carstate` 계약 상태

`carrot_server.py` 기준 현재 payload 핵심:
- 실데이터: `vEgo`, `vSetKph`, `gear`, `gpsOk`, `cpuTempC`, `memPct`, `diskPct`, `diskLabel`, `tfGap`, `tfBars`, `driveMode`, `temp`
- 고정/placeholder: `tlight="off"`, `redDot=False`, `speedLimitKph=None`, `speedLimitOver=False`, `apm=" "`
- 송신 주기: `await asyncio.sleep(0.1)` (약 10Hz)

## 6. 권장 구현 전략

### 6.1 "원본 느낌" 우선 (현실적 1차)

다음을 우선 고정 구현:
- E01~E10 (L1)
- E11~E14 중 데이터 계약만 확장해 빠르게 활성화

장점:
- 기존 구조 유지
- 구현/테스트 속도 빠름
- 성능/안정성 관리 용이

### 6.2 "원본 완전 동일" 우선

선택지:
- 합성된 온로드 렌더 결과를 별도 비디오 스트림으로 송출
- 앱은 해당 스트림을 가로 전체 렌더

장점:
- 시각 동등성 최고  
단점:
- 송출 파이프라인 변경 범위 큼
- 디버깅/대역폭/지연 고려 필요

## 7. 다음 분석 라운드에서 받을 요구 포맷(권장)

요구를 아래 형식으로 주면 바로 반영 가능:

1. 우선순위 요소 ID: `E..` 목록
2. 목표 수준: `L1/L2/L3`
3. 화면 배치 기준: `좌상/우상/하단 카드/전체 오버레이`
4. 동작 조건: `onroad only / always / alive 조건`
5. 업데이트 주기 요구: 예) `10Hz`, `2Hz`

---

이 문서는 1차 베이스라인이며, 이후 요청사항을 누적해 상세 설계 문서로 확장한다.

체크리스트 전수판:
- `CARROTPILOT_ONROAD_FULL_CHECKLIST_2026-03-02_KO.md`

정합성/성능 최소화 데이터채널 계획:
- `CARROTPILOT_DATACHANNEL_PERF_PLAN_2026-03-02_KO.md`

## 8. 분석 커버리지와 현재 누락 후보

### 8.1 현재 커버된 범위 (핵심)

- 온로드 메인 렌더 체인
  - `qt/onroad/annotated_camera.cc` -> `ui_draw(...)`
  - `ui/carrot.cc`의 HUD/경로/레이더/디버그/TPMS/alert 경로
- 온로드 화면 전환/디스플레이 모드
  - `qt/onroad/onroad_home.cc`
  - `qt/home.cc`의 `_current_carrot_display` 연계
- 앱 측 수신/표시 경로
  - `ws/carstate` 소비 (`home_hud_preview_card.dart`, `OverlayHudService.kt`)
  - WebRTC 카메라 표시 (`webrtc_drive_screen.dart`)

### 8.2 보완된 항목(체크리스트 문서로 확장)

아래 항목은 전수 체크리스트 문서에서 보완 완료:

1. 맵 시각화 계층
- `qt/maps/map.cc`, `qt/maps/map_panel.cc`, `qt/maps/map_instructions.cc`, `qt/maps/map_eta.cc`

2. 레코더 오버레이(녹화점)
- `qt/screenrecorder/screenrecorder.cc`
- `qt/onroad/annotated_camera.cc`의 `RECORD START/STOP/TOGGLE`

3. 보더 레이어 세부
- `ui/carrot.cc`의 `ui_draw_border(...)`, `BorderDrawer`

4. 오디오 체감 요소
- `ui/soundd.py`의 carrot countdown alert

### 8.3 결론 (문서 역할 분리)

- 이 문서는 "요소별 구현 가능성 매트릭스(E01~E23)"를 유지하는 요약 문서다.
- 전수 근거/체크 상태는 `CARROTPILOT_ONROAD_FULL_CHECKLIST_2026-03-02_KO.md`를 기준으로 관리한다.

## 9. 현재 구현 상태 스냅샷 (2026-03-04, 실코드 기준)

기준 코드:
- 앱: `lib/screens/drive/live_drive_canvas_screen.dart`
- 사이드카: `assets/sidecar/carrotlink_sidecar.py`

상태 정의:
- `완료`: 실제 화면에서 렌더 경로가 동작 중
- `부분`: 일부만 구현/원본 1:1 정책 미완
- `미구현`: 데이터는 있거나 분석은 되었지만 화면 렌더 미구현

| ID | 상태 | 비고 |
|---|---|---|
| E01 | 완료 | live 카메라(WebRTC/네이티브 디코더) 표시 |
| E02 | 완료 | 속도 HUD 값 표시(홈 HUD 경로) |
| E03 | 완료 | 설정속도 표시(홈 HUD 경로) |
| E04 | 완료 | eco/source 계열 표시(홈 HUD 경로) |
| E05 | 완료 | 기어 표시(홈 HUD 경로) |
| E06 | 완료 | GPS 상태 표시(홈 HUD 경로) |
| E07 | 완료 | 갭 숫자/바 표시(홈 HUD 경로) |
| E08 | 완료 | 주행모드 표시(홈 HUD 경로) |
| E09 | 완료 | CPU/MEM/DISK/VOLT 계열 표시(홈/HUD 카드) |
| E10 | 완료 | 날짜/시간 표시(홈 HUD 경로) |
| E11 | 미구현 | `tlight`는 아직 고정값 기반, 온로드 1:1 미완 |
| E12 | 미구현 | `redDot` 온로드 1:1 미완 |
| E13 | 미구현 | 제한속도 박스/CAM 경고 온로드 1:1 미완 |
| E14 | 미구현 | APM/APN 온로드 1:1 미완 |
| E15 | 미구현 | 상단 플롯 그래프 미구현 |
| E16 | 부분 | 리드 박스/레이더 배지/거리/속도 + xState 정책 + 정지거리(`desiredDistance`) 마커 반영, 실차 1:1 검증 진행 중 |
| E17 | 부분 | 패스/차선/로드엣지 투영 렌더 구현, 원본과 완전 동등(정책/표현) 검증은 진행 중 |
| E18 | 미구현 | Desire/PathEnd 아이콘류 미구현 |
| E19 | 미구현 | BlindSpot 바리어 미구현 |
| E20 | 미구현 | Turn/TBT 대형 블록 미구현 |
| E21 | 미구현 | Alert Text1/2 전용 온로드 레이어 미구현 |
| E22 | 미구현 | 상하단 border 디버그 텍스트 미구현 |
| E23 | 미구현 | TPMS 4륜 미구현 |

추가 메모:
- 레이더 주황색(`0xFFFFA726`)은 구현되어 있음.
- 경로패스의 정지거리 전용 마커(`desiredDistance/tFollow` 라인+레이블)는 구현됨.
