# HUD Data Pipeline 재구축 계획 (2026-03-07)

## 문서 목적
- 새 adaptive HUD를 구현하기 전에, HUD 데이터가 어떤 경로로 수집되고 가공되고 전달되어야 하는지 정의한다.
- 이 문서는 UI 문서가 아니다.
- 이 문서는 `원본 HUD 값 의미를 손상시키지 않는 데이터 파이프라인`을 설계하는 문서다.

관련 문서:
- [CARROTPILOT_ORIGINAL_ONROAD_HUD_ANALYSIS_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/carrotpilot/CARROTPILOT_ORIGINAL_ONROAD_HUD_ANALYSIS_2026-03-07_KO.md)
- [ADAPTIVE_HUD_REBUILD_PLAN_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/ADAPTIVE_HUD_REBUILD_PLAN_2026-03-07_KO.md)
- [HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md)

---

## 1. 현재 파이프라인 요약

현재 HUD 데이터 흐름은 크게 3개다.

### 1-1. Flutter 홈/주행 HUD
경로:
- [home_hud_preview_card.dart](/d:/CarrotLink/CarrotLink-dev/lib/widgets/home_hud_preview_card.dart#L623)

현재 흐름:
1. `HomeHudPreviewCard` 내부에서 isolate 생성
2. widget 내부 worker가 `ws://<ip>:7000/ws/carstate` 연결
3. payload를 widget 내부 `_HudSnapshot`으로 파싱
4. widget이 바로 렌더링

문제:
- 데이터 수집이 widget 내부에 박혀 있음
- home/drive가 같은 widget에 묶여 있음
- raw payload 해석과 렌더링이 분리되지 않음

### 1-2. Flutter fallback metrics
경로:
- [home_tab.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/tabs/home_tab.dart#L225)
- [live_drive_canvas_hud_components.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/drive/live_drive_canvas_hud_components.dart#L14)
- [ssh_service.dart](/d:/CarrotLink/CarrotLink-dev/lib/services/ssh_service.dart#L925)

현재 흐름:
1. SSH로 CPU/MEM/DISK 쉘 계산
2. 홈탭 또는 주행화면 state에 fallback 저장
3. `HomeHudPreviewCard`에 fallback prop으로 주입

문제:
- metric fallback이 widget prop으로 흘러 들어감
- semantic snapshot 외부에서 값이 끼어듦
- 어느 값이 live이고 어느 값이 fallback인지 UI가 구분하기 어려움

### 1-3. Android native HUD overlay
경로:
- [native_overlay_hud_service.dart](/d:/CarrotLink/CarrotLink-dev/lib/services/native_overlay_hud_service.dart)
- [OverlayHudService.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudService.kt#L239)

현재 흐름:
1. Android foreground overlay service가 직접 `ws://<host>:7000/ws/carstate` 연결
2. Android native에서 payload 직접 파싱
3. fallback metrics도 method channel로 따로 주입
4. native view tree를 직접 갱신

문제:
- Flutter HUD와 데이터 파이프라인이 분리됨
- semantic contract가 공통이 아님
- overlay만 별도 제품처럼 동작함

---

## 2. 현재 구조의 핵심 문제

## 2-1. source of truth가 없다
현재는:
- widget 내부 websocket
- SSH fallback
- Android native websocket

이 동시에 존재한다.

즉 `HUD 값의 유일한 진실 소스`가 없다.

## 2-2. UI layer가 payload semantics를 해석한다
현재 Flutter는:
- `temp.source` 비어 있으면 `eco` 기본값
- `diskLabel`과 fallback 조합으로 label 추정
- 일부 필드를 widget에서 조합

이건 새 adaptive HUD에 가장 나쁜 구조다.

## 2-3. preview / live / overlay가 같은 값을 다른 방식으로 받는다
현재는:
- preview는 widget mock 또는 실시간 IP
- live HUD는 widget 직접 websocket
- native overlay는 Android service 직접 websocket

즉 surface마다 data path가 다르다.

## 2-4. fallback이 domain 밖에서 개입한다
CPU/MEM/DISK fallback은 필요하지만,
지금처럼 widget prop에 끼우는 구조는 장기적으로 확장성이 낮다.

---

## 3. 새 파이프라인 목표

목표는 단순하다.

### 목표 1
모든 HUD surface가 **같은 semantic snapshot**을 받는다.

### 목표 2
모든 raw source 해석은 **repository/data layer**에서 끝낸다.

### 목표 3
fallback은 semantic snapshot 안에 명시적으로 들어간다.

### 목표 4
preview / live / overlay는 **같은 snapshot consumer**가 된다.

즉 새 구조는:
- raw source -> mapper -> `OriginalHudSnapshot` -> UI

하나로 정리되어야 한다.

---

## 4. 권장 계층 구조

## 4-1. Domain Layer
목적:
- HUD 값 의미 정의

구성:
- `OriginalHudSnapshot`
- `HudDriveModeState`
- `HudLimitState`
- `HudConnectivityState`
- `HudDeviceMetricsState`

참조:
- [HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md)

## 4-2. Data Source Layer
목적:
- 실제 raw 데이터 수집

구성 후보:
- `HudRemoteStreamDataSource`
- `HudFallbackMetricsDataSource`
- `HudPreviewDataSource`

역할:
- remote ws 수신
- fallback metric 수집
- preview/mock snapshot 생성

## 4-3. Mapper Layer
목적:
- raw payload -> semantic snapshot 변환

구성 후보:
- `HudRemotePayloadMapper`
- `HudFallbackMergePolicy`
- `HudSnapshotAssembler`

중요:
- Flutter widget 안에 이런 로직이 들어가면 안 된다

## 4-4. Repository / Controller Layer
목적:
- app 전체 HUD state 공급

구성 후보:
- `HudRepository`
- `HudController`
- `HudSubscriptionHandle`

역할:
- live source 시작/정지
- surface별 subscribe
- snapshot fan-out
- staleness / reconnect / degradation 상태 관리

## 4-5. Presentation Layer
목적:
- snapshot을 사용해 adaptive HUD 렌더링

구성:
- home HUD
- drive HUD
- overlay HUD
- preview HUD

중요:
- presentation은 snapshot만 받고 raw source를 모른다

---

## 5. 권장 source 구성

## 5-1. 1차 목표 source
초기엔 다음 3개 source만 두는 게 맞다.

### A. Live HUD remote source
역할:
- 기기에서 live HUD용 원본 의미 데이터 수신

권장 transport:
- 새 `HUD semantic snapshot` endpoint 또는 sidecar HUD endpoint

주의:
- 현재 `7000/ws/carstate`는 임시 호환용으로만 본다
- 최종 목적지는 원본 HUD semantic spec을 만족하는 전용 snapshot source다

### B. Fallback metrics source
역할:
- CPU/MEM/DISK 보조값 제공

허용 범위:
- `device.cpuTempAvgC`
- `device.memUsagePct`
- `device.diskUsedPct`

금지 범위:
- GPS
- limits
- drive mode
- temp control
- APN/APM

### C. Preview source
역할:
- 개발 중 mock snapshot 공급

중요:
- preview는 live source를 흉내 내는 것이지, UI를 직접 흉내 내는 것이 아니다
- 즉 preview도 `OriginalHudSnapshot`을 만들어야 한다

---

## 6. 권장 repository 구조

추천 개념은 아래와 같다.

### 6-1. `HudRepository`
책임:
- live HUD snapshot stream 제공
- preview snapshot 제공
- fallback merge 정책 적용

예상 인터페이스:

```dart
abstract interface class HudRepository {
  Stream<OriginalHudSnapshot> watchLive({required String host});
  Stream<OriginalHudSnapshot> watchPreview();
  Future<OriginalHudSnapshot?> getLatest();
  Future<void> warmUp(String host);
  Future<void> disposeHost(String host);
}
```

### 6-2. `HudController`
책임:
- UI surface 생명주기와 repository를 연결
- home / drive / overlay surface에서 공통 사용

예상 역할:
- host 변경 처리
- foreground/background 반영
- stale state 관리
- error / reconnect / degraded state 반영

### 6-3. `HudSnapshotAssembler`
책임:
- remote snapshot과 fallback metrics를 merge
- 어떤 필드를 fallback으로 대체할지 결정

예시 규칙:
- live `cpuTempAvgC` 없으면 fallback 허용
- live `gps.hasFix` 없다고 fallback true 넣지 않음

---

## 7. 권장 merge 정책

가장 중요하다.

## 7-1. live 우선
원칙:
- semantic field는 live source가 최우선

예:
- `driveMode`
- `tempControl`
- `limits`
- `signals`
- `connectivity`
- `gps`

이 필드는 live가 없으면 `null` 또는 `hidden`이어야지,
fallback이 대신 의미를 만들면 안 된다.

## 7-2. metric fallback only
아래만 fallback 허용:
- `device.cpuTempAvgC`
- `device.memUsagePct`
- `device.diskUsedPct`

추가 규칙:
- fallback이 적용되면 `meta.isFallbackMetricsApplied = true`
- field-level로 provenance를 남겨도 좋다

예:

```json
"meta": {
  "fieldSource": {
    "device.cpuTempAvgC": "fallback_ssh",
    "device.memUsagePct": "live",
    "device.diskUsedPct": "fallback_ssh"
  }
}
```

## 7-3. staleness 정책
권장:
- live snapshot 1~2초 이상 멈추면 `quality = degraded`
- 3초 이상이면 surface에 stale 상태를 전달

이 정보는 HUD layout가 아니라 repository/meta가 관리해야 한다.

---

## 8. surface별 연결 방식

## 8-1. 홈탭 HUD
현재:
- widget 내부 websocket

새 구조:
- `HudController(host)` 구독
- latest snapshot만 렌더

역할:
- preview가 아니라 “실제 live HUD monitor”로 동작

## 8-2. 주행화면 HUD
현재:
- home HUD widget 재사용
- fallback state 따로 관리

새 구조:
- drive 전용 HUD surface가 `HudController(host)` 구독
- live snapshot과 overlay frame sync는 분리

중요:
- HUD는 overlay frame sync에 종속될 필요가 없다
- HUD 값은 semantic stream으로 별도 유지 가능

## 8-3. HUD overlay
현재:
- Android native service가 직접 websocket 연결

새 구조 권장:
- 최종적으로는 overlay도 같은 `OriginalHudSnapshot` 계약을 사용

가능한 경로:
1. native overlay host가 semantic snapshot endpoint만 소비
2. 또는 Flutter HUD renderer를 overlay에 재사용

장기 권장:
- native overlay는 host/lifecycle 역할만 남기고
- HUD UI는 공통 presentation layer로 수렴

## 8-4. preview HUD
현재:
- widget 내부 preview/mock + live 혼합

새 구조:
- `PreviewHudSnapshotFactory`
- `HudRepository.watchPreview()`

즉 preview도 live와 같은 semantic snapshot 소비자여야 한다.

---

## 9. 기존 코드 해체 우선순위

## 9-1. 1순위 해체 대상
- [home_hud_preview_card.dart](/d:/CarrotLink/CarrotLink-dev/lib/widgets/home_hud_preview_card.dart#L623)

이유:
- data source + parse + render + fallback이 다 들어있다

조치 방향:
- 단계적으로
  - websocket worker 제거
  - `_HudSnapshot` 제거
  - semantic snapshot consumer로 전환

## 9-2. 2순위 해체 대상
- [OverlayHudService.kt](/d:/CarrotLink/CarrotLink-dev/android/app/src/main/kotlin/com/example/carrot_pilot_manager/OverlayHudService.kt#L520)

이유:
- native UI tree가 완전히 별개
- adaptive HUD 재사용이 어렵다

조치 방향:
- 먼저 data path 분리
- 그 다음 UI 구현체 축소

## 9-3. 3순위 정리 대상
- [home_tab.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/tabs/home_tab.dart#L225)
- [live_drive_canvas_hud_components.dart](/d:/CarrotLink/CarrotLink-dev/lib/screens/drive/live_drive_canvas_hud_components.dart#L3)

이유:
- fallback timer와 HUD surface wiring이 흩어져 있다

조치 방향:
- controller/repository 기반 wiring으로 교체

---

## 10. 단계별 실행 계획

## 단계 1. semantic spec 고정
완료 기준:
- [HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md) 확정

## 단계 2. data pipeline 설계 고정
완료 기준:
- 이 문서 확정

## 단계 3. Flutter domain/data skeleton 도입
예상 결과:
- `lib/features/hud/domain/...`
- `lib/features/hud/data/...`
- `lib/features/hud/application/...`

## 단계 4. live remote adapter 구현
예상 결과:
- 기존 raw `ws/carstate` 또는 신규 HUD endpoint를 semantic snapshot으로 변환

## 단계 5. fallback metrics adapter 구현
예상 결과:
- fallback merge를 repository 밖에서 안 하게 만듦

## 단계 6. home/drive HUD를 새 controller로 전환
예상 결과:
- `HomeHudPreviewCard`는 presentation만 남김 또는 대체

## 단계 7. overlay path 정리
예상 결과:
- native overlay의 websocket 직접 연결 제거 또는 축소

---

## 11. 구현 시 금지사항

다음은 하면 안 된다.

### 금지 1
새 adaptive HUD widget 안에 websocket 연결 넣기

### 금지 2
Flutter widget에서 raw payload 의미 추론하기

### 금지 3
fallback으로 semantic field 채우기

### 금지 4
surface마다 다른 snapshot 타입 쓰기

### 금지 5
preview 전용 필드를 live HUD 타입에 섞기

---

## 12. 결론

새 adaptive HUD가 제대로 되려면,
지금 가장 먼저 바꿔야 하는 것은 레이아웃이 아니라 **data pipeline**이다.

즉:
- widget 내부 websocket 제거
- semantic snapshot 통합
- fallback merge 중앙화
- overlay/home/drive 공통 repository 사용

이 네 가지가 먼저다.

다음으로 이어질 문서는:
- `HUD adaptive layout spec`



