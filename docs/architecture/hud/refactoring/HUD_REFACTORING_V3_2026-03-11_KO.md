# HUD Refactoring V3 (2026-03-11)

## 목적
- 현재 CarrotLink HUD 구조의 `v3` 기준을 한 문서로 고정한다.
- 이후 HUD 관련 작업자는 기존 산발 문서 대신 이 문서를 먼저 보고, 필요한 세부 문서를 따라가게 한다.
- `docs/architecture/hud/refactoring/`를 HUD 재구성 문서의 새 기준 폴더로 사용한다.

## 문서 이름 규칙
- 현재 기준 문서 이름은 `HUD_REFACTORING_V3_2026-03-11_KO.md`다.
- 이후 HUD 대형 구조 변경 문서는 같은 폴더 아래에 English prefix 기준으로 쌓는다.
- 예시:
  - `HUD_REFACTORING_V4_YYYY-MM-DD_KO.md`
  - `HUD_REFACTORING_V3_HANDOFF_YYYY-MM-DD_KO.md`
  - `HUD_REFACTORING_V3_CHECKLIST_YYYY-MM-DD_KO.md`

## V3가 뜻하는 것
`HUD Refactoring V3`는 아래 4가지를 묶은 현재 구조를 뜻한다.

1. semantic snapshot 기반 HUD 계약
2. `lib/features/hud` 중심 feature 구조
3. dedicated HUD sidecar relay 우선 사용
4. home / drive inline / drive overlay를 같은 HUD domain으로 통합

즉, `widget 안에서 직접 websocket을 열고 화면별로 따로 HUD를 조립하던 방식`은 더 이상 기준이 아니다.

## 현재 Source Of Truth

### 1. 의미 계약
- `lib/features/hud/domain/entities/original_hud_snapshot.dart`
- `lib/features/hud/domain/entities/*.dart`

### 2. remote ingest / merge / assemble
- `lib/features/hud/data/datasources/hud_remote_stream_data_source.dart`
- `lib/features/hud/data/mappers/hud_remote_payload_mapper.dart`
- `lib/features/hud/data/mappers/hud_fallback_merge_policy.dart`
- `lib/features/hud/data/mappers/hud_snapshot_assembler.dart`
- `lib/features/hud/data/repositories/hud_repository_impl.dart`

### 3. application / presentation
- `lib/features/hud/application/hud_controller.dart`
- `lib/features/hud/presentation/widgets/hud_controller_builder.dart`
- `lib/features/hud/presentation/widgets/adaptive_hud_host.dart`
- `lib/features/hud/presentation/widgets/adaptive_hud_panel.dart`
- `lib/features/hud/presentation/models/hud_adaptive_display_model.dart`

### 4. HUD sidecar relay
- `assets/sidecar/hud.py`
- `assets/sidecar/hud.sh`
- `lib/services/link_hud_service.dart`

## 현재 데이터 흐름

### Primary
1. comma side-load HUD relay: `assets/sidecar/hud.py`
2. app stream ingest: `hud_remote_stream_data_source.dart`
3. payload normalize: `hud_remote_payload_mapper.dart`
4. fallback merge: `hud_fallback_merge_policy.dart`
5. snapshot assemble: `hud_snapshot_assembler.dart`
6. repository/controller: `hud_repository_impl.dart` -> `hud_controller.dart`
7. surface render: `adaptive_hud_host.dart` -> `adaptive_hud_panel.dart`

### Secondary / compatibility
- `assets/sidecar/sidecar.py`의 compatibility HUD path
- fallback metrics adapter / preview source

## V3에서 공식 지원하는 surface
- Home HUD
- Drive inline HUD
- Drive overlay HUD
- Preview/mock HUD

공통 전제:
- 같은 `OriginalHudSnapshot`을 본다.
- 화면마다 의미 계약을 다시 정의하지 않는다.
- 화면 차이는 layout density와 section composition 차이로만 처리한다.

추가 메모:
- 현재 `V3`는 HUD semantic/domain 기준 문서다.
- HOME HUD / drive HUD가 앱 foreground 동안 하나의 shared session을 쓰게 만드는 lifecycle 리팩토링은 별도 계획으로 관리한다.
- 관련 계획 문서:
  - [`../../link/CARROTLINK_SHARED_RUNTIME_REFACTOR_PLAN_2026-03-11_KO.md`](D:/CarrotLink/CarrotLink-dev/docs/architecture/link/CARROTLINK_SHARED_RUNTIME_REFACTOR_PLAN_2026-03-11_KO.md)

## V3에서 더 이상 기준이 아닌 것
- `home_hud_preview_card.dart` 중심의 구형 화면별 HUD 조립
- Android 일반 background HUD overlay UI
- `legacy /ws/carstate`를 기본 HUD source로 보는 방식
- 화면별로 속도/기어/갭 의미를 따로 해석하는 방식

## 기존 문서와의 관계

### 먼저 볼 문서
- 이 문서

### 배경 / 세부 참조
- `../HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md`
- `../HUD_DATA_PIPELINE_REFACTOR_PLAN_2026-03-07_KO.md`
- `../HUD_ADAPTIVE_LAYOUT_SPEC_2026-03-07_KO.md`
- `../HUD_CLUSTER_LAYOUT_VISUAL_GUIDE_2026-03-08_KO.md`
- `../HUD_IMPLEMENTATION_CHECKLIST_2026-03-07_KO.md`
- `../HUD_PROGRESS_HANDOFF_2026-03-07_1622_KO.md`

### 원본 stock parity 기준
- `../../carrotpilot/C3_STOCK_ONROAD_GRAPHICS_HUD_REFERENCE_2026-03-10_KO.md`
- `../../carrotpilot/CARROTPILOT_ORIGINAL_ONROAD_HUD_ANALYSIS_2026-03-07_KO.md`

## 작업 규칙
- HUD 구조 변경은 먼저 이 문서를 갱신한다.
- `v3` 의미 계약을 깨는 변경은 새 버전 문서를 만든다.
- handoff / checklist / migration 메모는 `docs/architecture/hud/refactoring/` 아래에만 추가한다.
- 기존 `docs/architecture/hud/*.md` 문서는 배경 문서로 유지하되, 새 기준 문서 역할은 맡기지 않는다.

## 지금 시점의 판단
- `HUD Refactoring V3`는 현재 CarrotLink HUD 구현의 공식 이름으로 써도 된다.
- 이후 HUD 작업 요청이 오면, 우선 이 문서를 기준으로 작업 범위를 정하고 세부 문서로 내려가는 방식이 맞다.
