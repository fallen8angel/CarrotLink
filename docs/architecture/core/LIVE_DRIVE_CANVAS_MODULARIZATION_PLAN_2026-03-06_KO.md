# LiveDriveCanvas 구조화 계획 (2026-03-06)

대상 파일:
- `lib/screens/drive/live_drive_canvas_screen.dart`

## 목적

이 문서는 `live_drive_canvas_screen.dart`를 리팩토링이 아니라 **구조화/모듈화** 관점에서 안전하게 분리하기 위한 기준을 기록한다.

핵심 조건:
- 오픈파일럿 정합 수학은 수정하지 않는다.
- 경로/차선/리드/레이더 좌표 매핑 로직은 수정하지 않는다.
- 이번 작업은 **책임 분리와 파일 경량화**가 목적이다.

## 현재 진단

- 파일 길이: 약 `11k+` 라인
- 한 파일에 다음 책임이 과도하게 결합되어 있음
  - 화면 레이아웃/HUD UI
  - WebRTC/WebView/네이티브 카메라 브리지
  - sidecar 런타임/SSH/부트스트랩
  - overlay snapshot 상태기계
  - 디버그 팝업/프리뷰/진단
  - 오버레이 페인터
  - 투영 수학/행렬/벡터 타입

## 분리 원칙

1. 계산식 변경 금지
2. 1차는 `part` 기반 분리
3. 이름 변경 최소화
4. 동작 동일성 우선
5. UI와 수학 계층을 먼저 분리하고, 런타임 컨트롤러 분리는 이후 단계에서 진행

## 1차 분리 범위

안전 분리 대상으로 다음 하단 구성요소를 별도 파일로 이동한다.

- `_PreviewRoadBackdropPainter`
- `_DriveOverlaySnapshot`
- `_XyzSeries`
- `_LaneLineSeries`
- `_RoadEdgeSeries`
- `_NavPathPoint`
- `_DriveOverlayPainter`
- `_ProjectionTransform`
- `_DriveVideoPlacement`
- `_SourceCanvasPlacement`
- `_V3`
- `_M3`

이 구간은 파일 하단에 모여 있고, 상태 클래스와의 연결이 비교적 명확해서 **행동 변경 없이 물리적 파일만 분리**하기 적합하다.

## 1차 적용 결과

완료:
- `lib/screens/drive/live_drive_canvas_overlay_components.dart` 신설
- 메인 파일에 `part 'live_drive_canvas_overlay_components.dart';` 추가
- 아래 구성요소를 신규 part 파일로 이동
  - `_PreviewRoadBackdropPainter`
  - `_DriveOverlaySnapshot`
  - `_XyzSeries`
  - `_LaneLineSeries`
  - `_RoadEdgeSeries`
  - `_NavPathPoint`
  - `_DriveOverlayPainter`
  - `_ProjectionTransform`
  - `_DriveVideoPlacement`
  - `_SourceCanvasPlacement`
  - `_V3`
  - `_M3`

결과:
- `live_drive_canvas_screen.dart`: 약 `11.1k` 라인 -> `6667` 라인
- `live_drive_canvas_overlay_components.dart`: `3971` 라인
- `dart analyze` 기준 에러 0

비변경 보장:
- 경로/차선/리드/레이더 좌표 계산식 미변경
- 투영 수학/행렬/벡터 연산 미변경
- sidecar/webrtc/HUD 진입 로직 미변경

## 2차 적용 결과

완료:
- `lib/screens/drive/live_drive_canvas_debug_components.dart` 신설
- `lib/screens/drive/live_drive_canvas_hud_components.dart` 신설
- `lib/screens/drive/live_drive_canvas_runtime_components.dart` 신설
- 메인 파일에 아래 `part` 추가
  - `part 'live_drive_canvas_debug_components.dart';`
  - `part 'live_drive_canvas_hud_components.dart';`
  - `part 'live_drive_canvas_runtime_components.dart';`

적용 방식:
- 기존 공개 진입 메서드 이름은 메인 파일에 그대로 유지
- 실제 구현은 `...Impl()` 메서드로 분리
- 즉, 외부 호출 관계와 상태 흐름은 유지하고 물리적 위치만 이동

이번에 분리된 대표 구성:
- HUD 디버그 팝업 액션/스냅샷/텍스트 다이얼로그
- 주행 카메라 surface/HUD 패널/landscape overlay UI
- HUD 기본 모드 로드/적용
- 네이티브 카메라 이벤트 처리
- Web camera JS message 처리
- HUD 디버그 레이어 토글 로드/저장
- sidecar recovery schedule 관리

현재 파일 구성:
- `live_drive_canvas_screen.dart`: `2983` 라인
- `live_drive_canvas_runtime_components.dart`: `1801` 라인
- `live_drive_canvas_debug_components.dart`: `1596` 라인
- `live_drive_canvas_hud_components.dart`: `285` 라인
- `live_drive_canvas_overlay_components.dart`: `4098` 라인

검증:
- `dart analyze` 에러 0

비변경 보장:
- 투영/정합 수학 미변경
- painter 출력 계산식 미변경
- overlay snapshot 구조 미변경
- sidecar/webrtc 동작 순서 미변경

## 3차 적용 결과

완료:
- `overlay preview` 묶음을 `runtime_components`로 이동
- 화면 회전/주사율/awake 제어 묶음을 `runtime_components`로 이동
- sidecar revision/bootstrap 관련 묶음을 `runtime_components`로 이동

이번에 메인 파일에서 래퍼화된 대표 메서드:
- `_overlayPreviewScenarioLabel`
- `_setOverlayPreviewMode`
- `_startOverlayPreviewLoop`
- `_stopOverlayPreviewLoop`
- `_tickOverlayPreview`
- `_previewRoadPathVertices`
- `_previewLanePolygon`
- `_buildOverlayPreviewSnapshot`
- `_buildOverlayPreviewBackdrop`
- `_restorePortraitOrientation`
- `_setDisplayHighRefreshPreference`
- `_enableScreenAwake`
- `_disableScreenAwake`
- `_loadAndApplyLandscapeOrientation`
- `_lockLandscapeOrientations`
- `_exitScreen`
- `_isSidecarBootstrapDone`
- `_setSidecarBootstrapDone`
- `_shortSidecarRevision`
- `_notifySidecarRevisionUpdated`
- `_ensureSidecarRevisionUpToDate`
- `_isSidecarDeployMissingError`
- `_tryAutoBootstrapSidecar`

현재 파일 구성:
- `live_drive_canvas_screen.dart`: `2445` 라인
- `live_drive_canvas_runtime_components.dart`: `2406` 라인
- `live_drive_canvas_debug_components.dart`: `1596` 라인
- `live_drive_canvas_hud_components.dart`: `285` 라인
- `live_drive_canvas_overlay_components.dart`: `4098` 라인

검증:
- `dart analyze` 에러 0

비변경 보장:
- overlay preview 수학식/샘플 데이터 구성 미변경
- 화면 회전 정책/awake 정책 미변경
- sidecar bootstrap/revision 검증 순서 미변경

## 4차 적용 결과

완료:
- 카메라/런타임 공용 헬퍼 일부를 `runtime_components`로 추가 이동
- 메인 파일 하단의 top-level sidecar worker를 `runtime_components`로 이동

이번에 이동한 구성:
- `_driveSidecarWorkerMain`
- `_isAnimatedPathMode`
- `_cameraKindFromLabel`
- `_updateSourceSize`

주의:
- `_toast`, `_safeSetState`는 한 번 `runtime_components`로 이동했으나,
  `extension` 내부의 `setState` 직접 호출이 analyzer 경고를 만들기 때문에
  메인 파일에 유지했다.
- 즉, 구조화는 진행하되 analyzer 0을 우선 기준으로 삼았다.

현재 파일 구성:
- `live_drive_canvas_screen.dart`: `1434` 라인
- `live_drive_canvas_runtime_components.dart`: `3362` 라인
- `live_drive_canvas_debug_components.dart`: `1691` 라인
- `live_drive_canvas_hud_components.dart`: `285` 라인
- `live_drive_canvas_overlay_components.dart`: `4098` 라인

검증:
- `dart analyze` 에러 0

비변경 보장:
- 카메라 선택 규칙 미변경
- source size 갱신 규칙 미변경
- sidecar worker reconnect loop/디코드 흐름 미변경

## 5차 적용 결과

완료:
- `build()` 내부의 대형 레이아웃 조립부를 신규 part로 분리
- 메인 파일은 `build()` 진입점 + 화면 셸 역할만 유지
- 레이아웃 전용 part 추가:
  - `live_drive_canvas_layout_components.dart`

이번에 이동한 구성:
- `_driveFoldInsetsImpl`
- `_buildDriveScaffoldBodyImpl`
- `_buildDriveResponsiveLayoutImpl`
- `_buildDriveMainContentImpl`
- `_buildDriveDockImpl`
- `_buildDriveViewportContentImpl`

현재 파일 구성:
- `live_drive_canvas_screen.dart`: `769` 라인
- `live_drive_canvas_layout_components.dart`: `698` 라인
- `live_drive_canvas_runtime_components.dart`: `3562` 라인
- `live_drive_canvas_debug_components.dart`: `1720` 라인
- `live_drive_canvas_hud_components.dart`: `300` 라인
- `live_drive_canvas_overlay_components.dart`: `4314` 라인

검증:
- `dart analyze` 에러 0

비변경 보장:
- `build()` 내부 레이아웃 분기만 파일 이동
- 비디오 placement 계산식 미변경
- overlay painter 호출 조건 미변경
- sidecar/webrtc 상태 배너 노출 조건 미변경

## 6차 적용 결과

완료:
- `runtime_components`를 overlay 책임 기준으로 추가 분리
- 신규 part 추가:
  - `live_drive_canvas_overlay_sync_components.dart`
  - `live_drive_canvas_overlay_preview_components.dart`
- 기존 `live_drive_canvas_runtime_components.dart`는 제거

이번에 분리한 구성:
- overlay 동기화/네이티브 푸시/보간/프레임 락
  - `_stabilizeOverlaySnapshotImpl`
  - `_mergeSidecarOverlay2dTrackVerticesImpl`
  - `_applyHudModeRuntimeImpl`
  - `_loadHudDebugLayerTogglesImpl`
  - `_saveHudDebugLayerTogglesImpl`
  - `_cacheOverlaySnapshot`
  - `_findSyncedSnapshot`
  - `_applyOverlaySnapshot`
  - `_pushNativeOverlay`
  - `_publishOverlaySynced`
  - `_setRenderTarget`
  - `_onRenderTick`
  - `_handleCameraFrameEventImpl`
- preview 시뮬레이션
  - `_overlayPreviewScenarioLabelImpl`
  - `_setOverlayPreviewModeImpl`
  - `_startOverlayPreviewLoopImpl`
  - `_stopOverlayPreviewLoopImpl`
  - `_tickOverlayPreviewImpl`
  - `_previewRoadPathVerticesImpl`
  - `_previewLanePolygonImpl`
  - `_buildOverlayPreviewSnapshotImpl`
  - `_buildOverlayPreviewBackdropImpl`

현재 파일 구성:
- `live_drive_canvas_screen.dart`: `777` 라인
- `live_drive_canvas_overlay_sync_components.dart`: `758` 라인
- `live_drive_canvas_overlay_preview_components.dart`: `433` 라인
- `live_drive_canvas_layout_components.dart`: `698` 라인
- `live_drive_canvas_debug_components.dart`: `133` 라인
- `live_drive_canvas_debug_actions_components.dart`: `196` 라인
- `live_drive_canvas_hud_components.dart`: `300` 라인
- `live_drive_canvas_overlay_components.dart`: `3163` 라인
- `live_drive_canvas_overlay_models_components.dart`: `903` 라인
- `live_drive_canvas_overlay_math_components.dart`: `252` 라인

검증:
- `dart analyze` 에러 0

비변경 보장:
- overlay snapshot 정합/보간 계산식 미변경
- 프레임 동기화 정책 미변경
- preview 샘플 데이터/투영 기준 미변경

## 7차 적용 결과

완료:
- `camera_components`에서 HTML builder와 런타임 이벤트 처리를 분리
- 신규 part 추가:
  - `live_drive_canvas_camera_html_components.dart`

이번에 분리한 구성:
- HTML/WebView 생성 전용
  - `_buildLiveCameraHtmlImpl`
  - `_buildIdleCameraHtmlImpl`
- 카메라 런타임 전용(`live_drive_canvas_camera_components.dart`)
  - `_cameraKindFromLabel`
  - `_updateSourceSize`
  - `_unloadWebCameraSurfaceImpl`
  - `_handleNativeCameraEventImpl`
  - `_handleCameraJsMessageImpl`

현재 파일 구성:
- `live_drive_canvas_screen.dart`: `778` 라인
- `live_drive_canvas_overlay_sync_components.dart`: `758` 라인
- `live_drive_canvas_overlay_preview_components.dart`: `433` 라인
- `live_drive_canvas_camera_components.dart`: `315` 라인
- `live_drive_canvas_camera_html_components.dart`: `808` 라인
- `live_drive_canvas_sidecar_components.dart`: `1069` 라인
- `live_drive_canvas_lifecycle_components.dart`: `201` 라인
- `live_drive_canvas_layout_components.dart`: `698` 라인
- `live_drive_canvas_debug_components.dart`: `133` 라인
- `live_drive_canvas_debug_actions_components.dart`: `196` 라인
- `live_drive_canvas_debug_popup_components.dart`: `1395` 라인
- `live_drive_canvas_hud_components.dart`: `300` 라인
- `live_drive_canvas_overlay_components.dart`: `3163` 라인
- `live_drive_canvas_overlay_models_components.dart`: `903` 라인
- `live_drive_canvas_overlay_math_components.dart`: `252` 라인

검증:
- `dart analyze` 에러 0

비변경 보장:
- WebView 카메라 HTML 내용 자체는 파일만 이동
- native/web camera 이벤트 처리 순서 미변경
- 카메라 소스 크기 갱신 규칙 미변경

## 8차 적용 결과

완료:
- `sidecar_components`에서 bootstrap/revision 책임을 별도 part로 분리
- 신규 part 추가:
  - `live_drive_canvas_sidecar_bootstrap_components.dart`

이번에 분리한 구성:
- sidecar 런타임(`live_drive_canvas_sidecar_components.dart`)
  - worker isolate / ws loop
  - recovery schedule
  - runtime start/stop
  - payload/frame 처리
- sidecar bootstrap(`live_drive_canvas_sidecar_bootstrap_components.dart`)
  - `_isSidecarBootstrapDoneImpl`
  - `_setSidecarBootstrapDoneImpl`
  - `_shortSidecarRevisionImpl`
  - `_notifySidecarRevisionUpdatedImpl`
  - `_ensureSidecarRevisionUpToDateImpl`
  - `_isSidecarDeployMissingErrorImpl`
  - `_tryAutoBootstrapSidecarImpl`

현재 파일 구성:
- `live_drive_canvas_screen.dart`: `779` 라인
- `live_drive_canvas_overlay_sync_components.dart`: `758` 라인
- `live_drive_canvas_overlay_preview_components.dart`: `433` 라인
- `live_drive_canvas_camera_components.dart`: `315` 라인
- `live_drive_canvas_camera_html_components.dart`: `808` 라인
- `live_drive_canvas_sidecar_components.dart`: `920` 라인
- `live_drive_canvas_sidecar_bootstrap_components.dart`: `151` 라인
- `live_drive_canvas_lifecycle_components.dart`: `201` 라인
- `live_drive_canvas_layout_components.dart`: `698` 라인
- `live_drive_canvas_debug_components.dart`: `133` 라인
- `live_drive_canvas_debug_actions_components.dart`: `196` 라인
- `live_drive_canvas_debug_popup_components.dart`: `1395` 라인
- `live_drive_canvas_hud_components.dart`: `300` 라인
- `live_drive_canvas_overlay_components.dart`: `3163` 라인
- `live_drive_canvas_overlay_models_components.dart`: `903` 라인
- `live_drive_canvas_overlay_math_components.dart`: `252` 라인

검증:
- `dart analyze` 에러 0

비변경 보장:
- sidecar bootstrap 판단/자동 배포 순서 미변경
- worker reconnect loop 미변경
- payload 수신 후 overlay 반영 순서 미변경

## 9차 적용 결과

완료:
- `sidecar_components`에서 runtime/process 상태 책임을 별도 part로 분리
- 신규 part 추가:
  - `live_drive_canvas_sidecar_runtime_components.dart`
- `debug popup` 내부 공용 위젯 헬퍼를 별도 part로 분리
- 신규 part 추가:
  - `live_drive_canvas_debug_popup_widgets_components.dart`

이번에 분리한 구성:
- sidecar runtime/process
  - `_clearSidecarRecoveryScheduleImpl`
  - `_scheduleSidecarRuntimeRecoveryImpl`
  - `_adaptiveCameraQualityLabel`
  - `_resetAdaptiveCameraQualityState`
  - `_startAdaptiveCameraQualityLoop`
  - `_stopAdaptiveCameraQualityLoop`
  - `_setAdaptiveCameraQualityMode`
  - `_fmtClock`
  - `_parseStatusPairs`
  - `_refreshSidecarProcessStatus`
  - `_pushSidecarHistory`
  - `_isSidecarBusy`
  - `_showSidecarStatusBanner`
  - `_sidecarStatusTitle`
  - `_sidecarStatusColor`
  - `_setSidecarPhase`
  - `_waitForSidecarReady`
  - `_ensureSidecarRuntime`
  - `_stopSidecarProcessIfNeeded`
- debug popup widget helper
  - `_buildDebugLayerSwitch`
  - `_buildDebugGroupNavItem`
  - `_buildDebugGroupNavChip`
  - `_buildDebugSectionCard`
  - `_buildDebugStatusMetricCard`
  - `_buildDebugStatusGrid`

현재 파일 구성:
- `live_drive_canvas_screen.dart`: `783` 라인
- `live_drive_canvas_camera_components.dart`: `315` 라인
- `live_drive_canvas_camera_html_components.dart`: `808` 라인
- `live_drive_canvas_sidecar_components.dart`: `438` 라인
- `live_drive_canvas_sidecar_runtime_components.dart`: `449` 라인
- `live_drive_canvas_debug_popup_components.dart`: `1248` 라인
- `live_drive_canvas_debug_popup_widgets_components.dart`: `238` 라인
- `live_drive_canvas_overlay_sync_components.dart`: `787` 라인
- `live_drive_canvas_overlay_components.dart`: `3163` 라인

검증:
- `dart analyze lib/screens/drive` 에러 0

비변경 보장:
- adaptive camera quality 전환 정책 미변경
- sidecar phase/state machine 미변경
- debug popup 표시 조건/토글 저장 규칙 미변경

## 10차 적용 결과

완료:
- `sidecar_components`에서 HTTP transport와 camera diagnostics를 별도 part로 분리
- 신규 part 추가:
  - `live_drive_canvas_sidecar_transport_components.dart`
  - `live_drive_canvas_camera_diag_components.dart`

이번에 분리한 구성:
- sidecar transport
  - `_sidecarHttpUriImpl`
  - `_sidecarGetJson`
  - `_sidecarPostJson`
- camera diagnostics
  - `_cameraDiagTimestampForFileName`
  - `_resolveCameraDiagDir`
  - `_captureCameraErrorDiagnostics`

현재 파일 구성:
- `live_drive_canvas_screen.dart`: `783` 라인
- `live_drive_canvas_layout_components.dart`: `698` 라인
- `live_drive_canvas_camera_components.dart`: `315` 라인
- `live_drive_canvas_camera_html_components.dart`: `808` 라인
- `live_drive_canvas_camera_diag_components.dart`: `124` 라인
- `live_drive_canvas_sidecar_components.dart`: `256` 라인
- `live_drive_canvas_sidecar_bootstrap_components.dart`: `151` 라인
- `live_drive_canvas_sidecar_runtime_components.dart`: `449` 라인
- `live_drive_canvas_sidecar_transport_components.dart`: `66` 라인
- `live_drive_canvas_lifecycle_components.dart`: `201` 라인
- `live_drive_canvas_debug_components.dart`: `133` 라인
- `live_drive_canvas_debug_actions_components.dart`: `196` 라인
- `live_drive_canvas_debug_popup_components.dart`: `1248` 라인
- `live_drive_canvas_debug_popup_widgets_components.dart`: `238` 라인
- `live_drive_canvas_hud_components.dart`: `310` 라인
- `live_drive_canvas_overlay_components.dart`: `3163` 라인
- `live_drive_canvas_overlay_models_components.dart`: `903` 라인
- `live_drive_canvas_overlay_math_components.dart`: `252` 라인
- `live_drive_canvas_overlay_sync_components.dart`: `787` 라인
- `live_drive_canvas_overlay_preview_components.dart`: `433` 라인

검증:
- `dart analyze lib/screens/drive` 에러 0

비변경 보장:
- sidecar HTTP 요청 규칙/timeout 미변경
- camera diagnostic 수집 내용/저장 위치 정책 미변경
- overlay/정합 수학 전 구간 미변경

## 이후 단계

### 다음 우선순위
- `debug_popup_components`를 그룹별 렌더 조각으로 추가 구조화
- `overlay_components`는 계산식 고정 전제에서 painter/helper 시각 계층만 추가 분리 검토
- 나머지는 구조상 이미 충분히 분리되었으므로, 추가 분리는 가독성 이득 대비 리스크를 먼저 평가

## 검증 기준

- analyzer 에러 0
- 기존 enum/type/private symbol 접근 정상
- overlay painter 출력 변화 없음
- sidecar/webrtc/HUD 진입 로직 변화 없음

## 결론

이번 작업은 “큰 파일을 다시 쓰는 작업”이 아니다.
목표는 다음 두 가지다.

- 파일을 읽을 수 있는 구조로 나눈다.
- 정합 수학과 렌더 결과는 그대로 유지한다.
