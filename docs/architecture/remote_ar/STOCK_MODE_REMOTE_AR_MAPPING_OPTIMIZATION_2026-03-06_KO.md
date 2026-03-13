# CarrotLink Stock Mode Remote AR 좌표 맵핑 / 구조 / 최적화 기준 (2026-03-06)

최종 분석일: 2026-03-06

대상:
- 앱: `E:\CarrotLink\CarrotLink`
- 장치 런타임: `E:\CarrotLink\C3-v10-wip`

이 문서는 stock 모드 remote AR를 구현할 때,

- 어떤 좌표계를 기준으로
- road camera에 어떻게 올바르게 맵핑하고
- 어떤 구조로 분리하며
- 어디서 경량화/최적화를 해야 하는지

를 명시한다.

하드 제약:
- 기존 `경로패스/차선 맵핑 수학`은 수정하지 않는다
- 기존 `camera frame sync / frameId 처리`는 수정하지 않는다
- 새 기능은 현재 projection/frame 경로 위에 additive scene/render layer로만 추가한다

## 1. 한 줄 결론

- 앱은 `raw lat/lng`를 직접 road camera에 투영하지 않는다
- 1차 기준 좌표는 `car-space (forward x, lateral y, height z)`다
- `naviPaths`는 이미 AR-like 투영에 적합한 상대 경로 입력이다
- 올바른 맵핑은 `car-space -> camera/source pixel -> canvas/screen` 순서로 처리해야 한다
- 최적화는 `semantic scene -> native projection -> native render` 구조가 핵심이다

## 2. 좌표계 기준

stock 모드 remote AR에서 최소한 다음 좌표계를 구분해야 한다.

### 2.1 세계 좌표 / GPS 좌표

- 예: `lat/lng/alt`
- 원천 route 데이터(`vrtx`)는 여기에 가깝다

이 좌표계는 원천 데이터로는 중요하지만, 앱이 road camera 위에 직접 그릴 좌표계로 쓰면 안 된다.

### 2.2 차량 기준 좌표계(car-space)

권장 기준:
- `x`: 차량 전방 거리
- `y`: 차량 중심 기준 좌우 오프셋
- `z`: 높이

이 좌표계가 실제 AR-like 렌더의 기준이 된다.

현재 코드상 `naviPaths`는 사실상 이 기준에 가까운 상대 경로다.

### 2.3 카메라 source pixel 좌표

- road/wideRoad 원본 영상의 픽셀 좌표
- 예: `1928 x 1208` 기반

camera intrinsics/extrinsics를 적용한 뒤 도달하는 중간 좌표계다.

### 2.4 앱 canvas/screen 좌표

- 실제 Android 화면 또는 native overlay surface 상의 좌표
- video fit/zoom/xOffset/yOffset까지 모두 적용된 최종 좌표

## 3. 어떤 좌표를 실제로 쓸 것인가

### 3.1 1차 기준: `carrotMan.naviPaths`

이 값의 포맷은:

```text
x,y,d;x,y,d;...
```

권장 해석:
- `x`: 전방 거리
- `y`: 좌우 오프셋
- `d`: 누적 거리 또는 거리 기반 샘플 인덱싱 기준

즉 1차 경로 리본은 `naviPaths`를 중심으로 만든다.

### 3.2 `vrtx`는 직접 그리는 좌표가 아니다

`vrtx`는 route 원본 GPS 점열이다.

이건:
- 디버그
- 원천 route 확인
- 재계산 fallback

용도로는 쓸 수 있지만, 앱이 road camera 위에 직접 그릴 주 좌표로 삼으면 안 된다.

이유:
- lat/lng는 카메라 투영 친화적이지 않다
- heading 기준 상대화가 추가로 필요하다
- 앱 쪽에서 다시 같은 가공을 반복하게 된다

### 3.3 z 값은 어떻게 정할 것인가

1차 기준:
- `laneLines` 또는 `path`의 `z`를 참조한다
- 특정 거리 `d`에 대응하는 lane/path의 `z`를 샘플링한다
- 최종 z는 `sampled_z + pathOffsetZ`

현재 코드도 이 방향에 가깝다.

즉:
- 경로 x/y는 `naviPaths`
- 높이 z는 `modelV2/laneLines/path`

를 조합하는 방식이 맞다.

## 4. road camera에 올바르게 맵핑하는 순서

올바른 맵핑은 다음 순서다.

### 4.1 Step 1: AR object를 car-space에서 정의

예:
- 경로 리본의 각 포인트: `(x, y, z)`
- 턴 게이트 중심: `(turn_x, turn_y, turn_z)`
- 속도카메라 표지: `(alert_x, alert_y, alert_z)`

중요:
- 처음부터 screen pixel로 정의하면 안 된다
- 먼저 차량 기준 3D 좌표를 만든다

### 4.2 Step 2: camera intrinsics를 정한다

현재 코드 기준 intrinsics는 source 해상도와 카메라 종류에 따라 정해진다.

핵심:
- base source: `1928 x 1208`
- road focal: `2648.0`
- wide focal: `567.0`
- principal point: `(964, 604)` 스케일 반영

즉 source 크기에 맞춰 intrinsic matrix를 재계산해야 한다.

### 4.3 Step 3: calibration / extrinsic을 적용한다

현재 기준 입력:
- `liveCalibration.rpyCalib`
- `wideFromDeviceEuler`
- `_viewFromDevice`

즉:
- `deviceFromCalib`
- `wideFromDevice`
- `viewFromCalib`

순서로 camera orientation을 만든 뒤 intrinsic과 곱해 `calibTransform`을 만든다.

road camera:
- `viewFromCalib = viewFromDevice * deviceFromCalib`

wide camera:
- `viewFromCalib = viewFromDevice * wideFromDevice * deviceFromCalib`

### 4.4 Step 4: car-space -> source pixel 투영

현재 수학은 사실상 다음과 같다.

```text
source_homogeneous = intrinsic * viewFromCalib * [x, y, z]
sx = px / pz
sy = py / pz
```

조건:
- `pz > 0`
- finite 값
- source clip margin 안에 있어야 함

여기서 clip되지 않으면 화면에 그리지 않는다.

### 4.5 Step 5: source pixel -> screen canvas 배치

투영된 source pixel을 그대로 화면에 쓰면 안 된다.

이유:
- 실제 video가 화면에서 fit/zoom/offset이 적용된 상태로 표시되기 때문

따라서 반드시:
- `cover/contain`
- viewport zoom
- x/y infinity alignment
- display transform

을 동일하게 적용해 source-to-canvas transform을 만들어야 한다.

핵심 원칙:
- camera view 배치와 overlay 배치가 같은 transform을 써야 한다

### 4.6 Step 6: 최종 screen clip 및 culling

마지막으로:
- 화면 밖
- clip margin 밖
- 너무 가까움
- 너무 멂

조건은 그리지 않는다.

## 5. road camera 정합에서 가장 중요한 규칙

### 5.1 비디오와 AR는 같은 배치 transform을 공유해야 한다

이게 가장 중요하다.

현재 코드상 video placement는:
- source size
- cover/contain
- zoom
- xOffset/yOffset

을 반영한다.

AR 오브젝트도 정확히 같은 배치 결과를 따라야 한다.

즉, video와 overlay가 서로 다른 fit 계산을 쓰면 바로 어긋난다.

### 5.2 frame sync 없는 투영은 금지

AR path는 camera frame과 model/nav frame이 충분히 맞을 때만 보여야 한다.

최소 기준:
- `roadCameraState.frameId`
- `wideRoadCameraState.frameId`
- `modelV2.frameId`
- 필요 시 nav 데이터 갱신 시각

기준 예:
- frame gap이 임계치 이상이면 AR alpha 감소
- 더 커지면 즉시 숨김

### 5.3 `naviPaths`는 z가 없으므로 z를 따로 보강해야 한다

1차에서 맞는 방식:
- 같은 거리대의 lane/path z를 참조
- `pathOffsetZ` 같은 고정 오프셋을 더함

즉 `naviPaths`를 2D로 다루면 안 되고, pseudo-3D로 보강해야 한다.

### 5.4 road / wideRoad는 서로 다른 파라미터를 가져야 한다

필수 분리 항목:
- focal
- zoom
- visible distance
- path width
- gate size
- clutter threshold

road 기준에서 맞춘 값을 wide에 그대로 쓰면 안 된다.

## 6. 좌표를 어떻게 정할 것인가

### 6.1 경로 리본

입력:
- `naviPaths`

좌표 선정 규칙:
- `x`는 2m~120m 또는 140m까지만 사용
- 너무 가까운 점은 5m 이상으로 바닥 안정화
- 너무 먼 점은 잘라낸다
- 화면 밀도에 맞춰 resample한다

z 선정:
- `laneZ` 또는 `pathZ`에서 같은 거리 위치의 z를 가져온다
- `z + pathOffsetZ`

### 6.2 턴 게이트

입력:
- `xTurnInfo`
- `xDistToTurn`
- `naviPaths`

좌표 선정 규칙:
- 우선 `naviPaths` 상에서 `xDistToTurn`과 가장 가까운 구간을 찾는다
- 그 점을 gate center로 둔다
- gate 폭은 lane width 또는 고정 width를 사용한다

z 선정:
- 해당 거리의 lane/path z

### 6.3 턴 보드

입력:
- `xTurnInfo`
- `xDistToTurn`
- `szTBTMainText`

좌표 선정 규칙:
- gate center를 기준 anchor로 잡는다
- board는 gate보다 위쪽 z 또는 screen-space y offset을 약간 더 준다

의견:
- 1차는 진짜 3D billboard보다 "projected gate anchor + 보드 offset"이 안정적이다

### 6.4 속도카메라 표지

입력:
- `xSpdType`
- `xSpdDist`

좌표 선정 규칙:
- 경로 정중앙보다 약간 우측 또는 좌측에 둔다
- 본 경로를 가리지 않도록 해야 한다

### 6.5 신호등 상태

입력:
- `trafficState`

좌표 선정 규칙:
- 실제 신호등 위치가 없으면 임의 world anchor처럼 보이게 하면 안 된다
- 1차는 stop line 근처 상단의 abstract cue로 제한한다

즉:
- 이건 완전한 world-correct AR object가 아니다
- pseudo-AR로 처리해야 한다

## 6.6 고도 / 환경 적응형 배치가 가능한가

결론:
- `예`, 1차 수준에서는 이미 가능하다
- 단, "실제 세계 절대 좌표에 고정된 AR"이 아니라 "도로/차선/경로 형상에 적응하는 pseudo-AR"로 이해해야 한다

현재 데이터로 가능한 적응:
- `liveCalibration.height` 또는 `pathOffsetZ`를 이용한 기본 높이 보정
- `laneLines.z`, `path.z`, `roadEdges.z`를 이용한 오르막/내리막 반영
- lane 폭과 road edge를 이용한 gate width/anchor 위치 보정
- turn 거리와 curvature를 이용한 board/chevron 위치 조정
- road / wideRoad 카메라별 다른 최적 배치

즉 아래는 가능하다.

- 오르막에서는 보드가 너무 낮게 깔리지 않도록 조정
- 내리막에서는 경로 리본이 도로 아래로 가라앉아 보이지 않도록 조정
- 급커브에서는 chevron과 gate가 바깥쪽으로 과하게 튀지 않도록 조정
- 차선 폭이 넓은 구간에서는 gate 폭을 넓히고, 좁은 구간에서는 줄이기

하지만 아래는 현재 데이터만으로는 제한적이다.

- 실제 신호등/표지판의 절대 위치에 정확히 고정
- 복층도로, 지하차도, 육교 구조를 지도 고도까지 반영해 완전 정합
- 주변 실제 물체 occlusion을 맞춘 world-anchor AR

정리:
- "환경에 따라 더 좋은 위치"는 충분히 가능하다
- 다만 그 환경은 1차에서는 `차선/경로/곡률/높이` 같은 주행 형상 환경이지, 완전한 3D 월드 맵 환경은 아니다

## 7. 권장 구조

구조는 아래처럼 분리하는 게 맞다.

### 7.1 ingest layer

책임:
- sidecar payload 수신
- raw map/state 파싱

### 7.2 scene builder

책임:
- `carrotMan/navInstructionCarrot/modelV2/liveCalibration`를 semantic scene으로 변환

출력 예:
- `RouteRibbonScene`
- `TurnGateScene`
- `SpeedCueScene`
- `TrafficCueScene`

### 7.3 projection layer

책임:
- semantic scene의 car-space anchor를 source pixel / screen space로 투영

### 7.4 renderer layer

책임:
- 실제 비디오와 AR object를 그리기

원칙:
- scene builder와 renderer를 섞지 않는다

## 8. 최적화 / 경량화 기준

### 8.1 절대 하지 말아야 할 것

- 매 프레임 Flutter에서 최종 polygon 수백 개를 만들어 MethodChannel로 계속 넘기기
- raw string `naviPaths`를 UI 레이어에서 반복 파싱하기
- video transform과 overlay transform을 따로 계산하기

### 8.2 권장

- Flutter는 semantic scene까지만 생성
- 투영과 최종 렌더는 native에서 처리
- `naviPaths`는 parse cache 사용
- point cap 적용
- 거리/화면 밖 culling
- object pooling
- thermal degrade 단계 정의

### 8.3 point budget

권장 예:
- 경로 포인트: 60~90개
- chevron: 최대 3개
- gate: 1개
- speed/traffic cue: 각 1개

### 8.4 update 주기 분리

- video decode: 최대 주기
- camera frame sync: high
- scene rebuild: medium
- text/state badge: low

즉 모든 것을 같은 주기로 갱신하면 안 된다.

### 8.5 payload 계약 최적화

장기적으로는:
- `naviPaths` 문자열 대신 숫자 배열 구조
- typed payload
- versioned scene contract

가 낫다.

## 9. 경계 조건 / 실패 규칙

필수 규칙:
- `frame gap` 과다 시 숨김
- `naviPaths` stale 시 숨김
- calibration 부재 시 AR downgrade
- road/wide 전환 직후 N 프레임 동안 fade-in
- clip 밖 object는 즉시 제거
- 속도카메라/신호등은 route cue보다 우선순위를 높이지 않음

## 10. 추천 변수 / 설정

- `arSceneVersion`
- `arRenderMode`
- `arEnabled`
- `arNavPathMaxPoints`
- `arNavPathMaxDistanceM`
- `arMinRenderableDistanceM`
- `arDistanceScale`
- `arPathZOffsetM`
- `arGateScreenYOffsetPx`
- `arGateWorldZOffsetM`
- `arFrameGapTolerance`
- `arNavStaleTimeoutMs`
- `arThermalDegradeLevel`
- `arCameraKindPolicy`

## 11. 내 의견

가장 중요한 건 "멋있게 그리는 것"이 아니다.

진짜 중요한 건:
- 좌표계를 혼동하지 않는 것
- video와 overlay가 같은 transform을 쓰는 것
- frame sync가 틀어졌을 때 과감히 숨기는 것

즉 AR 품질은 그리는 능력보다 "언제 안 그릴지" 규칙에서 결정된다.

## 12. 참고 문서

- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_IMPLEMENTATION_CHECKLIST_2026-03-06_KO.md`
- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_DISPLAY_DESIGN_2026-03-06_KO.md`
- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_FEASIBILITY_2026-03-06_KO.md`
- `docs/architecture/carrotpilot/TMAP_7712_CARROTPILOT_ANALYSIS_2026-03-06_KO.md`

