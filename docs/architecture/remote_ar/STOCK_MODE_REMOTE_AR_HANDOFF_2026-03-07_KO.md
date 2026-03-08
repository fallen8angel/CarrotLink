# CarrotLink Stock Mode Remote AR 작업 인계 문서 (2026-03-07)

최초 작성일: 2026-03-07
대상 경로: `E:\CarrotLink\CarrotLink`
목적: 다른 컴퓨터/새 세션에서도 바로 다음 작업을 이어가기 위한 handoff 문서

## 1. 작업 목표

현재 목표는 `stock 모드 원격 주행카메라` 위에 새로운 remote-camera AR overlay를 얹는 것이다.

중요:

- 기존 CarrotLink `nav ar` 기능과는 별개다
- carrotpilot 내부 AR 구현을 직접 재사용하는 작업이 아니다
- 핵심은 `road/wideRoad 원격 카메라 + carrotMan/navInstructionCarrot + 기존 projection 결과`를 활용하는 것이다

## 2. 절대 건드리면 안 되는 범위

다음 3가지는 현재 설계의 하드 제약이다.

- 기존 `경로패스/차선 맵핑 수학` 비수정
- 기존 `camera frame sync / frameId` 로직 비수정
- 기존 `road/wide camera projection` 비수정

허용되는 작업:

- 위 결과물을 읽어서 새 scene/policy/renderer 계층을 추가
- 기존 projection 결과를 AR-like primitive 배치에 활용
- debug, capture/replay, tuning, fail-safe 계층 강화

## 3. 현재 구현 상태

2026-03-07 기준으로 아래는 이미 구현되어 있다.

- semantic AR scene builder
- Flutter -> native AR scene bridge
- native AR overlay renderer
- render policy / smoother / stabilizer / retainer
- anchor smoothing
- layout profile(`road_attached`, `wide_monitor`)
- tuning advisor / render bands / stats tracker
- AR scene inspect dialog
- AR scene capture / replay
- AR replay/session 자동 저장
- session 폴더 단위 자동 기록
- session 최신 요약 + timeline 누적 기록
- 기존 overlay보다 AR layer를 더 보이게 하는 시각 강조
- guide trail 움직임 추가

현재 남은 핵심은 대부분 `실기기 튜닝`이다.

현재 판단:

- 구조 작업은 대부분 끝났다
- 지금 병목은 `실제 화면 체감`
- 따라서 다음 작업은 구조 추가보다 `실주행 로그 기반 시각/정책 튜닝`이 우선이다

## 4. 현재 한계

다음 조합만으로는 현재 live AR scene이 만들어지지 않는다.

- phone fake GPS
- phone TMap 화면만 실행
- `alive` 미실행
- comma sidecar live payload 미유입

이유:

- CarrotLink는 phone TMap UI를 읽지 않는다
- live scene은 `_DriveOverlaySnapshot` 기반으로 만들어진다
- calibration/route/turn/native view가 없으면 `local payload`와 `native payload`가 모두 `null`일 수 있다

즉 `phone TMap만 보이는 상태`는 현재 개발 모드 입력으로 쓰이지 않는다.

## 5. 현재 구조

### 5.1 Flutter 계층

핵심 파일:

- `lib/screens/drive/live_drive_canvas_screen.dart`
- `lib/screens/drive/live_drive_canvas_ar_scene_components.dart`
- `lib/screens/drive/live_drive_canvas_ar_replay_components.dart`
- `lib/screens/drive/live_drive_canvas_overlay_components.dart`
- `lib/screens/drive/live_drive_canvas_overlay_sync_components.dart`
- `lib/screens/drive/live_drive_canvas_overlay_models_components.dart`
- `lib/screens/drive/live_drive_canvas_debug_popup_components.dart`
- `lib/screens/drive/live_drive_canvas_debug_actions_components.dart`

역할:

- raw snapshot -> semantic AR scene 생성
- 기존 projection 결과에서 `screenAnchors` 추출
- native `arScene` payload push
- AR inspect / capture / replay / diagnosis UI 제공

### 5.2 Android native 계층

핵심 bridge / host:

- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveVideoPlugin.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveOverlayPayload.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveOverlayCanvasRenderer.kt`

AR scene 모델 / 렌더:

- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArScene.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArSceneOverlayRenderer.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArCueGlyphRenderer.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArGuidePrimitiveRenderer.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArGuideRibbonRenderer.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArGuideTrailRenderer.kt`

AR 계산 / policy / tuning:

- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArRenderStatePipeline.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArRenderPolicy.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArRenderSmoother.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArRenderStabilizer.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArSceneRetainer.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArAnchorSmoother.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArSceneSanitizer.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArRenderBands.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArRenderStatsTracker.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArTuningAdvisor.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArRenderTuning.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArGuideTuning.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArGuideVisualTuning.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArLayoutProfileTuning.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArShellLayout.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArGeometry.kt`
- `android/app/src/main/kotlin/com/example/carrot_pilot_manager/NativeDriveArAnchoredGuidePath.kt`

## 6. 디버그 진입점

실행 화면:

- stock HUD 주행 화면

디버그 팝업:

- `HUD 디버그` -> `점검`

현재 중요한 액션:

- `Native AR scene 전송`
- `AR scene 보기`
- `AR 캡처 저장`
- `AR 파일 저장`
- `마지막 캡처 재생`
- `AR 재생 종료`

`AR scene 보기`에서 확인할 핵심 필드:

- `nativeViewId`
- `localRoutePoints`
- `localTurnInfo`
- `localCalibrationOk`
- `replaySessionDir`
- `replayTimelinePath`
- `[diagnosis]`
- `[local payload]`
- `[native payload]`
- `[native render summary]`

자동 저장 파일 구조:

- 루트 최신 요약: `logs/ar_scene/session_latest.json`
- 세션 폴더: `logs/ar_scene/session_<timestamp>_<host>/`
- 세션 메타: `session_meta.json`
- 타임라인 로그: `timeline.ndjson`

주의:

- 자동 저장은 `AR scene/debug/session` 계열이다
- 원본 비디오나 모든 raw 차량 로그를 다 저장하는 구조는 아직 아니다

실사용 흐름:

- 사용자는 주행만 하고 온다
- 주행 후 `logs/ar_scene/session_<...>/` 폴더를 확인한다
- 다음 세션에서는 `session_meta.json`, `timeline.ndjson`, 스크린샷으로 사후 분석한다

## 7. 다음 작업 순서

### 7.1 실기기 데이터 확보 전까지 할 일

1. 문서와 코드 구조를 유지
2. debug/diagnosis/capture/replay/auto-save 경로가 깨지지 않게 유지
3. 주행 후 세션 로그를 읽을 준비가 된 상태 유지
4. 기존 projection/frame math 쪽 직접 수정은 하지 않음

### 7.2 실기기 데이터 확보 후 최우선 작업

1. `road` 카메라 기준 live scene 확보
2. 자동 저장된 세션 폴더 확보
3. `session_meta.json`, `timeline.ndjson`, `native render summary`, 스크린샷 함께 검토
4. 아래 값 조정

- `effectiveAnchorQuality` 관련 threshold
- `anchoredPlacementBlend`
- `shellAlphaMultiplier`
- `guideAlphaMultiplier`
- `trailAlphaMultiplier`
- retention hold/fade 규칙
- `road_attached` / `wide_monitor` profile preset

### 7.3 실기기 확보 후 두 번째 작업

- 초록 path fill 대비 새 AR layer 분리감 추가 검토
- trail/ribbon/chip/card의 실제 체감 정도 튜닝
- clutter가 큰 장면에서 degrade stage 튜닝
- wideRoad 전용 preset 미세 조정
- 장시간 주행 중 flicker / unstable frame / thermal 관찰
- capture/replay 장면을 기준으로 regression 확인

### 7.4 현재 세션 이후 바로 할 일

다음 사용자가 다른 작업을 지시하더라도, remote AR 작업 재개 시 첫 단계는 아래다.

1. 최신 `logs/ar_scene/session_<...>/` 폴더 확보
2. `session_meta.json` 읽기
3. `timeline.ndjson`에서 route/turn/budget/retention/anchor 상태 변화 보기
4. 스크린샷과 로그를 대조해 체감이 약했던 장면의 원인 분리

## 8. 다음 세션 체크리스트

새 세션 시작 시 먼저 확인할 것:

- 이 문서부터 읽기
- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_ON_DEVICE_TEST_2026-03-07_KO.md` 읽기
- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_FEASIBILITY_2026-03-06_KO.md` 최신 상태 확인
- `git status --short`로 작업 트리 확인
- 아래 검증 명령 실행

## 9. 검증 명령

다음 명령은 현재 기준 기본 검증 명령이다.

```powershell
dart analyze lib/screens/drive/live_drive_canvas_screen.dart
flutter build apk --debug
```

현재 확인 기준 산출물:

- `build/app/outputs/flutter-apk/app-debug.apk`

## 10. 내일 출근길 실기기 테스트 기준

내일 2026-03-08 테스트는 아래를 만족하면 성공이다.

- live scene 이 실제로 생성됨
- `nativeViewId`가 생성됨
- `local payload`가 `null`이 아님
- `native payload`가 `null`이 아님
- 최소 1개 이상 `AR 캡처 저장` 성공

세부 절차는 아래 문서를 따른다.

- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_ON_DEVICE_TEST_2026-03-07_KO.md`

## 11. 다음 세션에서 피해야 할 실수

- phone TMap 화면만 보고 live AR scene 이 생길 거라고 가정하지 말 것
- 기존 path/lane mapping math를 건드려서 AR를 맞추려 하지 말 것
- frame sync를 건드려서 AR flicker를 줄이려 하지 말 것
- road/wide projection 수학 수정으로 문제를 해결하려 하지 말 것

현재 전략은 항상 이렇다.

- 기존 계산 결과는 그대로 둔다
- 바깥에서 scene/policy/renderer/fail-safe를 다듬는다

## 12. 관련 문서 인덱스

- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_FEASIBILITY_2026-03-06_KO.md`
- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_ON_DEVICE_TEST_2026-03-07_KO.md`
- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_MVP_EXECUTION_PLAN_2026-03-06_KO.md`
- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_IMPLEMENTATION_CHECKLIST_2026-03-06_KO.md`
- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_MAPPING_OPTIMIZATION_2026-03-06_KO.md`
- `docs/architecture/remote_ar/STOCK_MODE_REMOTE_AR_DISPLAY_DESIGN_2026-03-06_KO.md`
- `docs/architecture/carrotpilot/TMAP_7712_CARROTPILOT_ANALYSIS_2026-03-06_KO.md`

