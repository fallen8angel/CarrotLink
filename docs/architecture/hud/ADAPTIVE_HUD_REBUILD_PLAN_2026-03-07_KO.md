# Adaptive HUD 전면 재구축 계획 (2026-03-07)

## 전제
- 이 문서는 `원본 carrot HUD의 값 의미`만 유지하고,
  `기존 CarrotLink HUD의 UX/UI, 레이아웃, 색상, 시각 스타일, 구현 방식`은 전부 폐기하는 것을 전제로 한다.
- 즉 재사용 대상은 `데이터 의미`뿐이다.
- 재사용하지 않는 대상:
  - 기존 `HomeHudPreviewCard`의 디자인
  - 기존 주행화면 내 HUD 배치 방식
  - 기존 Android 네이티브 HUD 오버레이 UI 레이아웃
  - 기존 HUD 색상 팔레트
  - 기존 카드형 비율/배경/장식

## 목표
- 매우 작은 화면부터 폴드/태블릿/큰 화면까지 모두 대응하는 adaptive HUD를 새로 설계한다.
- 홈탭 HUD, 주행화면 HUD, HUD 오버레이가 모두 같은 데이터 모델을 사용하도록 통합한다.
- 기존 구현의 “화면마다 다른 HUD”를 없애고, 공통 semantic snapshot 기반으로 재구성한다.
- 구조화와 모듈화를 우선한다.

## 이번 단계의 목표
- 지금 단계에서는 코드를 새로 짜는 것이 아니라, **기존 HUD 관련 구조를 해체 관점으로 분석하고 재구축 문서를 시작**한다.
- 즉, 무엇을 버리고 무엇만 남길지, 어떤 순서로 뜯고 다시 만들지 정의한다.

---

## 1. 검토 범위

이번에 검토한 현재 HUD 관련 구현 경로는 아래다.

### 1-1. 공통 Flutter HUD 위젯
- [home_hud_preview_card.dart](/d:/CarrotLink/CarrotLink-dev/lib/widgets/home_hud_preview_card.dart)

현재 역할:
- 홈탭 HUD 미리보기
- 주행화면 내 HUD 패널
- 주행화면 landscape HUD overlay

즉 하나의 위젯이 3개 surface를 동시에 담당한다.

### 1-2. 홈탭 HUD 사용처
- [home_tab.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/tabs/home_tab.dart#L587)

현재 역할:
- 홈탭 카드 안에서 `HomeHudPreviewCard`를 사용
- HUD fallback metrics도 여기서 주입

### 1-3. 주행화면 HUD 사용처
- [live_drive_canvas_hud_components.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/drive/live_drive_canvas_hud_components.dart#L372)

현재 역할:
- portrait 하단 HUD panel
- landscape HUD overlay
- drive mode tag / sidecar badge 등 보조 HUD와 혼합

### 1-4. HUD 설정 화면
- [hud_settings_screen.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/settings/hud_settings_screen.dart)

현재 역할:
- HUD overlay on/off
- HUD 기본 모드 설정

### 1-5. Android 네이티브 HUD 오버레이 서비스
- [native_overlay_hud_service.dart](/d:/CarrotLink/CarrotLink-dev/lib/services/native_overlay_hud_service.dart)
- [OverlayHudService.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudService.kt#L520)

현재 역할:
- 앱 밖 오버레이 HUD
- 자체 websocket 연결
- 자체 UI 레이아웃
- 자체 fallback metric 반영

즉 현재는 Flutter HUD와 Android native HUD가 사실상 **서로 다른 UI 코드**다.

---

## 2. 현재 구조의 문제

## 2-1. 데이터와 UI가 너무 강하게 결합되어 있다
현재 [home_hud_preview_card.dart](/d:/CarrotLink/CarrotLink-dev/lib/widgets/home_hud_preview_card.dart#L623)는:
- widget 안에서 worker isolate를 띄우고
- websocket을 직접 받고
- payload를 직접 파싱하고
- 바로 stateful widget으로 그림

문제:
- HUD 디자인을 버리고 다시 만들려 해도 데이터 수집 로직이 위젯 안에 박혀 있다
- home/drive/overlay에서 공통 domain layer를 만들기 어렵다

## 2-2. 하나의 위젯이 너무 많은 surface를 동시에 담당한다
현재 `HomeHudPreviewCard`는:
- 홈탭 preview
- 주행화면 panel
- 주행화면 overlay

를 모두 담당한다.

문제:
- preview와 real driving HUD의 요구사항이 다르다
- 그런데 한 위젯이 다 처리하다 보니 `비율`, `scale`, `parent fill`, `matchParentWidth` 같은 옵션이 계속 누적됐다

## 2-3. adaptive라기보다 “케이스별 보정”에 가깝다
현재는 `UiWindowClass`를 쓰고는 있지만,
- 홈탭은 따로 폭 cap 계산
- 주행화면 portrait는 별도 size 계산
- 주행화면 landscape는 또 다른 ratio 계산
- native overlay는 아예 dp 고정형

문제:
- 체계적인 adaptive 시스템이 아니라, 화면마다 다른 수식이 붙은 상태다

## 2-4. 네이티브 오버레이는 완전히 별도 제품처럼 구현돼 있다
[OverlayHudService.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudService.kt#L520)를 보면:
- `LinearLayout`
- `TextView`
- `dp(260)`, `dp(180)` 같은 고정 크기
- 자체 websocket 연결
- 자체 status text
- 자체 bar view

문제:
- Flutter HUD와 의미는 비슷해도 구조가 따로 논다
- adaptive 재설계와 구조화 관점에서 가장 큰 중복 소스다

## 2-5. 현재 색/스타일/레이아웃이 데이터 구조까지 끌고 다닌다
현재 구현은 기존 carrot 느낌을 따라가느라:
- 카드형
- 녹색 중심
- 특정 box 배치
- 특정 비율

이런 시각 규칙이 데이터 필드 구조와 사실상 묶여 있다.

문제:
- 지금처럼 완전 새 UX/UI로 가려면 이 결합을 먼저 끊어야 한다

---

## 3. 무엇을 남기고 무엇을 버릴 것인가

## 3-1. 남길 것
- 원본 HUD semantic field 의미
- 원본 필드 우선순위
- 원본 값 생산 원리
- 기존 `UiWindowClass`, `UiLayoutTokens` 같은 앱 전반 adaptive infrastructure
- HUD 설정/모드라는 개념 자체

## 3-2. 버릴 것
- `HomeHudPreviewCard`의 현재 레이아웃
- `HomeHudPreviewCard`의 현재 스타일/색/장식
- 주행화면 portrait panel의 현재 비율/배치
- 주행화면 landscape overlay의 현재 비율/배치
- Android `OverlayHudService.kt`의 현재 UI 조립 코드
- 기존 HUD용 box/metric/gear/gap UI 모양
- 기존 “한 widget으로 모든 surface 대응” 방식

---

## 4. 새 목표 구조

새 adaptive HUD는 아래 4층으로 나눠야 한다.

### 4-1. HUD Domain Layer
책임:
- HUD가 필요로 하는 의미 필드 정의
- 원본 HUD semantics를 공통 snapshot으로 정리

예시:
- `OriginalHudSnapshot`
- `HudMetricSnapshot`
- `HudLimitState`
- `HudDriveMode`
- `HudSignalState`

중요:
- Flutter widget은 raw websocket payload를 직접 해석하지 않는다

### 4-2. HUD Data Layer
책임:
- 원본 HUD 값 수집
- sidecar/ws/fallback 결합
- snapshot 생성

구성 예시:
- `HudRepository`
- `HudRemoteDataSource`
- `HudFallbackMetricsSource`
- `HudSnapshotMapper`

중요:
- home/drive/overlay가 같은 repository를 바라봐야 한다
- widget 내부 isolate/websocket 구조는 제거 대상이다

### 4-3. HUD Adaptive Layout Layer
책임:
- 화면 크기/방향/힌지/overlay 여부에 따라 slot을 정한다
- 어떤 필드가 어디에 들어갈지 배치 규칙만 가진다

예시:
- `HudLayoutSpec`
- `HudSlot`
- `HudDensity`
- `HudSurfaceKind`

surface 예시:
- `homePreview`
- `driveInline`
- `driveOverlay`
- `systemOverlay`

중요:
- “이 화면에서는 이 위젯을 scale 0.87” 식이 아니라
- “이 surface는 compact dense, 이 slot은 topLeading metric cluster” 식의 구조여야 한다

### 4-4. HUD Render Layer
책임:
- 실제 UI 그리기
- 색/타이포/모션/shape

중요:
- 여기서만 새 UX/UI를 만든다
- domain/data/layout은 디자인과 분리

---

## 5. 권장 구현 방향

## 5-1. 공통 semantic snapshot을 먼저 만든다
새 adaptive HUD는 반드시 공통 snapshot 하나를 기준으로 해야 한다.

예시 필드:
- 속도
- 설정속도
- temp reason / temp speed
- gear
- drive mode
- gap
- GPS
- LIMIT/CAM
- APN/APM
- CPU/MEM/DISK/VOLT
- signal/traffic state

핵심:
- 디자인을 바꾸더라도 값 의미는 안 흔들려야 한다

## 5-2. UI surface별로 “별도 위젯”을 두되, 같은 layout engine을 쓴다
예상 구성:
- `AdaptiveHudSurface`
- `HomeHudSurface`
- `DriveHudSurface`
- `OverlayHudSurface`

하지만 내부적으로는 같은 layout spec과 render component를 공유한다.

즉:
- 파일은 나뉘되
- 의미와 배치 규칙은 공통

## 5-3. Android 오버레이는 “UI 구현체”가 아니라 “호스트”로 축소한다
현재 native overlay service는 HUD를 직접 그린다.

새 구조에선 권장 방향이 이렇다.
- `OverlayHudService.kt`는 오버레이 창 lifecycle, drag, permission, foreground service만 담당
- 실제 HUD UI는 가능한 한 공통 HUD renderer를 사용

가능한 선택지:
1. Android overlay 안에 별도 Flutter HUD surface를 올리는 방식
2. 공통 layout schema를 native가 소비하는 얇은 shell 방식

문서 기준 권장:
- 장기적으로는 `native service = host only`
- `HUD UI = 공통 renderer`

## 5-4. preview와 real HUD를 분리한다
현재 preview와 실제 HUD가 너무 많이 섞여 있다.

새 구조 권장:
- `PreviewHudSnapshotFactory`
- `LiveHudSnapshotRepository`

즉 프리뷰는 가짜 데이터 공급만 담당하고,
실제 렌더 구조는 live HUD와 같게 맞춘다.

---

## 6. adaptive 설계 기준

## 6-1. 기준 viewport
반드시 아래를 기준으로 레이아웃을 나눈다.
- `compact`
- `medium`
- `expanded`
- `large`
- `extraLarge`

근거:
- [window_class.dart](/d:/CarrotLink/CarrotLink-dev/lib/ui/adaptive/window_class.dart)

## 6-2. 화면 축
아래 축도 같이 본다.
- portrait / landscape
- full-screen / split / floating
- fold / hinge 유무
- app surface / overlay surface

## 6-3. 최소 대응 단위
HUD는 아주 작은 화면에서도 동작해야 하므로 최소 단위가 필요하다.

권장 단위:
- `dense`
- `compact`
- `comfortable`
- `expanded`

이건 window class와 별도다.
예:
- 같은 compact라도 overlay에서는 dense
- home preview에서는 compact
- tablet full에서는 comfortable

## 6-4. 배치 원칙
권장 원칙:
- 속도는 항상 가장 우선
- 주요 제어 의미는 1초 안에 읽혀야 함
- device metrics는 축약 가능
- 극소형에서는 정보 밀도보다 안정된 정렬 우선
- fold/hinge에서는 안전영역 분리

---

## 7. 단계별 진행 계획

이번 작업은 너무 크기 때문에 반드시 단계별로 간다.

### 1단계. 기존 HUD 구조 해체 문서화
목표:
- 어떤 코드가 어디서 HUD를 만들고 있는지 정리
- 무엇을 버릴지 확정

이번 문서가 이 단계의 시작이다.

### 2단계. HUD semantic snapshot spec 문서화
목표:
- 원본 HUD 의미 필드 정의
- 원본 필드 -> 우리 snapshot 매핑 정의

산출물:
- `HUD_SEMANTIC_SNAPSHOT_SPEC_...md`

### 3단계. HUD data pipeline 재설계
목표:
- widget 내부 websocket 제거
- repository 기반 통합
- fallback 분리

산출물:
- `HUD_DATA_PIPELINE_PLAN_...md`

### 4단계. adaptive layout spec 정의
목표:
- 모든 window class / overlay surface에서 공통 배치 규칙 정의

산출물:
- `HUD_ADAPTIVE_LAYOUT_SPEC_...md`

### 5단계. Flutter 공통 HUD renderer 구현
목표:
- home / drive / preview 공유 renderer 구축

### 6단계. Android overlay host 정리
목표:
- native UI 제거 또는 최소화
- 공통 renderer를 overlay에서도 사용 가능하게 정리

---

## 8. 현재 코드 기준 즉시 해체 대상

우선적으로 해체 대상으로 보는 파일:
- [home_hud_preview_card.dart](/d:/CarrotLink/CarrotLink-dev/lib/widgets/home_hud_preview_card.dart)
- [OverlayHudService.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudService.kt#L520)

이유:
- 둘 다 현재 디자인/배치/데이터 해석이 강하게 결합돼 있다
- adaptive 구조와 semantic snapshot 분리에 가장 큰 장애물이다

단, 당장 삭제가 아니라:
- 우선 read-only 레거시 취급
- 신규 adaptive HUD 완성 뒤 제거

---

## 9. 이번 시점의 결론

지금 가장 맞는 방향은 이렇다.

- 원본 carrot HUD의 “값 의미”만 남긴다
- 현재 CarrotLink HUD의 UX/UI는 전부 버린다
- 새 HUD는 adaptive 전용으로 다시 만든다
- home, drive, overlay를 한 semantic snapshot 위에 올린다
- 현재 `HomeHudPreviewCard`와 `OverlayHudService`는 레거시로 취급한다

즉, 지금부터는 “기존 HUD 개선”이 아니라
**“HUD 제품을 새로 설계한다”**가 맞다.

---

## 10. 다음 문서 작업

바로 이어서 해야 할 문서는 아래다.

1. `HUD semantic snapshot spec`
2. `HUD data pipeline refactor plan`
3. `HUD adaptive layout spec`

이 순서가 맞다.

