# HUD 진행 현황 / 인수인계 (2026-03-07 16:22 KST)

## 목적
- 다른 컴퓨터에서 HUD 재구축 작업을 바로 이어갈 수 있도록 현재 상태를 정리한다.
- 어떤 브랜치가 최신인지, 무엇을 끝냈는지, 무엇이 남았는지, 어디서부터 이어가야 하는지 기록한다.

## 기준 시각
- 2026-03-07 16:22:32 +09:00

## Git 상태
- 현재 작업 브랜치: `dev_ar`
- 현재 작업 브랜치 HEAD: `9f0b725`
- 로컬 `dev` 브랜치: `6092009`
- 원격 `origin/dev`: `6092009`
- 즉, **로컬 `dev` 브랜치는 원격 `origin/dev`와 동기화된 상태**다.

주의:
- 현재 HUD 재구축 변경사항은 `dev_ar` 워크트리에 **커밋/푸시되지 않은 로컬 변경**으로 남아 있다.
- 다른 컴퓨터에서 이 변경사항 자체를 이어서 작업하려면, 다음 단계에서 커밋/푸시가 추가로 필요하다.

## 관련 문서
- [CARROTPILOT_ORIGINAL_ONROAD_HUD_ANALYSIS_2026-03-07_KO.md](/d:/CarrotLink/CarrotLink-dev/docs/architecture/CARROTPILOT_ORIGINAL_ONROAD_HUD_ANALYSIS_2026-03-07_KO.md)
- [ADAPTIVE_HUD_REBUILD_PLAN_2026-03-07_KO.md](/d:/CarrotLink/CarrotLink-dev/docs/architecture/ADAPTIVE_HUD_REBUILD_PLAN_2026-03-07_KO.md)
- [HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md](/d:/CarrotLink/CarrotLink-dev/docs/architecture/HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md)
- [HUD_DATA_PIPELINE_REFACTOR_PLAN_2026-03-07_KO.md](/d:/CarrotLink/CarrotLink-dev/docs/architecture/HUD_DATA_PIPELINE_REFACTOR_PLAN_2026-03-07_KO.md)
- [HUD_ADAPTIVE_LAYOUT_SPEC_2026-03-07_KO.md](/d:/CarrotLink/CarrotLink-dev/docs/architecture/HUD_ADAPTIVE_LAYOUT_SPEC_2026-03-07_KO.md)
- [HUD_IMPLEMENTATION_CHECKLIST_2026-03-07_KO.md](/d:/CarrotLink/CarrotLink-dev/docs/architecture/HUD_IMPLEMENTATION_CHECKLIST_2026-03-07_KO.md)

## 지금까지 한 일

### 1. 원본 HUD 분석 및 문서화
- carrotpilot / carrot.cc 기준으로 원본 HUD가 어떤 값을 어떤 우선순위로 그리는지 분석했다.
- 원본 HUD의 값 의미와 우리 앱 HUD가 어긋난 원인을 문서로 정리했다.

### 2. semantic snapshot 구조 도입
- 새 HUD의 공통 계약으로 `OriginalHudSnapshot`을 도입했다.
- 값 의미를 `vehicle / tempControl / driveMode / gap / limits / connectivity / signals / gps / device / visibility / meta`로 분리했다.

주요 파일:
- [original_hud_snapshot.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/domain/entities/original_hud_snapshot.dart)
- [hud_repository.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/domain/repositories/hud_repository.dart)

### 3. HUD data pipeline 재구축
- widget 내부 websocket 의존을 줄이고 HUD feature 계층으로 옮겼다.
- live / preview / fallback metric source를 feature 내부 datasource로 분리했다.
- 원격 payload mapper, fallback merge policy, snapshot assembler를 만들었다.

주요 파일:
- [hud_remote_stream_data_source.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/data/datasources/hud_remote_stream_data_source.dart)
- [hud_fallback_metrics_data_source.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/data/datasources/hud_fallback_metrics_data_source.dart)
- [hud_preview_data_source.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/data/datasources/hud_preview_data_source.dart)
- [hud_remote_payload_mapper.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/data/mappers/hud_remote_payload_mapper.dart)
- [hud_fallback_merge_policy.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/data/mappers/hud_fallback_merge_policy.dart)
- [hud_snapshot_assembler.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/data/mappers/hud_snapshot_assembler.dart)
- [hud_repository_impl.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/data/repositories/hud_repository_impl.dart)

### 4. sidecar HUD semantic source 추가
- sidecar가 `/ws/hud`에서 HUD semantic snapshot을 직접 내리도록 추가했다.
- 앱은 `7766/ws/hud`를 우선 보고, 실패 시 `7000/ws/carstate`로 fallback 하도록 했다.

주요 파일:
- [carrotlink_sidecar.py](/d:/CarrotLink/CarrotLink-dev/assets/sidecar/carrotlink_sidecar.py)
- [hud_remote_stream_data_source.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/data/datasources/hud_remote_stream_data_source.dart)

### 5. Flutter adaptive HUD 첫 구현
- 새 adaptive HUD feature를 `lib/features/hud` 아래로 도입했다.
- `homePreview`, `driveInline`, `driveOverlay` surface 개념을 넣었다.
- 홈/주행 Flutter HUD는 새 adaptive host/panel을 쓰도록 교체했다.
- 연결 전/로딩/오류 상태는 의미 없는 `--` 카드 대신 상태 쉘로 보이게 했다.

주요 파일:
- [hud.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/hud.dart)
- [hud_controller.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/application/hud_controller.dart)
- [hud_controller_builder.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/presentation/widgets/hud_controller_builder.dart)
- [adaptive_hud_host.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/presentation/widgets/adaptive_hud_host.dart)
- [adaptive_hud_panel.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/presentation/widgets/adaptive_hud_panel.dart)
- [adaptive_hud_primitives.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/presentation/widgets/adaptive_hud_primitives.dart)
- [hud_layout_profile.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/presentation/models/hud_layout_profile.dart)
- [hud_adaptive_display_model.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/presentation/models/hud_adaptive_display_model.dart)

적용 위치:
- [home_tab.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/tabs/home_tab.dart)
- [live_drive_canvas_hud_components.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/drive/live_drive_canvas_hud_components.dart)

### 6. native overlay HUD 구조 분리
- Android overlay HUD도 parser / model / layout / view factory / ui applier / socket client로 분리했다.
- 서비스는 orchestration 중심으로 축소했다.
- overlay도 semantic snapshot을 우선 소스로 쓰고, semantic이 stale일 때만 websocket fallback으로 내려간다.

주요 파일:
- [OverlayHudService.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudService.kt)
- [OverlayHudModels.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudModels.kt)
- [OverlayHudPayloadParser.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudPayloadParser.kt)
- [OverlayHudLayoutProfiles.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudLayoutProfiles.kt)
- [OverlayHudViewFactory.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudViewFactory.kt)
- [OverlayHudUiApplier.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudUiApplier.kt)
- [OverlayHudSocketClient.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudSocketClient.kt)
- [OverlayHudPositionController.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudPositionController.kt)
- [OverlayHudTouchInteractions.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudTouchInteractions.kt)
- [OverlayHudCloseTargetController.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudCloseTargetController.kt)

### 7. overlay와 Flutter HUD semantic 경로 일치
- 홈 HUD뿐 아니라 주행 HUD도 native overlay로 semantic snapshot을 직접 밀도록 연결했다.
- 따라서 홈/주행 어느 화면에서든 overlay가 같은 semantic HUD 값을 받을 수 있다.

주요 파일:
- [native_overlay_hud_service.dart](/d:/CarrotLink/CarrotLink-dev/lib/services/native_overlay_hud_service.dart)
- [MainActivity.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/MainActivity.kt)
- [home_tab.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/tabs/home_tab.dart)
- [live_drive_canvas_hud_components.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/drive/live_drive_canvas_hud_components.dart)

## 지금 남은 일

### 1. Flutter adaptive HUD UX/UI 마무리
- 지금은 새 구조와 surface 분리는 들어갔지만, 최종 UX/UI polish는 아직 덜 됐다.
- 특히 `driveOverlay`와 `homePreview`의 시각 언어를 더 명확히 갈라야 한다.
- 상태별 모션/전환도 아직 최소 수준이다.

### 2. native overlay 시각 계층 polish
- tiny / compact / regular에서 더 공격적인 표시 단순화가 필요하다.
- 현재는 adaptive는 되지만, 최종 제품 수준의 시각 정리는 아직 남아 있다.

### 3. compat/legacy fallback 노출 정책 정리
- `COMPAT`, `metric fallback`, `missing` 등의 표시 기준은 들어가 있지만, 언제 사용자에게 보여주고 언제 숨길지 정책 정리가 더 필요하다.
- 특히 preview / home / drive / overlay surface마다 메타 정보 표시 강도가 달라져야 한다.

### 4. 일부 레거시 경로 정리
- semantic source가 없는 구형 장치/브랜치 대응을 위해 compatibility mapper가 남아 있다.
- 당장 제거하면 안 되지만, 최종 단계에선 더 명확한 downgrade 정책이 필요하다.

### 5. 런타임 실기 검증
- 빌드/정적 분석은 통과했지만, 다양한 기기/화면크기/회전/멀티윈도우에서 시각 확인이 더 필요하다.
- 특히 fold, landscape compact, overlay drag 상태 확인이 남아 있다.

## 현재 진척도
- 문서화: 90% 이상
- semantic snapshot / data pipeline: 80% 이상
- Flutter adaptive HUD: 75% 전후
- native overlay adaptive HUD: 70% 전후
- 전체 HUD 재구축: 약 90%가 아니라, **구조 기준 약 90%, 최종 UX polish 포함 실질 완성도는 80~85% 정도**로 보는 게 더 정확하다.

## 최근 검증 상태
- `dart analyze` 통과
- `android app:compileDebugKotlin` 통과
- `flutter build apk --debug --target lib/main.dart` 통과

## 다른 컴퓨터에서 이어갈 때 권장 시작점

### 바로 읽을 문서 순서
1. [HUD_PROGRESS_HANDOFF_2026-03-07_1622_KO.md](/d:/CarrotLink/CarrotLink-dev/docs/architecture/HUD_PROGRESS_HANDOFF_2026-03-07_1622_KO.md)
2. [HUD_IMPLEMENTATION_CHECKLIST_2026-03-07_KO.md](/d:/CarrotLink/CarrotLink-dev/docs/architecture/HUD_IMPLEMENTATION_CHECKLIST_2026-03-07_KO.md)
3. [HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md](/d:/CarrotLink/CarrotLink-dev/docs/architecture/HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md)
4. [HUD_ADAPTIVE_LAYOUT_SPEC_2026-03-07_KO.md](/d:/CarrotLink/CarrotLink-dev/docs/architecture/HUD_ADAPTIVE_LAYOUT_SPEC_2026-03-07_KO.md)

### 바로 열 파일 순서
1. [adaptive_hud_host.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/presentation/widgets/adaptive_hud_host.dart)
2. [adaptive_hud_panel.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/presentation/widgets/adaptive_hud_panel.dart)
3. [hud_adaptive_display_model.dart](/d:/CarrotLink/CarrotLink-dev/lib/features/hud/presentation/models/hud_adaptive_display_model.dart)
4. [OverlayHudService.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudService.kt)
5. [OverlayHudViewFactory.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudViewFactory.kt)
6. [OverlayHudPayloadParser.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudPayloadParser.kt)

### 추천 다음 작업
- `driveOverlay` 최종 레이아웃 다듬기
- native overlay tiny/compact 정보 압축 규칙 정리
- compat/fallback 메타 노출 정책 정리
- 실기 화면 검증 후 spacing / visibility 튜닝

## 비고
- `dev`는 최신 원격과 동기화했지만, **현재 HUD 작업 자체는 아직 로컬 변경 상태**다.
- 다른 컴퓨터에서 이 변경사항을 그대로 이어가려면, 다음 단계에서 현재 변경분을 커밋하고 푸시해야 한다.
