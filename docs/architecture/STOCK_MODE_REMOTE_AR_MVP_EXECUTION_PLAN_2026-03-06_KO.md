# CarrotLink Stock Mode Remote AR MVP 실행 계획 (2026-03-06)

최종 분석일: 2026-03-06

대상:
- 앱: `E:\CarrotLink\CarrotLink`
- 장치 런타임: `E:\CarrotLink\C3-v10-wip`

이 문서는 stock 모드 remote AR 구현을 실제 개발 순서로 정리한다.

핵심 목표:
- 1차 MVP 범위를 고정
- 수정 파일 순서를 고정
- scene/payload 계약을 먼저 고정

하드 제약:
- 기존 `경로패스/차선 맵핑 수학`은 수정하지 않는다
- 기존 `camera frame sync / frameId 처리` 로직은 수정하지 않는다
- 1차 구현은 반드시 현재 projection/frame 파이프라인 바깥에 additive layer로 얹는다

## 1. MVP 범위

### 1.1 반드시 들어갈 것

- 경로 리본
- 턴 게이트
- 턴 보드
- chevron
- stale / frame-gap 폴백

### 1.2 1차에서 제외

- 진짜 world-anchor AR
- Unity 전환
- 신호등 절대 위치 고정
- 속도카메라 3D 표지
- 복층도로/육교 절대 고도 정합

### 1.3 성공 기준

- 직진/분기/교차로에서 경로 리본이 road camera와 크게 어긋나지 않음
- 다음 턴 위치가 사용자 시점에서 납득 가능한 위치에 뜸
- mismatch 시 과감히 숨김
- clutter가 적고 읽기 쉬움

## 2. 우선순위

### P0

- `carrotMan.naviPaths`
- `xTurnInfo`
- `xDistToTurn`
- `szTBTMainText`
- `navInstructionCarrot` fallback
- `roadCameraState.frameId`
- `modelV2.frameId`
- `liveCalibration`

이 조합만으로 MVP를 만든다.

### P1

- `xSpdType`
- `xSpdLimit`
- `xSpdDist`
- `nRoadLimitSpeed`
- `nGoPosDist`
- `nGoPosTime`

### P2

- `trafficState`
- `roadEdges`
- richer z adaptation
- wideRoad 전용 튜닝

## 3. 구현 순서

## 3.1 Phase A: 계약 고정

수정 파일:
- `assets/sidecar/carrotlink_sidecar.py`
- `lib/screens/drive/live_drive_canvas_overlay_models_components.dart`

작업:
- sidecar live payload에서 실제로 필요한 필드만 다시 점검
- `carrotMan` / `navInstructionCarrot` / camera frame 관련 필드를 계약 문서와 일치시킴
- `naviPaths` parse / stale 규칙을 고정

완료 기준:
- scene builder가 받을 입력이 문서와 1:1 대응

## 3.2 Phase B: Scene builder 정리

수정 파일:
- `lib/screens/drive/live_drive_canvas_overlay_models_components.dart`
- 필요 시 신규 파일:
  - `lib/screens/drive/live_drive_canvas_ar_scene_components.dart`

작업:
- raw payload -> semantic scene 변환 분리
- `RouteRibbonScene`
- `TurnCueScene`
- `SceneHealth`

완료 기준:
- renderer는 raw payload를 몰라도 scene만으로 동작 가능

## 3.3 Phase C: Projection 규칙 정리

수정 파일:
- `lib/screens/drive/live_drive_canvas_overlay_components.dart`
- `lib/screens/drive/live_drive_canvas_overlay_math_components.dart`

작업:
- car-space -> source pixel -> canvas 규칙을 하나의 경로로 통일
- `naviPaths x/y` + sampled z 조합
- turn gate anchor 규칙 추가
- frame gap/stale gating 추가

완료 기준:
- 경로/턴 cue가 같은 projection stack을 공유

## 3.4 Phase D: Native bridge 정리

수정 파일:
- `lib/screens/drive/live_drive_canvas_overlay_sync_components.dart`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveVideoPlugin.kt`

작업:
- Flutter -> native로 polygon이 아니라 semantic scene 또는 최소한 car-space primitive를 보낼지 확정
- MVP에서는 기존 native overlay를 재사용할지, 새 renderer로 갈지 결정
- frameId 기준 sync 유지

완료 기준:
- overlay update가 현재보다 더 큰 scene에서도 안정적

## 3.5 Phase E: 화면/설정 연결

수정 파일:
- `lib/screens/drive/live_drive_canvas_screen.dart`
- `lib/screens/drive/live_drive_canvas_hud_components.dart`

작업:
- feature flag / mode toggle
- debug flag
- road / wideRoad 정책 UI 반영

완료 기준:
- 사용자 입장에서 stock 모드에서 켜고 끌 수 있음

## 4. 파일별 역할

### `assets/sidecar/carrotlink_sidecar.py`

역할:
- live payload source
- frameId / calibration / carrotMan 데이터 공급

1차 수정 방향:
- 필드 누락 여부 확인
- payload version 추가 여부 검토

### `lib/screens/drive/live_drive_canvas_overlay_models_components.dart`

역할:
- raw payload 파싱
- snapshot 구성

1차 수정 방향:
- snapshot을 raw payload cache로만 쓰고
- semantic AR scene builder를 분리

### `lib/screens/drive/live_drive_canvas_overlay_components.dart`

역할:
- projection
- overlay primitive 생성

1차 수정 방향:
- 경로 리본 / 턴 게이트 / 턴 보드의 car-space anchor 규칙 정리

### `lib/screens/drive/live_drive_canvas_overlay_sync_components.dart`

역할:
- frame sync
- native overlay push

1차 수정 방향:
- scene update frequency 조정
- stale/fallback 정책 집중

### `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveVideoPlugin.kt`

역할:
- 실제 stock mode 비디오 위 오버레이 렌더링

1차 수정 방향:
- polygon/label 기반으로 MVP를 얹을지
- semantic scene 수용 구조로 확장할지 결정

## 5. Scene 스키마 초안

권장 구조:

```json
{
  "sceneVersion": 1,
  "cameraKind": "road",
  "modelFrameId": 123,
  "cameraFrameId": 120,
  "health": {
    "frameGap": 3,
    "frameGapOk": true,
    "navStale": false,
    "calibrationOk": true
  },
  "routeRibbon": {
    "points": [[5.0, 0.2, 1.3], [10.0, 0.4, 1.4]],
    "style": "primary"
  },
  "turnCue": {
    "type": "right",
    "distanceM": 230,
    "text": "우회전",
    "anchor": [24.0, 1.8, 1.5]
  },
  "turnBoard": {
    "text": "230m 우회전",
    "anchor": [24.0, 1.8, 2.0]
  },
  "chevrons": [
    {"anchor": [12.0, 0.5, 1.3]},
    {"anchor": [18.0, 0.9, 1.4]}
  ]
}
```

원칙:
- scene payload는 screen pixel이 아니라 `car-space` 기준으로 보낸다
- projection은 native 또는 공용 projection 계층에서 처리한다

## 6. Flutter -> native bridge 스키마 초안

### 6.1 MVP에서 가장 안전한 방식

- Flutter가 최종 polygon을 만드는 현재 방식 유지
- scene이 안정화되면 native projection으로 이관

장점:
- 구현 진입이 빠름

단점:
- 장기적으로 payload가 무거워짐

### 6.2 권장 장기 방식

```json
{
  "version": 1,
  "viewId": 3,
  "cameraKind": "road",
  "frameId": 120,
  "scene": {
    "...": "semantic car-space scene"
  }
}
```

장점:
- payload 경량화
- native renderer 확장 쉬움
- 3D-like 연출로 가기 쉬움

## 7. 변수 초안

- `arEnabled`
- `arSceneVersion`
- `arMode`
- `arNavPathMaxPoints`
- `arNavPathMaxDistanceM`
- `arDistanceScale`
- `arPathVerticalOffsetPx`
- `arGateVerticalOffsetPx`
- `arFrameGapTolerance`
- `arNavStaleTimeoutMs`
- `arRoadOnly`
- `arWideRoadEnabled`

## 8. 환경 / 고도 적응 초안

### 가능한 것

- `pathOffsetZ`로 기본 높이 보정
- `laneLines.z/path.z`로 오르막/내리막 반영
- lane 폭에 맞춘 gate width
- 곡률에 따라 chevron spacing 조정
- road / wideRoad별 다른 board 위치

### 구현 방식

경로 리본:
- `naviPaths(x,y)` + `lane/path z`

턴 게이트:
- `xDistToTurn` 근처 `naviPaths` 포인트를 anchor로 사용
- lane width 기준으로 gate 폭 조정

턴 보드:
- gate anchor를 기준으로 추가 z 또는 y offset

즉 "환경에 따라 좋은 위치"는 가능하다.

단, 현재 단계에서는:
- 차선/경로/곡률/높이 기반 적응

까지만 현실적이다.

### 아직 어려운 것

- 실제 표지판 위치에 완전 고정
- 실제 신호등 위치에 완전 고정
- 복층 구조까지 완전 정합

## 9. 검증 순서

1. 직진 고속도로
2. 완만한 곡선
3. 급커브
4. 좌/우 분기
5. 교차로 턴
6. 오르막 / 내리막
7. wideRoad 전환
8. 야간
9. 저사양/발열 상황

## 10. 내 의견

- 첫 구현은 절대 "3D 엔진 완성"을 목표로 두면 안 된다
- 먼저 `경로와 턴이 믿을 수 있게 맞는 것`이 핵심이다
- 고도/환경 적응은 이미 충분히 시작 가능하고, 이건 lane/path z만 잘 써도 체감이 크다
- 진짜 어려운 건 world-level 절대 정합이지, 지금 단계의 adaptive pseudo-AR은 충분히 현실적이다

## 11. 참고 문서

- `docs/architecture/STOCK_MODE_REMOTE_AR_DISPLAY_DESIGN_2026-03-06_KO.md`
- `docs/architecture/STOCK_MODE_REMOTE_AR_MAPPING_OPTIMIZATION_2026-03-06_KO.md`
- `docs/architecture/STOCK_MODE_REMOTE_AR_IMPLEMENTATION_CHECKLIST_2026-03-06_KO.md`
- `docs/architecture/STOCK_MODE_REMOTE_AR_FEASIBILITY_2026-03-06_KO.md`
