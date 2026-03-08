# HUD 진행 현황 / 인수인계 (2026-03-07 16:22 KST)

## 목적
- 다른 컴퓨터에서 HUD 재구축 작업을 바로 이어갈 수 있도록 현재 상태를 정리한다.
- 어떤 브랜치가 최신인지, 무엇을 끝냈는지, 무엇이 남았는지, 어디서부터 이어가야 하는지 기록한다.

## 기준 시각
- 2026-03-07 16:22:32 +09:00

## Git 상태
- 현재 작업 브랜치: `dev`
- 현재 작업 브랜치 HEAD: `a634694`
- 원격 `origin/dev`: `a634694`
- 즉, **현재 로컬 `dev`는 원격 `origin/dev`와 동기화된 상태**다.

주의:
- HUD/AR 작업은 이후 추가 로컬 변경이 있을 수 있으므로, 실제 작업 전 `git status`를 다시 확인하는 편이 안전하다.

## 관련 문서
- [CARROTPILOT_ORIGINAL_ONROAD_HUD_ANALYSIS_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/carrotpilot/CARROTPILOT_ORIGINAL_ONROAD_HUD_ANALYSIS_2026-03-07_KO.md)
- [ADAPTIVE_HUD_REBUILD_PLAN_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/ADAPTIVE_HUD_REBUILD_PLAN_2026-03-07_KO.md)
- [HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md)
- [HUD_DATA_PIPELINE_REFACTOR_PLAN_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_DATA_PIPELINE_REFACTOR_PLAN_2026-03-07_KO.md)
- [HUD_ADAPTIVE_LAYOUT_SPEC_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_ADAPTIVE_LAYOUT_SPEC_2026-03-07_KO.md)
- [HUD_CLUSTER_LAYOUT_VISUAL_GUIDE_2026-03-08_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_CLUSTER_LAYOUT_VISUAL_GUIDE_2026-03-08_KO.md)
- [HUD_IMPLEMENTATION_CHECKLIST_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_IMPLEMENTATION_CHECKLIST_2026-03-07_KO.md)

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

### 8. 2026-03-07 후속 polish 반영
- `driveOverlay`는 좁은 화면에서 3열 고정 배치 대신 compact 전용 2단 보조 레이아웃으로 내려가도록 조정했다.
- Flutter HUD는 live 상태에서 `quality / host / compat` 메타를 무조건 다 보여주지 않고, surface와 density에 따라 더 보수적으로 노출하도록 바꿨다.
- native overlay는 `tiny / compact / regular`에 따라 메타를 `Compact / Full` 모드로 압축하도록 정리했다.
- native overlay source badge도 `HUD / COMPAT / FALLBACK / PREVIEW` 별로 시각 구분되게 조정했다.
- `showMetricsRow`, `detailText`, `statusText`도 작은 창일수록 더 짧게 보이도록 정리했다.

### 9. HUD session 공유 구조 반영
- `AdaptiveHudHost`가 여러 개 떠도 host/sshService 기준으로 shared repository를 재사용하도록 바꿨다.
- 따라서 같은 host에서 HUD surface가 여러 개 열려도 websocket / fallback fetch 파이프라인이 중복 생성되지 않게 정리했다.
- shared repository가 살아 있는 동안 host session을 공유하고, 마지막 listener가 빠지면 session을 자동 정리하도록 연결했다.

### 10. surface 하위 섹션 분리 진행
- `adaptive_hud_panel.dart`에서 `driveInline / driveOverlay` 전용 레이아웃 조각을 별도 위젯 파일로 분리하기 시작했다.
- 이후 `homePreview` 하위 섹션도 `adaptive_hud_home_sections.dart`로 분리했다.
- 현재 추가된 파일은 `adaptive_hud_home_sections.dart`, `adaptive_hud_drive_inline_sections.dart`, `adaptive_hud_drive_overlay_sections.dart`이며, panel은 surface orchestration과 shared helper 위주로만 남겨두는 방향으로 정리됐다.
- 이번 단계로 `adaptive_hud_panel.dart` 크기는 약 33KB -> 17KB 수준까지 줄었고, surface별 polish를 별도 파일에서 진행할 수 있는 기반이 생겼다.

### 11. overlay compact / native tiny preset 보강
- Flutter `driveOverlay`는 좁은 화면에서 meta row를 단일 `Row` 대신 `Wrap`으로 내려가게 바꿨다.
- compact overlay support row에는 작은 `SIG` 상태 밴드를 다시 포함시켜, 좁은 화면에서도 상태 정보가 너무 빨리 사라지지 않게 조정했다.
- native overlay는 `OverlayHudMetaMode`를 `Tiny / Compact / Full` 3단으로 나누고, 아주 작은 창에서는 source / status / detail 압축 강도를 더 높였다.
- `Tiny`에서는 `statusText`를 필요할 때만 남기고, `detailText`는 degraded 정보 위주로만 축약되게 바꿨다.
- native `statusValue`도 빈 문자열이면 숨기도록 조정했다.

### 12. state shell / live 전환 polish
- Flutter HUD panel은 `state shell -> live HUD` 전환 시 `AnimatedSwitcher` 기반의 짧은 fade/scale 전환을 넣었다.
- native parser는 `statusText`를 source / compat / fallback / degraded 상태에 맞게 더 명시적으로 만들도록 정리했다.
- 따라서 live 연결, 호환 모드, fallback, degraded 상태가 작은 창에서도 이전보다 더 구분되게 됐다.

### 13. 2026-03-08 최신 디자인 방향 정리
- 최신 방향은 `adaptive panel`을 더 다듬는 것보다 `원본 좌하단 HUD 클러스터`를 기준으로 adaptive layout를 다시 잡는 쪽이다.
- 필드 의미는 그대로 두고, `driveMode`만 한글화하며 나머지 표기는 원본 HUD 느낌을 유지한다.
- `CPU / MEM / VOLT(DISK)`는 주 정보가 아니라 우상단의 작은 아이콘/숫자 정보로 내린다.
- 모든 density는 같은 클러스터를 압축한 형태여야 하며, `속도 / 설정속도 / 기어 / LIMIT`를 마지막까지 보존한다.
- 자세한 기준은 [HUD_CLUSTER_LAYOUT_VISUAL_GUIDE_2026-03-08_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_CLUSTER_LAYOUT_VISUAL_GUIDE_2026-03-08_KO.md)를 우선 참고한다.

### 14. 2026-03-08 클러스터 재배치 1차 반영
- Flutter adaptive HUD는 `좌하단 클러스터` 기준으로 다시 묶기 시작했다.
- `driveMode`는 UI에서 한글로 표기하도록 바꿨다.
- `CPU / MEM / VOLT(DISK)`는 텍스트 라벨형 tile 대신 아이콘 + 값 형태의 소형 metric으로 바꿨다.
- `driveOverlay / driveInline / homePreview`는 공통적으로:
  - 상단: 작은 metric row
  - 메인: `속도 / 설정속도+temp+gap / 기어`
  - 하단: `driveMode / LIMIT / APN`
  구조로 맞추는 방향으로 1차 수정이 들어갔다.
- semantic field 의미 자체는 바꾸지 않았고, UI 해석만 조정했다.

### 15. 2026-03-08 의미 노이즈 축소 / overflow 보정
- `LON / LAT`, 큰 `SIG` 박스 같은 설명 부담이 큰 보조 요소는 메인 HUD에서 제거하거나 작은 점 표시 수준으로 내렸다.
- `gearText == U`인 경우는 큰 기어 박스로 올리지 않고, 우측 보조 rail의 작은 `–` 표시로 약화했다.
- `NO GPS`, `hidden` 같은 fallback 문자열은 메인 클러스터에서 크게 보이지 않도록 줄였다.
- `속도 / 설정속도 / 기어 / 하단 strip`이 더 큰 비중을 갖도록 flex와 상단 정렬을 재조정했다.
- `driveOverlay`, `driveInline`, `homePreview` 모두 짧은 높이에서 더 빨리 compact 밀도로 내려가도록 보수적으로 조정했다.

### 16. 2026-03-08 최종 HUD 골격 재정렬
- surface마다 따로 노는 배치를 줄이기 위해 `상단 metric bar / 본문 좌측정보·우측정보 / 하단 상태바` 3단 골격으로 다시 통일했다.
- 상단은 `CPU / MEM / VOLT(DISK)`를 `3분할 고정 bar`로 배치하고, 더 이상 우측 상단의 떠 있는 chip처럼 취급하지 않는다.
- 좌측정보는 `현재속도` 메인과 `LIMIT`, `APN/APM/N/C`를 맡는다.
- 우측정보는 `설정속도` 메인과 `tempControl`, `gap`, `gear`를 맡는다.
- 하단 상태바는 `좌 red dot / 중앙 mode pill(일반·안전·고속·에코) / 우 signal` 구조로 고정한다.
- `gearText == U`인 경우는 별도 박스로 띄우지 않고 숨기거나 매우 약하게 처리한다.
- `homePreview`, `driveInline`, `driveOverlay` 모두 같은 구조 언어를 쓰도록 surface 레이아웃을 다시 맞췄다.

## 지금 남은 일

### 1. Flutter adaptive HUD 최종 polish
- `driveOverlay` compact polish는 한 차례 들어갔고, 2026-03-08 기준으로 좌하단 HUD 클러스터 재배치 1차 반영도 시작됐다.
- 아직 실제 실기 화면에서 spacing / font hierarchy / overflow가 완전히 맞는지는 더 확인해야 한다.
- `homePreview`와 `driveInline`도 같은 클러스터 언어를 공유하도록 바뀌었지만, 최종 fine tuning은 남아 있다.
- 상태별 모션/전환은 아직 최소 수준이다.

### 2. native overlay 최종 압축 규칙 튜닝
- tiny / compact / regular 압축 규칙은 한 차례 더 다듬었지만, 실기 화면에서 메타가 너무 약한지/강한지는 더 확인해야 한다.
- source badge / detail line / status line의 표시 강도는 실제 기기 화면 기준으로 한 번 더 다듬어야 한다.

### 3. surface 분리 및 파일 정리
- `homePreview / driveInline / driveOverlay` 하위 섹션 분리는 1차 완료로 봐도 된다.
- 남은 건 panel 안의 shared helper를 더 나눌지 여부인데, 지금 시점에서는 구조 작업보다 실기 튜닝 우선이 맞다.

### 4. 일부 레거시 경로 정리
- semantic source가 없는 구형 장치/브랜치 대응을 위해 compatibility mapper가 남아 있다.
- 당장 제거하면 안 되지만, 최종 단계에선 더 명확한 downgrade 정책이 필요하다.

### 5. 런타임 실기 검증
- 빌드/정적 분석은 통과했지만, 다양한 기기/화면크기/회전/멀티윈도우에서 시각 확인이 더 필요하다.
- 특히 fold, landscape compact, overlay drag 상태 확인이 남아 있다.

## 현재 진척도
- 문서화: 90% 이상
- semantic snapshot / data pipeline: 80% 이상
- Flutter adaptive HUD: 93~94%
- native overlay adaptive HUD: 87~88%
- 전체 HUD 재구축: **구조 기준 97% 이상, 최종 UX polish 포함 실질 완성도는 93~94% 전후**로 보는 게 더 정확하다.

## 최근 검증 상태
- `dart analyze` 통과
- `android app:compileDebugKotlin` 통과
- `flutter build apk --debug --target lib/main.dart` 통과

## 다른 컴퓨터에서 이어갈 때 권장 시작점

### 바로 읽을 문서 순서
1. [HUD_PROGRESS_HANDOFF_2026-03-07_1622_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_PROGRESS_HANDOFF_2026-03-07_1622_KO.md)
2. [HUD_CLUSTER_LAYOUT_VISUAL_GUIDE_2026-03-08_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_CLUSTER_LAYOUT_VISUAL_GUIDE_2026-03-08_KO.md)
3. [HUD_IMPLEMENTATION_CHECKLIST_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_IMPLEMENTATION_CHECKLIST_2026-03-07_KO.md)
4. [HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md)
5. [HUD_ADAPTIVE_LAYOUT_SPEC_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_ADAPTIVE_LAYOUT_SPEC_2026-03-07_KO.md)

### 바로 열 파일 순서
1. [adaptive_hud_host.dart](/e:/CarrotLink/CarrotLink/lib/features/hud/presentation/widgets/adaptive_hud_host.dart)
2. [adaptive_hud_panel.dart](/e:/CarrotLink/CarrotLink/lib/features/hud/presentation/widgets/adaptive_hud_panel.dart)
3. [adaptive_hud_drive_inline_sections.dart](/e:/CarrotLink/CarrotLink/lib/features/hud/presentation/widgets/adaptive_hud_drive_inline_sections.dart)
4. [adaptive_hud_drive_overlay_sections.dart](/e:/CarrotLink/CarrotLink/lib/features/hud/presentation/widgets/adaptive_hud_drive_overlay_sections.dart)
5. [hud_adaptive_display_model.dart](/e:/CarrotLink/CarrotLink/lib/features/hud/presentation/models/hud_adaptive_display_model.dart)
6. [OverlayHudService.kt](/e:/CarrotLink/CarrotLink/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudService.kt)

### 추천 다음 작업
- 실기 화면 검증 후 `상단 metric bar / 좌측정보 / 우측정보 / 하단 상태바` spacing 마감
- `LIMIT / APN / tempControl / gear / signal`의 실화면 가독성 튜닝
- native overlay HUD도 같은 3단 골격으로 최종 맞춤
- native overlay source/detail/status 최종 preset 다듬기
- 레거시 downgrade / compat cleanup 정책 마감
- fold / landscape compact / overlay drag 상태에서 마지막 spacing 정리

## 비고
- `dev`는 최신 원격과 동기화된 기준에서 작업 중이다.
- 이후 HUD 작업을 이어갈 때는 `Git 상태`보다 `지금 남은 일`과 `추천 다음 작업`을 기준으로 판단하는 편이 정확하다.


