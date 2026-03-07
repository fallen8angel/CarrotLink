# HUD 구현 체크리스트 및 마이그레이션 계획 (2026-03-07)

## 문서 목적
- 새 adaptive HUD를 실제 코드로 옮길 때의 구현 순서와 체크리스트를 정리한다.
- 레거시 HUD를 언제 동결하고, 언제 교체하고, 언제 제거할지 단계별로 정의한다.
- home / drive / overlay / preview를 어떤 순서로 새 구조로 이관할지 정리한다.

관련 문서:
- [ADAPTIVE_HUD_REBUILD_PLAN_2026-03-07_KO.md](/d:/CarrotLink/CarrotLink-dev/docs/architecture/ADAPTIVE_HUD_REBUILD_PLAN_2026-03-07_KO.md)
- [HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md](/d:/CarrotLink/CarrotLink-dev/docs/architecture/HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md)
- [HUD_DATA_PIPELINE_REFACTOR_PLAN_2026-03-07_KO.md](/d:/CarrotLink/CarrotLink-dev/docs/architecture/HUD_DATA_PIPELINE_REFACTOR_PLAN_2026-03-07_KO.md)
- [HUD_ADAPTIVE_LAYOUT_SPEC_2026-03-07_KO.md](/d:/CarrotLink/CarrotLink-dev/docs/architecture/HUD_ADAPTIVE_LAYOUT_SPEC_2026-03-07_KO.md)
- [HUD_PROGRESS_HANDOFF_2026-03-07_1622_KO.md](/d:/CarrotLink/CarrotLink-dev/docs/architecture/HUD_PROGRESS_HANDOFF_2026-03-07_1622_KO.md)

## 최신 진행 현황
- 기준 시각: 2026-03-07 16:22 KST
- 최신 handoff 문서: [HUD_PROGRESS_HANDOFF_2026-03-07_1622_KO.md](/d:/CarrotLink/CarrotLink-dev/docs/architecture/HUD_PROGRESS_HANDOFF_2026-03-07_1622_KO.md)
- 구조 기준 진척: 약 90%
- 실제 UX/UI polish 포함 진척: 약 80~85%

핵심 상태:
- `dev` 로컬 브랜치는 `origin/dev`와 동기화됨
- HUD 재구축 실제 변경분은 현재 `dev_ar` 워크트리의 로컬 변경 상태
- 다른 컴퓨터에서 그대로 이어서 작업하려면 다음 단계에서 커밋/푸시 필요

---

## 1. 최종 목표

최종 상태는 아래여야 한다.

### 1-1. 공통 semantic snapshot
- home / drive / overlay / preview가 모두 같은 `OriginalHudSnapshot`을 사용한다

### 1-2. 공통 data pipeline
- widget 내부 websocket 제거
- fallback merge 중앙화
- surface별 별도 raw parsing 제거

### 1-3. 공통 adaptive renderer
- layout rule은 같고, surface마다 density/slot만 다르다

### 1-4. 레거시 HUD 제거
- 기존 `HomeHudPreviewCard` 디자인 의존 경로 제거
- 기존 Android native HUD UI 조립 코드 제거 또는 host-only 축소

---

## 2. 레거시 동결 원칙

새 HUD 작업 시작 시점부터 아래는 **기능 추가 금지**다.

### 동결 대상
- [home_hud_preview_card.dart](/d:/CarrotLink/CarrotLink-dev/lib/widgets/home_hud_preview_card.dart)
- [live_drive_canvas_hud_components.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/drive/live_drive_canvas_hud_components.dart)
- [OverlayHudService.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudService.kt#L520)

허용되는 변경:
- 치명적인 버그 수정
- 빌드 깨짐 수정
- 새 구조로의 migration bridge 추가

허용되지 않는 변경:
- 디자인 수정
- 배치 수정
- 색상 수정
- 임시 필드 추가
- 새로운 의미 추론 로직 추가

이유:
- 레거시를 계속 고치면 migration이 끝나지 않는다

---

## 3. 새 코드 구조 목표

권장 디렉토리:

```text
lib/features/hud/
  domain/
  data/
  application/
  presentation/
```

세부 권장 구조:

```text
lib/features/hud/
  domain/
    entities/
      original_hud_snapshot.dart
      hud_drive_mode_state.dart
      hud_limit_state.dart
      hud_device_metrics_state.dart
    repositories/
      hud_repository.dart

  data/
    datasources/
      hud_remote_stream_data_source.dart
      hud_fallback_metrics_data_source.dart
      hud_preview_data_source.dart
    mappers/
      hud_remote_payload_mapper.dart
      hud_snapshot_assembler.dart
      hud_fallback_merge_policy.dart
    repositories/
      hud_repository_impl.dart

  application/
    hud_controller.dart
    hud_surface_session.dart

  presentation/
    model/
    layout/
    surfaces/
    widgets/
    theme/
```

---

## 4. 단계별 구현 체크리스트

## 단계 0. 준비
목표:
- 설계 문서 4종 고정
- 레거시 동결 선언

체크:
- [ ] 원본 HUD 분석 문서 확정
- [ ] semantic snapshot spec 확정
- [ ] data pipeline plan 확정
- [ ] adaptive layout spec 확정
- [ ] 레거시 HUD 파일 동결 범위 합의

완료 기준:
- 구현 순서 변경 없이 다음 단계로 갈 수 있어야 함

---

## 단계 1. Domain skeleton 도입
목표:
- semantic snapshot와 관련 상태 타입을 코드로 만든다

체크:
- [ ] `lib/features/hud/domain/entities/original_hud_snapshot.dart`
- [ ] `HudDriveModeState`
- [ ] `HudTempControlState`
- [ ] `HudLimitState`
- [ ] `HudConnectivityState`
- [ ] `HudSignalState`
- [ ] `HudGpsState`
- [ ] `HudDeviceMetricsState`
- [ ] `HudVisibilityState`
- [ ] `HudRepository` interface 정의

완료 기준:
- UI 없이도 snapshot 타입만 import 가능
- 기존 `_HudSnapshot`에 의존하지 않음

주의:
- 이 단계에서 UI 코드는 건드리지 않는다

---

## 단계 2. Data source skeleton 도입
목표:
- raw data source를 presentation 밖으로 뺀다

체크:
- [ ] `HudRemoteStreamDataSource` 생성
- [ ] `HudFallbackMetricsDataSource` 생성
- [ ] `HudPreviewDataSource` 생성
- [ ] websocket lifecycle이 widget 내부가 아닌 data layer에 위치
- [ ] SSH fallback 접근이 widget prop이 아닌 data source로 이동

완료 기준:
- Flutter widget 바깥에서 live raw stream을 구독할 수 있음

주의:
- 아직 semantic snapshot 완성 전이어도 됨
- 다만 presentation이 websocket을 직접 열면 실패

---

## 단계 3. Mapper / assembler 구현
목표:
- raw source를 `OriginalHudSnapshot`으로 바꾸는 로직 구현

체크:
- [ ] `HudRemotePayloadMapper` 구현
- [ ] `HudFallbackMergePolicy` 구현
- [ ] `HudSnapshotAssembler` 구현
- [ ] `tempControl` 최종 우선순위 로직 구현
- [ ] `driveMode` 원본 명칭 매핑 구현
- [ ] `APN/APM` badge mode 계산 구현
- [ ] `LIMIT/CAM` 최종 mode 계산 구현
- [ ] `GPS` placeholder 금지 처리
- [ ] `meta.isFallbackMetricsApplied` 처리

완료 기준:
- `OriginalHudSnapshot`만으로 UI가 표시 가능
- Flutter가 raw payload 의미를 다시 추론할 필요 없음

주의:
- 이 단계는 parity 핵심이라 테스트 우선

---

## 단계 4. Repository / controller 구현
목표:
- home / drive / overlay / preview가 같은 snapshot pipeline을 쓰게 만든다

체크:
- [ ] `HudRepositoryImpl` 구현
- [ ] `HudController` 구현
- [ ] `watchLive(host)` 구현
- [ ] `watchPreview()` 구현
- [ ] stale/degraded 처리 구현
- [ ] host 변경 대응 구현
- [ ] foreground/background 정책 정의

완료 기준:
- 특정 surface가 repository/controller만 보고 snapshot 구독 가능

주의:
- controller는 UI 로직이 아니라 session/state orchestration 역할만 해야 함

---

## 단계 5. Presentation primitive 구현
목표:
- 새 adaptive HUD의 최소 단위를 만든다

체크:
- [ ] `HudSurfaceKind`
- [ ] `HudDensityClass`
- [ ] `HudSlot`
- [ ] `HudLayoutSpec`
- [ ] `HudThemeTokens`
- [ ] `HudPrimarySpeedBlock`
- [ ] `HudSetSpeedBlock`
- [ ] `HudTempControlBlock`
- [ ] `HudGearBlock`
- [ ] `HudDriveModeBlock`
- [ ] `HudLimitBlock`
- [ ] `HudConnectivityBlock`
- [ ] `HudMetricStrip`

완료 기준:
- 각 slot을 독립적으로 렌더 가능
- 현재 디자인/색상과 무관한 새 표현 시작 가능

주의:
- 이 단계에서도 home/drive/overlay에 바로 붙이지 않는다

---

## 단계 6. Preview surface 우선 구현
목표:
- live에 붙기 전에 preview로 adaptive layout를 검증한다

체크:
- [ ] `PreviewHudSurface` 구현
- [ ] density별 mock snapshot 확인
- [ ] `micro/dense/compact/comfortable/spacious` 렌더 확인
- [ ] fold / hinge 레이아웃 확인

완료 기준:
- live 연결 없이 adaptive layout 품질 검증 가능

이유:
- preview가 먼저 살아야 live 디버깅 없이 UI 조정 가능

---

## 단계 7. Home HUD 이관
목표:
- 홈탭에서 새 adaptive HUD surface 사용

현재 대상:
- [home_tab.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/tabs/home_tab.dart#L587)

체크:
- [ ] home에서 새 `HudController` 사용
- [ ] 기존 `HomeHudPreviewCard` 대신 `HomeHudSurface` 연결
- [ ] fallback prop 주입 제거
- [ ] widget 내부 websocket 제거

완료 기준:
- 홈탭이 새 semantic snapshot pipeline을 사용
- 기존 `HomeHudPreviewCard`는 더 이상 홈탭 주력 경로가 아님

---

## 단계 8. Drive HUD 이관
목표:
- 주행화면 inline/panel/overlay HUD를 새 구조로 바꾼다

현재 대상:
- [live_drive_canvas_hud_components.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/drive/live_drive_canvas_hud_components.dart#L372)

체크:
- [ ] portrait HUD panel 교체
- [ ] landscape HUD overlay 교체
- [ ] sidecar badge / drive mode tag와 충돌 없이 공존
- [ ] overlay frame sync와 HUD semantic stream 분리 유지

완료 기준:
- drive 화면에서 새 adaptive HUD surface만 사용

주의:
- HUD는 camera/overlay sync와 별도 stream이어도 됨

---

## 단계 9. Android overlay path 이관
목표:
- Android 오버레이도 새 semantic pipeline에 맞춘다

현재 대상:
- [OverlayHudService.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudService.kt#L239)

1차 목표:
- [ ] native service에서 raw field parsing 최소화
- [ ] semantic snapshot만 소비하게 축소

2차 목표:
- [ ] native UI 조립 코드 제거 또는 host-only 축소

완료 기준:
- overlay도 semantic snapshot 기준으로 동작
- Flutter HUD와 의미 계약 차이가 없음

주의:
- 이 단계는 가장 리스크가 크므로 마지막에 가는 게 맞다

---

## 단계 10. 레거시 제거
목표:
- 새 구조 완성 후旧 HUD 제거

체크:
- [ ] 홈탭에서 기존 `HomeHudPreviewCard` 제거 또는 preview-only 격리
- [ ] drive HUD에서 기존 레거시 경로 제거
- [ ] Android native UI 직접 조립 경로 제거 또는 deprecated 표시
- [ ] `_HudSnapshot` 삭제
- [ ] widget 내부 websocket worker 삭제

완료 기준:
- HUD 관련 source of truth가 새 pipeline으로 완전히 일원화

---

## 5. 마이그레이션 순서가 중요한 이유

올바른 순서:
1. semantic type
2. data source
3. mapper
4. repository/controller
5. preview
6. home
7. drive
8. overlay
9. legacy removal

잘못된 순서:
- home UI부터 고치기
- overlay UI부터 새로 그리기
- preview를 마지막에 만들기

이유:
- data contract 없이 UI부터 만들면 다시 갈아엎게 된다

---

## 6. 파일별 처리 계획

## 6-1. 유지하며 참조할 파일
- [window_class.dart](/d:/CarrotLink/CarrotLink-dev/lib/ui/adaptive/window_class.dart)
- [layout_tokens.dart](/d:/CarrotLink/CarrotLink-dev/lib/ui/adaptive/layout_tokens.dart)

이유:
- adaptive 인프라 자체는 재사용 가능

## 6-2. 단계적 교체 대상
- [home_hud_preview_card.dart](/d:/CarrotLink/CarrotLink-dev/lib/widgets/home_hud_preview_card.dart)
- [home_tab.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/tabs/home_tab.dart)
- [live_drive_canvas_hud_components.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/drive/live_drive_canvas_hud_components.dart)
- [native_overlay_hud_service.dart](/d:/CarrotLink/CarrotLink-dev/lib/services/native_overlay_hud_service.dart)
- [OverlayHudService.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudService.kt)

## 6-3. 새로 추가될 가능성이 높은 파일
- `lib/features/hud/domain/entities/original_hud_snapshot.dart`
- `lib/features/hud/data/repositories/hud_repository_impl.dart`
- `lib/features/hud/application/hud_controller.dart`
- `lib/features/hud/presentation/layout/hud_layout_spec.dart`
- `lib/features/hud/presentation/surfaces/home_hud_surface.dart`
- `lib/features/hud/presentation/surfaces/drive_hud_surface.dart`
- `lib/features/hud/presentation/surfaces/overlay_hud_surface.dart`
- `lib/features/hud/presentation/surfaces/preview_hud_surface.dart`

---

## 7. 테스트 체크리스트

## 7-1. data layer
- [ ] live snapshot 정상 수신
- [ ] fallback metrics 병합 정상
- [ ] stale 판단 정상
- [ ] preview snapshot 정상

## 7-2. semantic parity
- [ ] speed parity
- [ ] set speed parity
- [ ] tempControl parity
- [ ] drive mode parity
- [ ] gear parity
- [ ] gap parity
- [ ] APN/APM parity
- [ ] LIMIT/CAM parity
- [ ] GPS parity
- [ ] CPU/MEM/DISK/VOLT parity

## 7-3. adaptive layout
- [ ] compact portrait
- [ ] compact landscape
- [ ] medium
- [ ] expanded
- [ ] large
- [ ] extraLarge
- [ ] fold vertical hinge
- [ ] fold horizontal hinge
- [ ] overlay host

## 7-4. UX
- [ ] 정보 우선순위 유지
- [ ] 레이아웃 붕괴 없음
- [ ] safe area 침범 없음
- [ ] 과한 점멸/흔들림 없음

---

## 8. 출시/적용 전략

권장 rollout:

### 1차
- preview + home만 새 구조

### 2차
- drive HUD 전환

### 3차
- overlay 전환

### 4차
- 레거시 제거

이유:
- overlay는 Android service까지 걸려 있어 리스크가 가장 크다

---

## 9. 구현 착수 전 체크

코드 작업 시작 전 반드시 확인:
- [ ] semantic snapshot spec에 동의했는가
- [ ] data pipeline plan에 동의했는가
- [ ] adaptive layout spec에 동의했는가
- [ ] 레거시 HUD 동결에 동의했는가

이 4개가 안 되면 코딩을 시작하면 안 된다.

---

## 10. 결론

이제 HUD 작업은 “어디 한 군데 고치는 작업”이 아니다.
아래를 순서대로 밟는 재구축 작업이다.

1. semantic 계약 고정
2. data pipeline 통합
3. adaptive layout 구현
4. home 전환
5. drive 전환
6. overlay 전환
7. 레거시 제거

즉 다음 실제 코드 작업은
**`lib/features/hud` skeleton 생성부터 시작하는 것이 맞다.**
