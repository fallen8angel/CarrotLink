# CarrotLink Stock Mode Remote AR 표시 설계 (2026-03-06)

최종 분석일: 2026-03-06

대상:
- 앱: `E:\CarrotLink\CarrotLink`
- 장치 런타임: `E:\CarrotLink\C3-v10-wip`

이 문서는 `stock 모드 원격 주행카메라` 위에 어떤 정보를 어떤 방식으로 AR-like 형태로 표시할지 정리한다.

전제:
- 폰 카메라 ARCore 기반이 아니라 원격 road/wideRoad 카메라 기반이다
- `TMAP raw ingress`보다는 `carrotMan/navInstructionCarrot`를 주 입력 계약으로 본다
- 목적은 "진짜 월드앵커 AR"이 아니라 "주행 맥락에 맞는 고정밀 remote-camera AR-like overlay"다

## 1. 한 줄 결론

- 1차 구현에서 가장 중요한 AR 정보는 `경로`, `다음 턴`, `남은 거리`다
- 데이터 소스는 `7712 raw`가 아니라, 그 결과물인 `carrotMan + navInstructionCarrot + camera calibration`가 맞다
- 사용자에게는 "도로 위에 붙는 경로 리본 + 턴 게이트 + 안내 보드" 중심으로 보여야 한다
- 속도카메라, 제한속도, 신호등, 목적지 정보는 2차 보조 AR 레이어로 붙이는 것이 맞다

## 2. 데이터 계층

AR 표시 설계는 다음 4층으로 나뉜다.

### 2.1 외부 내비 ingress

원천은 외부 내비 앱 또는 CarrotMan 계열 입력이다.

관찰된 ingest:
- `7712 TCP JSON line`
- 핵심 raw 키:
  - `vrtx`: 원본 route GPS 점열
  - `rgdata`: TBT/속도/도로/위치 메타

하지만 앱이 직접 여기를 주 계약으로 삼을 필요는 낮다.

### 2.2 carrotpilot 가공 계층

`carrot_man.py`와 `carrot_serv.py`가 외부 내비 입력을 앱 친화적인 scene state로 바꾼다.

핵심 출력:
- `carrotMan.naviPaths`
- `carrotMan.xTurnInfo`
- `carrotMan.xDistToTurn`
- `carrotMan.szTBTMainText`
- `carrotMan.nRoadLimitSpeed`
- `carrotMan.xSpdType`
- `carrotMan.xSpdLimit`
- `carrotMan.xSpdDist`
- `carrotMan.trafficState`
- `carrotMan.xPosLat`
- `carrotMan.xPosLon`
- `carrotMan.xPosAngle`
- `carrotMan.xPosSpeed`
- `navInstructionCarrot.maneuverType`
- `navInstructionCarrot.maneuverModifier`
- `navInstructionCarrot.allManeuvers`

### 2.3 sidecar 전송 계층

현재 sidecar는 이미 아래를 앱으로 전송한다.

- `carrotMan`
- `navInstructionCarrot`
- `roadCameraState`
- `wideRoadCameraState`
- `liveCalibration`
- `modelV2`
- `carState`
- `lateralPlan`

즉 1차 구현에 필요한 데이터는 이미 대부분 live payload에 있다.

### 2.4 앱 scene 계층

앱은 raw payload를 바로 렌더하지 않고, semantic scene으로 정리해서 써야 한다.

권장 scene 객체:

```json
{
  "routeRibbon": [],
  "turnCue": {},
  "speedCue": {},
  "trafficCue": {},
  "egoState": {},
  "health": {}
}
```

## 3. 무엇을 AR로 표시할 것인가

우선순위를 명확히 나눠야 한다.

### 3.1 1차 필수 AR 레이어

#### A. 경로 리본

데이터:
- `carrotMan.naviPaths`
- `modelV2`
- `liveCalibration`
- `roadCameraState`

표현:
- 도로 바닥에 붙는 초록색 반투명 리본
- 멀수록 얇고 연하게
- 가까울수록 두껍고 선명하게

사용자 체감:
- "내가 어느 차선 방향으로 진행해야 하는지"를 즉시 이해

이유:
- 가장 정보 밀도가 높고
- 운전 중 시선 이동이 가장 적고
- AR-like 효과가 가장 강하다

#### B. 턴 게이트

데이터:
- `xTurnInfo`
- `xDistToTurn`
- `szTBTMainText`
- `navInstructionCarrot`

표현:
- 교차로나 분기 전에 도로를 가로지르는 얇은 게이트
- 좌회전이면 왼쪽으로 시각 중심이 약간 치우친 형태
- 우회전이면 오른쪽 치우침

사용자 체감:
- "바로 저 지점이 다음 행동 포인트"라는 인식 강화

#### C. 턴 안내 보드

데이터:
- `xTurnInfo`
- `xDistToTurn`
- `szTBTMainText`
- `maneuverType`
- `maneuverModifier`

표현:
- 게이트 위 또는 경로 상부에 떠 있는 보드
- 예: `250m 우회전`
- 텍스트와 아이콘을 같이 표시

사용자 체감:
- AR 오브젝트의 의미를 즉시 이해

#### D. 경로 chevron

데이터:
- `naviPaths`

표현:
- 진행 방향을 따라 2~3개 정도의 chevron
- 화면 아래에서 위로 흐르는 것이 아니라, 경로 위 앞쪽으로 박혀 있는 느낌

사용자 체감:
- 회전 전 접근 감각 강화

### 3.2 2차 권장 AR 레이어

#### E. 속도카메라/단속 표지

데이터:
- `xSpdType`
- `xSpdLimit`
- `xSpdDist`
- `szSdiDescr`

표현:
- 도로 우측 숄더 쪽 소형 표지판
- 거리와 제한속도를 함께 표기

주의:
- 상시 표시하면 clutter가 심해지므로 조건부 표시가 맞다

#### F. 제한속도 배지

데이터:
- `nRoadLimitSpeed`

표현:
- 완전한 AR object보다는 AR-HUD hybrid가 맞다
- 차로 위에 띄우기보다 좌상단 또는 우상단의 고정 배지가 더 안정적이다

의견:
- 이건 "AR처럼 보이는 것"보다 "읽기 쉬운 것"이 더 중요하다

#### G. 신호등 상태 표시

데이터:
- `trafficState`

표현:
- 정지선 또는 진행 차로 상부의 작은 상태 점
- 빨강/초록/좌회전 신호 수준만 단순 표시

주의:
- 오탐/지연 리스크가 크므로 confidence가 낮으면 숨겨야 한다

### 3.3 3차 선택 레이어

#### H. 목적지 도착 존

데이터:
- `nGoPosDist`
- `nGoPosTime`
- `navInstructionCarrot.distanceRemaining`

표현:
- 도착 임박 시 경로 끝단이 넓게 열리는 finish zone

#### I. 도로명/분기명 표지

데이터:
- `szPosRoadName`
- `szNearDirName`
- `szFarDirName`

표현:
- AR 표지판처럼 만들 수는 있지만
- 1차는 일반 HUD text가 더 낫다

의견:
- 도로명은 AR object보다 카드형 정보가 더 읽기 쉽다

## 4. 어떤 정보는 AR로 만들지 않는 것이 낫다

아래는 AR 오브젝트보다 HUD가 더 적합하다.

- 현재 도로명
- ETA
- 남은 총거리
- 연결 상태
- 디버그 텍스트
- 프레임 갭/성능 상태

이유:
- 공간에 고정시킬 이유가 약하고
- 읽기 쉬움이 더 중요하고
- clutter를 빠르게 키운다

## 5. 사용자가 실제로 보게 될 화면

### 5.1 평상시 직진 구간

- 차선 위에 얇은 경로 리본만 유지
- 상시 텍스트는 최소화
- 필요 시 작은 진행 chevron만 표시

### 5.2 턴 120m~40m 전

- 경로 리본이 두꺼워짐
- turn gate가 멀리 생성됨
- 거리 보드가 작게 등장

### 5.3 턴 40m~10m 전

- gate와 보드가 가장 선명해짐
- chevron 밀도를 조금 높임
- 필요 시 차로 유도 폭을 넓힘

### 5.4 턴 직후

- 이전 turn AR object는 즉시 사라짐
- 다음 maneuver가 있으면 새 cue로 전환

### 5.5 과속카메라/신호 구간

- 경로 리본은 유지
- 보조 표지는 짧은 시간만 표시
- 본 경로보다 시각 우선순위가 높아지면 안 됨

## 6. AR layer 우선순위

가시성 우선순위:

1. 경로 리본
2. 턴 게이트
3. 턴 안내 보드
4. chevron
5. 속도카메라 표지
6. 신호등 상태
7. 제한속도/도로명 등 기타 배지

원칙:
- 한 프레임에 "읽어야 하는 핵심 의미"는 최대 1~2개만 노출
- 경로와 턴이 항상 1순위

## 7. 데이터와 AR 오브젝트 매핑

| AR 오브젝트 | 주 데이터 | 보조 데이터 | 1차 여부 |
| --- | --- | --- | --- |
| 경로 리본 | `naviPaths` | `modelV2`, `liveCalibration`, `roadCameraState` | 필수 |
| 턴 게이트 | `xTurnInfo`, `xDistToTurn` | `navInstructionCarrot` | 필수 |
| 턴 안내 보드 | `szTBTMainText`, `xDistToTurn` | `maneuverType`, `maneuverModifier` | 필수 |
| chevron | `naviPaths` | `xDistToTurn` | 필수 |
| 속도카메라 표지 | `xSpdType`, `xSpdLimit`, `xSpdDist` | `szSdiDescr` | 권장 |
| 제한속도 배지 | `nRoadLimitSpeed` | - | 권장 |
| 신호등 표시 | `trafficState` | - | 선택 |
| 도착 존 | `nGoPosDist` | `distanceRemaining` | 선택 |
| 도로명 표지 | `szPosRoadName` | `szNearDirName`, `szFarDirName` | 비권장 |

## 8. 2026-03 기준 구현 방식

### 8.1 렌더링 구조

1차 권장안:
- Flutter는 shell/UI/설정만 담당
- Android native renderer가 실제 AR-like scene을 그림
- 원격 비디오와 AR 오브젝트를 같은 렌더 경로에서 처리

권장 기술 방향:
- `MediaCodec` decoder
- `SurfaceTexture` 기반 비디오 texture
- `OpenGL ES` 또는 유사 native 3D renderer
- 필요 시 `TextureView` 기반 최종 표시

근거:
- `SurfaceTexture`에서 생성한 `Surface`는 `MediaCodec` 출력 대상으로 사용할 수 있다
- `TextureView`는 일반 View처럼 합성 가능하지만 `SurfaceView`보다 느릴 수 있다
- Flutter platform views는 합성/성능 trade-off가 있어, 비디오와 AR를 따로 겹치기보다 native 한 경로에서 같이 그리는 편이 안정적이다

### 8.2 ARCore/Unity 판단

- ARCore:
  - stock 모드 1차 구현에는 비권장
  - 이유는 입력이 폰 카메라가 아니라 원격 비디오이기 때문
- Unity:
  - 가능하지만 1차 권장안은 아님
  - full-screen 전용 driving mode로 빼지 않는 이상 통합 비용이 큼

## 9. 구현 순서

### 1차 MVP

- 경로 리본
- 턴 게이트
- 턴 안내 보드
- chevron

목표:
- 운전자가 "다음 진행 방향"을 직관적으로 이해

### 2차

- 속도카메라 표지
- 제한속도 배지
- 도착 존

목표:
- 내비 정보 확장

### 3차

- 신호등 상태
- 고도 보정
- richer 3D mesh

목표:
- 시각 완성도 상승

## 10. 내 의견

### 10.1 반드시 AR로 보여야 하는 것

- 경로
- 다음 턴 위치
- 다음 턴 의미

이 세 개가 이 기능의 본질이다.

### 10.2 AR로 보이면 멋있지만 1차 핵심은 아닌 것

- 속도카메라
- 신호등
- 목적지 도착 효과

이건 나중에 붙여도 된다.

### 10.3 AR로 만들지 않는 게 더 나은 것

- 도로명
- ETA
- 연결/디버그 상태

이건 HUD로 남겨야 읽기 쉽다.

### 10.4 사용자 경험 기준으로 가장 중요한 원칙

- 멋있어 보이는 것보다 "한눈에 방향을 알게 하는 것"이 우선
- clutter를 만들면 실패
- 경로 리본과 턴 게이트만 정확해도 체감 품질은 높다

## 11. 참고 문서

- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_MVP_EXECUTION_PLAN_2026-03-06_KO.md`
- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_IMPLEMENTATION_CHECKLIST_2026-03-06_KO.md`
- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_MAPPING_OPTIMIZATION_2026-03-06_KO.md`
- `docs/architecture/carrotpilot/TMAP_7712_CARROTPILOT_ANALYSIS_2026-03-06_KO.md`
- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_FEASIBILITY_2026-03-06_KO.md`

공식 참고:
- Flutter Platform Views
  - https://docs.flutter.dev/platform-integration/android/platform-views
- Android `SurfaceTexture`
  - https://developer.android.com/reference/android/graphics/SurfaceTexture
- Android `TextureView`
  - https://developer.android.com/reference/android/view/TextureView
- Android `MediaCodec`
  - https://developer.android.com/reference/android/media/MediaCodec
- ARCore enable AR
  - https://developers.google.com/ar/develop/java/enable-arcore

