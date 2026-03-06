# CarrotLink 주행화면 AR-Style 내비 오버레이 계획서 (2026-03-06)

최종 분석일: 2026-03-06  
분석 기준:
- 앱: `E:\CarrotLink\CarrotLink`
- openpilot: `E:\Carrotpilot\openpilot`

## 1. 배경과 목표

요구사항:
1. 폰 카메라(ARCore/ARKit) 기반은 사용하지 않음  
2. Tmap API 직접 호출 없이 구현  
3. `openpilot/comma`의 주행 데이터(로드카메라, 경로, IMU/자세 관련 데이터)를 활용해  
   폰 주행화면에서 "AR처럼 보이는" 시각 안내를 먼저 구현  
4. 폰에서 검증 후 comma 화면(UI)에도 동일 개념 이식

본 문서는 위 조건에서의 현실적인 구현 경로를 확정한다.

## 2. 이전 검토(일반 AR) 문서화 요약

이전 답변 요지:
1. 진짜 월드앵커 AR(실외 정합)은 `Flutter 단독`보다 `Native AR(ARCore/ARKit)` 또는 `Unity`가 안정적  
2. 다만 현재 요구사항처럼 "주행영상 위 AR-like"는 **진짜 AR 엔진 없이도 구현 가능**  
3. 따라서 본 과제는 AR SDK보다 **카메라-경로 좌표 투영 파이프라인**이 핵심

결론:
- 이번 범위에서는 ARCore/ARKit를 1차 필수 요소로 보지 않는다.
- 우선 `openpilot`의 기존 투영/경로 정보를 모바일 렌더러로 재사용하는 것이 최적이다.

## 3. 코드 사실관계 (E:\Carrotpilot\openpilot 기준)

### 3.1 이미 존재하는 데이터/렌더 기반

1. `carrotMan`에 내비 정보가 게시됨  
   - 파일: `selfdrive/carrot/carrot_serv.py`
   - 필드: `xTurnInfo`, `xDistToTurn`, `szTBTMainText`, `naviPaths` 등
   - `naviPaths` 포맷: `x,y,d;x,y,d;...` (ego 기준 경로 포인트 문자열)

2. openpilot UI가 이미 경로를 화면 좌표로 투영함  
   - 파일: `selfdrive/ui/carrot.cc`
   - 흐름: `carrotMan.getNaviPaths()` 파싱 -> `mapToScreen(...)` -> 경로/아이콘 draw

3. 카메라 화면 비율/투영 기본 행렬 로직 존재  
   - 파일: `selfdrive/ui/qt/widgets/cameraview.cc`
   - 함수: `calcFrameMatrix()`

4. 서비스 정의에 내비/경로 서비스 존재  
   - 파일: `cereal/services.py`
   - 관련: `navInstruction`, `navRoute`, `navRouteNavd`, `navInstructionCarrot`, `carrotMan`

### 3.2 CarrotLink 현재 상태

1. 사이드카는 현재 `p2/p3`에서 `carState`, `modelV2`, `lateralPlan`, `liveCalibration`,
   `roadCameraState`, `wideRoadCameraState` 등을 전달
   - 파일: `assets/sidecar/carrotlink_sidecar.py`

2. 단, 현재 사이드카 라이브 payload에 `carrotMan/navInstructionCarrot/navRoute`는 미포함
   - 즉, 내비 문구/턴 거리/명시적 경로선은 앱에서 아직 직접 못 받는 상태

3. 앱(`live_drive_canvas_screen.dart`)은 이미 카메라+오버레이 투영 파이프라인을 보유
   - `overlay2d` + `modelV2` 기반 path/lane/radar 렌더 가능

## 4. 기술 판단

판단: **구현 가능(높음)**  
이유:
1. 경로 데이터 생성(`carrotMan.naviPaths`)과 화면 투영(`mapToScreen` 계열)이 openpilot에 이미 존재
2. CarrotLink 앱도 실시간 오버레이 렌더 기반이 완성되어 있어 내비 레이어 추가 난이도만 남음
3. Tmap API 직접 연동 없이도, openpilot 내부 내비 산출물(carrotMan/navInstruction)만으로 MVP 가능

## 5. 목표 아키텍처 (폰 1차)

## 5.1 데이터 경로

1. comma/openpilot -> sidecar(`/ws/live`)  
2. sidecar payload 확장:
   - `carrotMan` (필수)
   - `navInstructionCarrot` (권장)
   - `navRoute` or `navRouteNavd` (옵션, 디버그/보강)
3. 앱 `LiveDriveCanvasScreen`에서 수신 후 `DriveNavOverlaySnapshot` 생성

## 5.2 렌더 경로

1. 기존 카메라 배치/투영 행렬(앱의 `_buildTransform`, `_mapToScreen`) 재사용  
2. `naviPaths(x,y,d)`를 전방 구간(예: 3~120m)으로 잘라 경로 폴리곤/화살표로 렌더  
3. `xTurnInfo`, `xDistToTurn`, `szTBTMainText`로 TBT 표지판 렌더  
4. `overlay2d` path/lane과 내비 경로를 레이어 분리:
   - base: openpilot path/lane
   - top: nav corridor + turn marker

## 5.3 IMU/자세 데이터 활용

1. 1차(MVP): `liveCalibration + camera/model frame` 기반으로 충분히 구현 가능  
2. 2차(고급): `liveLocationKalman`/자세값을 받아 turn marker 흔들림 완화(저역통과/가중 보정)  
3. raw `sensorEvents`는 폰 측 직접 활용보다 openpilot 추정값(`liveLocationKalman`) 사용이 안정적

## 6. 구현 단계 (권장)

## 단계 A: 데이터 계약 확장 (1~2일)

수정 파일:
1. `assets/sidecar/carrotlink_sidecar.py`

작업:
1. `PROFILE_SERVICES`의 `p2/p3`에 `carrotMan`, `navInstructionCarrot` 추가
2. `_build_live_payload()`에 위 payload 직렬화 추가
3. payload 크기 증가 모니터링(전송 주기/프레임 드랍 영향 체크)

완료 기준:
1. 앱 로그에서 `carrotMan.naviPaths`, `xTurnInfo`, `xDistToTurn` 수신 확인

## 단계 B: AR-like 내비 레이어 MVP (2~4일)

수정 파일(앱):
1. `lib/screens/drive/live_drive_canvas_screen.dart`
2. (신규 권장) `lib/screens/drive/drive_nav_overlay.dart` 또는 동일 파일 내 private class

작업:
1. `naviPaths` 파서 구현 (`x,y,d` 튜플 리스트)
2. 경로-카메라 투영 후 폴리라인/리본 렌더
3. 턴 표지판(좌/우/유턴/도착) + 남은 거리 카드 렌더
4. 기존 `webrtc/openpilot` 모드 정책 유지 (렌더 레이어만 추가)

완료 기준:
1. 턴 직전/교차로 구간에서 경로선과 실제 차선 진행 방향이 일치
2. 급회전 구간에서 프레임 드랍/깜빡임이 허용 범위 내

## 단계 C: 안정화/튜닝 (3~5일)

작업:
1. 품질 게이팅:
   - frame gap 과다 시 내비 레이어 알파 다운
   - `naviPaths` stale(예: 2초 이상 갱신 없음) 시 숨김
2. 시인성 튜닝:
   - 낮/밤 컬러 세트
   - 곡률 기반 굵기/투명도 조절
3. 진단 로그:
   - `logs/camera_errors`와 동일하게 nav overlay 상태 덤프 추가

완료 기준:
1. 멀티윈도우/저성능 기기에서 안정 동작
2. 오검출(엉뚱한 방향표시) 최소화

## 단계 D: comma UI 이식 (2차)

대상:
1. `selfdrive/ui/carrot.cc` (기존 내비 draw 확장)

원칙:
1. 폰에서 검증한 경로 보간/스무딩 파라미터를 동일 적용
2. 좌표계는 openpilot 원본 로직(`mapToScreen`) 우선 재사용

## 7. 성능/품질 목표

1. 렌더 추가 비용: 평균 2ms/frame 이내(폰 기준)  
2. 오버레이 갱신 지연: 150ms 이내  
3. 경로 stale 감지: 2초  
4. 경로 투영 포인트 수: 40~120개 동적 제한

## 8. 리스크와 대응

1. 리스크: `naviPaths` 형식/단위 변경 가능  
   - 대응: 파서 버전/유효성 검사 + fail-safe(레이어 숨김)

2. 리스크: 카메라 소스(road/wideRoad) 변경 시 정합 흔들림  
   - 대응: camera kind별 별도 파라미터 세트 유지

3. 리스크: route 정보 없을 때 표시 품질 저하  
   - 대응: fallback을 `model path only`로 자동 전환

4. 리스크: 전송량 증가로 프레임 저하  
   - 대응: carrot payload는 10Hz 이하 샘플링 옵션 제공

## 9. 즉시 실행 항목 (다음 작업)

1. sidecar payload에 `carrotMan/navInstructionCarrot` 추가  
2. 앱에서 `naviPaths` 파싱 + 단순 폴리라인 렌더(색상 1종)  
3. `xTurnInfo/xDistToTurn` 카드 표시  
4. 주행 로그 기반 정합성 체크 리포트 작성

## 10. 내비 데이터 활용 범위 (세부 보강)

아래는 `E:\Carrotpilot\openpilot` 기준으로, 앱에서 바로 활용 가능한 내비/경로 데이터다.

### 10.1 활용 가능한 주요 필드

1. `carrotMan` (`cereal/custom.capnp`)
   - 턴/분기: `xTurnInfo`, `xDistToTurn`, `xTurnCountDown`, `szTBTMainText`
   - 속도/규제: `nRoadLimitSpeed`, `xSpdType`, `xSpdLimit`, `xSpdDist`, `xSpdCountDown`, `vTurnSpeed`, `szSdiDescr`
   - 진행도: `nGoPosDist`, `nGoPosTime`, `leftSec`
   - 위치/자세 기반: `xPosLat`, `xPosLon`, `xPosAngle`, `xPosSpeed`
   - 경로: `naviPaths` (`x,y,d;x,y,d;...`)

2. `navInstruction`/`navInstructionCarrot` (`cereal/log.capnp`)
   - 안내문: `maneuverPrimaryText`, `maneuverSecondaryText`
   - 조작 타입: `maneuverType`, `maneuverModifier`
   - 거리/시간: `maneuverDistance`, `distanceRemaining`, `timeRemaining`, `timeRemainingTypical`
   - 차선/규제: `lanes`, `showFull`, `speedLimit`, `speedLimitSign`
   - 세부 단계: `allManeuvers`

3. `navRoute`/`navRouteNavd` (`cereal/log.capnp`)
   - 경로 폴리라인: `coordinates[] {latitude, longitude}`

### 10.2 데이터 -> AR 스타일 요소 매핑

1. `naviPaths` / `navRoute.coordinates`
   - 전방 경로 리본, 분기 진입 라인, 진행 방향 화살표 스트립

2. `xTurnInfo`, `maneuverType`, `maneuverModifier`
   - 좌/우회전, 유턴, 도착, 합류/분기 아이콘(상단 혹은 전방 게이트)

3. `xDistToTurn`, `maneuverDistance`
   - 거리 카운트다운(카드/원형 게이지/바)

4. `lanes`, `showFull`
   - 추천 차선 하이라이트(비추천 차선 디밍)

5. `speedLimit`, `nRoadLimitSpeed`, `xSpd*`, `szSdiDescr`
   - 제한속도 배지, 단속/주의구간 마커, 과속 경고 색상 단계

6. `distanceRemaining`, `timeRemaining`, `nGoPosDist`, `nGoPosTime`
   - 도착 정보 칩(잔여 거리/ETA), 종점 비컨

7. `xPosAngle`, `xPosSpeed` + `liveCalibration` + `roadCameraState`
   - 오버레이 흔들림 보정, 시점 정합 안정화, 곡률 기반 강조

8. `vTurnSpeed`
   - 회전/진입 구간 권장 감속 시각화

### 10.3 ARCore/ARKit 관련 정리 (용어 혼선 방지)

1. "폰 카메라를 쓰지 않는다" 조건이면 ARCore/ARKit는 필수 아님
2. 본 계획의 1차 목표는 "진짜 월드앵커 AR"이 아니라 "주행영상 위 AR-like 오버레이"
3. 따라서 핵심은 AR SDK가 아니라 `openpilot 경로 데이터 + 카메라 좌표 투영 + 렌더 안정화`
4. 추후 진짜 공간 고정형 AR이 필요할 때만 ARCore/ARKit를 별도 트랙으로 검토

## 11. ARmap 저장소 코드 분석 결과 (`https://github.com/Jin1751/ARmap`)

분석 기준:
- 클론 경로: `E:\CarrotLink\external\ARmap`
- 확인 파일:
  - `app/src/main/java/com/example/armap/*.java`
  - `app/src/main/res/layout/*.xml`
  - `app/build.gradle`, `unityLibrary/build.gradle`, `unityLibrary/src/main/AndroidManifest.xml`

### 11.1 구조/동작 요약

1. 앱 구조는 Android(Java) + Unity(`unityLibrary`) 하이브리드
2. Android 측에서 TMap API로 POI 검색/경로(`PEDESTRIAN_PATH`)를 받아 좌표 리스트를 생성
3. `StartNavi.PathRequestThread`에서:
   - 전체 경로점(`allPoints`)
   - 분기 설명 텍스트(`descriptions`)
   - 설명 포인트(`descriptionPoints`)
   를 구성
4. `UnityHandler`가 위 배열들을 `UnitySendMessage`로 `GeospatialHandler`에 전달
5. Unity/ARCore 쪽에서 Geospatial 기반으로 AR 안내판 렌더

### 11.2 우리 프로젝트 관점에서 차용 가능 요소

1. 내비 "단계 텍스트 + 단계 좌표 + 전체 폴리라인" 분리 설계
2. 단계 설명 포인트와 경로 포인트를 분리해 렌더 레이어를 다르게 주는 방식
3. 안내 이벤트(턴/도착) 단위로 오브젝트를 생성하는 파이프라인 아이디어

### 11.3 우리 프로젝트에서 그대로 차용하기 어려운 부분

1. TMap API 직접 의존 (현재 요구사항과 충돌)
2. ARCore/Geospatial + 폰 카메라 필수 전제 (현재 요구사항과 충돌)
3. Unity 빌드 산출물 중심 저장소라 유지보수/디버깅 투명성이 낮음
4. `UnitySendMessage` 문자열 기반 전달은 타입 안정성과 오류 추적성이 낮음

### 11.4 본 문서에 대한 보완 의견

1. 현재 문서 방향(AR SDK 없이 openpilot 데이터로 AR-like 구현)은 타당함
2. 다만 ARmap처럼 데이터를 아래 3계층으로 분리하는 것을 명시하면 좋음
   - route polyline layer
   - maneuver event layer
   - regulation/warning layer
3. sidecar payload 설계 시 문자열 덩어리보다 구조화(JSON dict/list) 우선
4. 앱 렌더는 "stale/지연/정합 실패" 상태를 등급화해 fail-safe 동작을 강제

## 12. 실행 관점 결론

1. ARmap의 "표현 방식"은 참고 가치가 있지만, 구현 경로는 현재 우리 조건과 다름
2. 우리 앱은 `openpilot`의 `carrotMan/navInstruction/navRoute`를 직접 받아
   Flutter 오버레이에서 렌더하는 방식이 유지보수성과 실시간성 모두 유리함
3. 1차 목표는 "폰 카메라 없이 주행영상 기반 AR-like 안내", 2차에만 AR SDK 재검토

## 13. 구현 스코프 상세 (요청 반영)

요청 반영 기준:
1. 참고 이미지와 유사한 "안내판 + 화살표 + 하단 상태 배지" 스타일 선호
2. 디테일 디자인은 추후 수정 가능
3. `webrtc`에는 적용하지 않고 `openpilot road camera`에만 적용

### 13.1 v1에서 실제 구현할 요소

1. 경로 리본(`Nav Corridor`)
   - 전방 3m~90m 구간을 폴리라인/리본으로 렌더
   - 분기점 근접 시 굵기/채도 증가

2. 분기 안내판(`Turn Gate`)
   - 초록 안내판 + 흰색 텍스트(예: "우회전 후 230m")
   - 턴 타입(좌/우/유턴/도착)에 따라 아이콘 교체

3. 진행 화살표(`Chevron Stack`)
   - 진행 방향으로 2~4개 계단형 화살표(원근감 포함)
   - 분기점까지 거리 짧아질수록 간격 축소

4. 하단 상태 배지(`Route Status Pill`)
   - "정상 경로 / 재탐색 / 도착 임박" 상태 표시
   - 경로 stale/품질 저하 시 자동 경고 문구 전환

5. 상단 텍스트 카드(`TBT Card`)
   - `xTurnInfo/xDistToTurn/szTBTMainText` 요약
   - 가독성 확보를 위해 반투명 다크 카드 + 굵은 폰트

### 13.2 v1 범위에서 제외

1. webrtc 영상 위 AR 오버레이
2. 폰 카메라/ARCore 월드앵커
3. 3D 오브젝트 쉐이더/복잡한 파티클 연출
4. openpilot 원본 코드 직접 수정(1차)

## 14. 디자인 일관성/가독성 기준

### 14.1 컬러/타이포 토큰

앱 기존 테마와 정합:
- 기본 강조색: `AppTheme.carrotOrange` (`#FF6D00`)
- 배경 계열: `#121212`, `#1E1E1E`

AR 오버레이 전용 토큰(제안):
1. `nav_board_bg = #17A84B` (안내판 초록)
2. `nav_board_text = #FFFFFF`
3. `nav_chevron = #244CFF` (화살표 파랑)
4. `nav_route_ok = #2EEA6A`
5. `nav_route_warn = #FFB020`
6. `nav_route_error = #FF4D4F`
7. `nav_shadow = rgba(0,0,0,0.45)`

타이포:
1. 기본: Noto Sans KR(앱 기본과 동일)
2. 안내판 본문: 600~700 weight
3. 거리 숫자: tabular figure 또는 숫자 고정폭 우선
4. 모든 핵심 텍스트 최소 14sp(세로 compact 기준)

### 14.2 레이아웃 규칙

1. 상단 안전영역(상태바/노치) + 16dp 아래부터 카드 배치
2. 중앙 시야 30% 영역에는 큰 불투명 패널 금지
3. 하단 배지는 하단 컨트롤/오류배너와 충돌하지 않게 동적 오프셋
4. 멀티윈도우/폴더블에서는 텍스트 2줄 허용, 아이콘은 고정 비율 유지
5. 동일 의미 요소는 모드/해상도와 무관하게 같은 위치 계열 유지

### 14.3 시인성 규칙

1. 모든 텍스트에 그림자 또는 아웃라인 적용
2. 밝은 노면에서 대비비(contrast) 4.5:1 이상 목표
3. 속도 80km/h 이상에서는 작은 보조 텍스트 자동 축소/생략
4. 경로 오차/데이터 지연 시 채도보다 명도 우선으로 경고

## 15. 좌표 지정/투영 방식 (road camera 전용, webrtc 제외)

### 15.1 모드 게이트 정책

1. `openpilot overlay mode && liveCamera == road`일 때만 AR-nav 활성화
2. `webrtc` 모드면 AR-nav projector/painter 실행 금지
3. `wideRoad` 선택 시 v1에서는 AR-nav 비활성(또는 TBT 카드만 표시)

### 15.2 좌표계/입력 데이터

입력:
1. `carrotMan.naviPaths`: `x,y,d` 점열
2. `overlay2d.laneLines[2].z` 또는 대응 z 샘플
3. `liveCalibration`, `roadCameraState`, `displayTransform`

참조 원리:
1. openpilot `carrot.cc`의 검증 경로를 따름
2. 핵심 흐름: `naviPaths parse -> idx 계산 -> z 보정 -> mapToScreen`

### 15.3 권장 투영 절차

1. `naviPaths` 파싱
   - 잘못된 포맷/NaN 제거
   - 전방 거리 기준(예: 3~120m) 필터

2. z 샘플 선택
   - `idx = getPathLengthIdx(laneLineX, d)` 방식 사용
   - `z = laneLineZ[idx] + zOffset`

3. 화면 투영
   - 앱의 기존 `_buildTransform` + `_mapToScreen`만 사용
   - 투영 불가점(`p.z <= 0`, clip 밖)은 폐기

4. 앵커 포인트 생성
   - 안내판 앵커: 18~28m 전방(턴 임박 시 10~18m)
   - 화살표 앵커: 8~35m 구간을 등간격 샘플
   - 하단 배지는 2D HUD 레이어(투영 좌표 미사용)

5. 안정화 필터
   - 점 위치 저역통과(EMA) + 거리 기반 알파
   - 연속 프레임 거리 점프 임계치 초과 시 이전 프레임 유지

### 15.4 구현 시 주의(기하 정합)

1. `live_drive_canvas_screen.dart`의 투영 수식 블록(`_buildTransform`, `_mapToScreen`)은 수정 금지 원칙
2. 적응형/레이아웃 변경은 외곽 UI만 수정, 투영 블록은 고정
3. `camera_source/displayTransform` 바뀔 때 투영 캐시 즉시 무효화

## 16. 페이즈별 상세 계획

### Phase 0. 계약 확정/샘플 캡처 (0.5~1일)

산출물:
1. sidecar payload 샘플(JSON) 5세트(직선/분기/유턴/도착/stale)
2. 필드 유효성 표(필수/옵션/단위)

완료 기준:
1. 앱 디버그에서 `naviPaths/xTurnInfo/xDistToTurn` 안정 수신 확인

### Phase 1. 데이터 파서/도메인 모델 (1~2일)

산출물:
1. `DriveNavOverlaySnapshot` 확장
2. `naviPaths` 파서 + 검증기 + stale 판별기

완료 기준:
1. 포맷 오류/누락에서도 앱 크래시 없이 fail-safe 동작

### Phase 2. 투영기(Projector) 구현 (1~2일)

산출물:
1. road camera 전용 `DriveNavProjector`
2. 앵커 포인트/리본 폴리곤 생성기

완료 기준:
1. 턴 직전 구간에서 경로 리본이 차선 진행 방향과 시각적으로 일치

### Phase 3. AR-like UI 렌더 (2~3일)

산출물:
1. Turn Gate / Chevron / Route Status / TBT Card painter/widget
2. 낮/밤 팔레트 + 텍스트 대비 튜닝

완료 기준:
1. compact/medium/expanded, 멀티윈도우에서 오버플로우 없음

### Phase 4. 최적화/진단 (1~2일)

산출물:
1. 렌더 비용 계측 로그(ms)
2. frame drop/stale 시 자동 degrade 정책
3. `camera_error` 시 nav 상태 덤프 포함

완료 기준:
1. 평균 렌더 오버헤드 목표치 충족, 시각 깜빡임 억제

### Phase 5. 현장 검증/튜닝 (지속)

산출물:
1. 주간/야간/우천 샘플 리포트
2. 오표시 사례와 재현 로그

완료 기준:
1. 치명 오표시 없음, 경고/페일세이프 동작 검증

## 17. 구조 모듈화 계획

권장 신규 구조:

`lib/features/drive_nav_overlay/`
1. `models/drive_nav_overlay_snapshot.dart`
2. `parsers/carrot_navi_paths_parser.dart`
3. `projection/drive_nav_projector.dart`
4. `painters/nav_corridor_painter.dart`
5. `painters/turn_gate_painter.dart`
6. `widgets/nav_tbt_card.dart`
7. `controller/drive_nav_overlay_controller.dart`
8. `diagnostics/drive_nav_diag_recorder.dart`

연동 지점:
1. 입력: `assets/sidecar/carrotlink_sidecar.py` payload
2. 화면: `lib/screens/drive/live_drive_canvas_screen.dart`
3. 설정(추후): HUD/주행 설정 화면에 on/off 및 디버그 토글

원칙:
1. 파싱/투영/렌더를 분리해 테스트 가능하게 구성
2. 렌더러는 immutable snapshot만 소비
3. 모드 게이트(webrtc 차단)는 controller 최상단에서 1회 처리

## 18. 최적화 계획

### 18.1 성능 예산

1. 파싱: <= 0.3ms/frame
2. 투영(최대 120점): <= 1.2ms/frame
3. 페인팅: <= 1.5ms/frame
4. 총 오버헤드: 평균 <= 3.0ms/frame 목표

### 18.2 최적화 기법

1. 객체 재사용(List/Offset 버퍼 재활용)
2. 샘플 포인트 동적 감쇠(원거리 점 간격 증가)
3. 변경 없는 프레임은 projector 스킵(프레임 ID 기반)
4. 텍스트 레이아웃 캐시(거리/문구 동일 시 재사용)
5. stale/지연 시 자동 단순 모드:
   - 리본 숨김 -> 카드만 유지 -> 최소 경고만 유지 순차 축소

### 18.3 안정성/진단

1. `camera_error` 시점에 아래 동시 저장
   - sidecar `/health`
   - tmux tail
   - nav overlay snapshot(핵심 필드)
2. projection 실패율, clip-out 비율, stale 비율 로그화
3. 회귀 테스트용 replay payload 세트 유지

## 19. 착수 체크리스트 (개발 시작용)

1. sidecar에 `carrotMan/navInstructionCarrot` 포함 여부 재확인
2. `road camera only` 게이트 코드 먼저 고정
3. 파서 + projector 단위 테스트 작성
4. 기본 UI(안내판/화살표/하단배지) 최소 렌더 우선
5. 멀티윈도우/compact 시 오버플로우 확인
6. 실주행 로그 3개 이상으로 정합 검증
7. 진단 덤프 자동 저장 동작 확인

---

이 계획은 "폰 카메라/외부 AR SDK 없이도 AR처럼 보이는 내비 오버레이"를 빠르게 구현하는 경로다.  
핵심은 새 엔진 도입이 아니라, `E:\Carrotpilot\openpilot`에 이미 있는 경로/투영 체계를 CarrotLink 화면으로 안전하게 이식하는 것이다.
