# HUD Adaptive Layout Spec (2026-03-07)

## 문서 목적
- `OriginalHudSnapshot`을 어떤 방식으로 화면에 배치할지 정의한다.
- 이 문서는 데이터 문서가 아니라 **adaptive 레이아웃 문서**다.
- 기존 HUD의 박스/카드/색/배치 방식은 참고하지 않는다.
- 목표는 “모든 size class와 surface에서 같은 의미를 다른 밀도로 보여주는 HUD”다.

관련 문서:
- [ADAPTIVE_HUD_REBUILD_PLAN_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/ADAPTIVE_HUD_REBUILD_PLAN_2026-03-07_KO.md)
- [HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md)
- [HUD_DATA_PIPELINE_REFACTOR_PLAN_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_DATA_PIPELINE_REFACTOR_PLAN_2026-03-07_KO.md)
- [HUD_CLUSTER_LAYOUT_VISUAL_GUIDE_2026-03-08_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_CLUSTER_LAYOUT_VISUAL_GUIDE_2026-03-08_KO.md)

주의:
- 이 문서는 adaptive 일반 원칙 문서다.
- 2026-03-08 기준 최신 시각 방향은 `원본 좌하단 HUD 클러스터 기반 재배치`이며, 실제 시각 구조와 색상 방향은 [HUD_CLUSTER_LAYOUT_VISUAL_GUIDE_2026-03-08_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_CLUSTER_LAYOUT_VISUAL_GUIDE_2026-03-08_KO.md)를 우선 참고한다.
- 현재 최신 레이아웃 키워드는 `상단 3분할 metric bar + 본문 좌측정보/우측정보 + 하단 상태바`다.
- 상단: `CPU / MEM / VOLT(DISK)` 3분할 고정 바
- 좌측정보: `현재속도` 메인 + `LIMIT / APN/APM/N/C`
- 우측정보: `설정속도` 메인 + `tempControl / gap / gear`
- 하단 상태바: `좌 red dot / 중앙 mode pill / 우 signal`

---

## 1. 설계 전제

### 1-1. 디자인은 완전 신규
이 문서는 아래를 전제로 한다.
- 기존 Home HUD 카드 레이아웃 폐기
- 기존 drive HUD 패널/overlay 레이아웃 폐기
- 기존 Android native overlay HUD UI 폐기
- 기존 carrot-like 색/장식/카드 모양 폐기

즉 가져가는 것은:
- 값 의미
- 정보 우선순위
- 표시/숨김 조건

뿐이다.

### 1-2. 같은 snapshot, 다른 배치
새 HUD는 모든 surface에서 같은 semantic snapshot을 본다.

즉 차이는:
- 보여주는 정보량
- 배치 위치
- 크기 밀도
- 인터랙션 방식

뿐이고, 값 계약은 동일해야 한다.

### 1-3. adaptive는 “scale”이 아니라 “layout mode”다
이 문서에서 adaptive는 단순 확대/축소가 아니다.

좋지 않은 방식:
- 같은 HUD를 통째로 scale 0.8
- 같은 카드의 가로/세로만 줄이기

권장 방식:
- surface별 slot 재배치
- density별 노출 항목 재구성
- 동일 semantic field의 다른 표현 방식

---

## 2. 목표 surface 정의

새 HUD는 아래 surface를 공식 지원한다.

## 2-1. `homePreview`
목적:
- 홈탭에서 live HUD 상태를 요약해서 보여줌

특징:
- 클릭 진입을 위한 preview 성격
- 정보 정확도는 live와 동일
- 시각적으로는 요약형

## 2-2. `driveInline`
목적:
- 주행화면에서 video/overlay와 함께 붙는 HUD

특징:
- camera/overlay와 시선 경쟁이 있음
- 정보 밀도 높지만 산만하면 안 됨

## 2-3. `driveOverlay`
목적:
- 주행화면 내 floating HUD

특징:
- video 위에 직접 얹힘
- 투명/저방해형 구조 필요
- 위치와 크기 제한이 큼

## 2-4. `systemOverlay`
목적:
- 앱 밖 Android overlay HUD

특징:
- 별도 창
- drag / bounds / overlay safe area 필요
- 어떤 앱 위에도 떠 있을 수 있음

## 2-5. `preview`
목적:
- 개발/디자인/디버그용 mock HUD

특징:
- live와 같은 layout engine 사용
- 데이터만 mock

---

## 3. 분류 축

HUD adaptive는 최소 4축으로 나눠야 한다.

## 3-1. width class
현재 앱 인프라 재사용:
- `compact`
- `medium`
- `expanded`
- `large`
- `extraLarge`

근거:
- [window_class.dart](/d:/CarrotLink/CarrotLink-dev/lib/ui/adaptive/window_class.dart)

## 3-2. density class
HUD는 width class만으로 부족하다.
같은 compact라도 overlay는 훨씬 빡빡할 수 있다.

권장 density class:
- `micro`
- `dense`
- `compact`
- `comfortable`
- `spacious`

권장 기준:
- shortest side
- surface kind
- safe area 제외 후 usable rect

예시:
- 아주 작은 멀티윈도우: `micro`
- 일반 폰 portrait: `dense`
- 일반 폰 landscape: `compact`
- 태블릿: `comfortable`
- 큰 화면: `spacious`

## 3-3. orientation
- `portrait`
- `landscape`

## 3-4. device feature
- normal
- fold vertical hinge
- fold horizontal hinge
- overlay host

---

## 4. 안전영역 기준

## 4-1. usable rect 우선
HUD 배치는 전체 화면이 아니라 **usable rect** 기준이어야 한다.

usable rect 계산 시 제외:
- status bar
- navigation bar
- camera/overlay 상단 badge
- 하단 dock / bottom sheet
- hinge/fold 가림 영역
- overlay drag affordance area

즉 배치 기준은 항상:
- `screen rect`
- `safe insets`
- `reserved UI regions`
- `hinge cutout`

을 뺀 나머지여야 한다.

## 4-2. overlay는 별도 safe rule
`systemOverlay`는 app canvas가 아니라 OS overlay이므로,
별도 safe margin이 필요하다.

권장:
- 최소 외곽 margin 유지
- close target / drag area와 충돌 금지
- 화면 밖 반쯤 나가는 상태 금지

---

## 5. HUD 정보 우선순위

모든 size에서 항상 다 보여주면 안 된다.
우선순위를 정해야 한다.

## 5-1. Tier 1: 절대 우선
어떤 size에서도 최대한 남기는 정보:
- 메인 속도
- 설정 속도
- temp control 최종 상태
- gear

## 5-2. Tier 2: 주행 의미 핵심
- drive mode
- LIMIT/CAM
- gap
- APN/APM

## 5-3. Tier 3: 상태 보조
- GPS
- signal state

## 5-4. Tier 4: 장치 상태
- CPU
- MEM
- DISK/VOLT

원칙:
- space가 부족하면 device metrics부터 접는다
- 주행 의미보다 장치 metrics가 먼저 사라져야 한다

---

## 6. Slot 기반 레이아웃 정의

새 HUD는 고정 카드가 아니라 slot 조합이어야 한다.

권장 slot:
- `primarySpeed`
- `setSpeed`
- `tempControl`
- `gear`
- `driveMode`
- `limit`
- `gap`
- `connectivity`
- `signal`
- `gps`
- `metrics`
- `status`

각 slot은 위치가 아니라 “정보 단위”다.

즉 같은 `driveMode` slot이라도:
- micro에서는 text only
- spacious에서는 badge

로 표현이 달라질 수 있다.

---

## 7. density별 노출 규칙

## 7-1. `micro`
대상:
- 아주 작은 분할 화면
- 좁은 overlay
- extreme compact

노출:
- `primarySpeed`
- `setSpeed`
- `tempControl`
- `gear`

조건부:
- `limit` 또는 `driveMode` 중 하나만

숨김:
- `metrics`
- `gps`
- `signal`
- `connectivity`
- `gap` bar 시각요소

표현 원칙:
- 숫자 우선
- label 최소화
- 한 줄 또는 2블록 구조

## 7-2. `dense`
대상:
- 일반 compact phone portrait
- 작은 drive overlay

노출:
- `primarySpeed`
- `setSpeed`
- `tempControl`
- `gear`
- `driveMode`
- `limit`
- `gap`

조건부:
- `connectivity`
- `gps`

숨김:
- `metrics`는 축약형 또는 1개만

## 7-3. `compact`
대상:
- 일반 phone landscape
- home preview standard

노출:
- Tier 1 + Tier 2 전부
- `gps`
- `connectivity`

조건부:
- `metrics` compact strip
- `signal`

## 7-4. `comfortable`
대상:
- tablet portrait
- drive inline large

노출:
- 대부분 표시
- `metrics` 전체 표시
- `signal` 표시

## 7-5. `spacious`
대상:
- large tablet
- fold unfolded

노출:
- 전체 표시 가능
- 단, 여백을 살려 시선 분산을 줄여야 함

주의:
- 정보를 더 많이 넣는다고 좋은 게 아니라,
  spacing과 grouping을 더 잘 줘야 한다

---

## 8. surface별 기본 배치 전략

## 8-1. `homePreview`
원칙:
- 요약형
- 정적 카드가 아니라 adaptive panel
- 하단 dock와 겹치지 않는 비율 유지

권장 배치:
- 상단: device metrics 축약 strip 또는 숨김
- 중앙 좌: 메인 속도
- 중앙 우: set speed + temp control
- 우측 또는 하단: gear
- 하단: drive mode / limit / gap

주의:
- home preview는 “실제 HUD 축소판”이 아니라
  “home surface에 맞는 summary layout”이어야 한다

## 8-2. `driveInline`
원칙:
- camera와 경쟁 최소화
- 시야 아래 또는 한쪽 safe zone
- 지속 노출형

권장:
- portrait: 하단 anchored band 또는 corner cluster
- landscape: 좌하 또는 우하 고정 cluster

주의:
- path/lane/lead overlay와 겹치지 않도록 reserved region 필요

## 8-3. `driveOverlay`
원칙:
- 떠 있는 작은 HUD
- draggable 가능
- transparency와 가독성 균형

권장:
- dense/compact 기준으로만 렌더
- device metrics는 숨기거나 아주 축약
- speed와 temp/gear 위주

## 8-4. `systemOverlay`
원칙:
- OS overlay 특성상 정보 과잉 금지
- drag handle / touch target 고려
- status나 fallback 표시도 필요

권장:
- 최소 semantic core만 보여주는 별도 density 정책 사용
- `systemOverlay`는 기본적으로 `dense` 이하로 제한

---

## 9. fold / hinge 대응

## 9-1. vertical hinge
원칙:
- hinge를 가로지르는 단일 HUD 금지
- 한쪽 pane에 완전히 들어가야 함

## 9-2. horizontal hinge
원칙:
- 상/하 분할 중 하나에 고정
- hinge 근처 중앙 정렬 금지

## 9-3. unfolded large layout
주의:
- 넓다고 중앙에 퍼뜨리지 말 것
- 시선 이동이 커지므로 grouping 강화 필요

---

## 10. 모듈 구조 권장

권장 presentation 구조:

```text
lib/features/hud/presentation/
  model/
  layout/
  surfaces/
  widgets/
  theme/
```

### 10-1. `model/`
- presentation 전용 view model
- semantic snapshot을 UI-friendly model로 변환

### 10-2. `layout/`
- `HudLayoutSpec`
- `HudSurfaceKind`
- `HudDensityClass`
- `HudSlotPlacement`

### 10-3. `surfaces/`
- `home_hud_surface.dart`
- `drive_hud_surface.dart`
- `overlay_hud_surface.dart`
- `preview_hud_surface.dart`

### 10-4. `widgets/`
- 재사용 가능한 slot renderer
- 예:
  - `hud_primary_speed_block.dart`
  - `hud_temp_control_block.dart`
  - `hud_limit_block.dart`
  - `hud_connectivity_badge.dart`
  - `hud_metric_strip.dart`

### 10-5. `theme/`
- 새 HUD 전용 색/타이포/spacing token
- 기존 색상 시스템과 분리 가능

---

## 11. 추천 layout engine 방향

권장:
- `slot + constraints` 기반
- `Stack` 남용 금지
- 절대좌표 비율 기반 복제 금지

좋은 방식:
- surface별 root layout
- 내부 slot grid/flex
- density별 visibility rule
- measured size 기반 variant 선택

권장 패턴:
- `LayoutBuilder`
- `CustomMultiChildLayout` 또는 명시적 slot layout
- token-driven spacing

지양:
- pixel ratio 수십 개 if/switch
- screen마다 수식 하나씩 추가하는 방식

---

## 12. motion / 상태 표현 원칙

디자인은 새로 가더라도 상태 변화 원칙은 필요하다.

권장:
- 값 변경 애니메이션은 짧고 명확하게
- 숫자 바뀔 때만 motion
- 레이아웃 자체 흔들림 금지
- placeholder -> live 전환은 fade 또는 number morph

금지:
- layout jump
- slot 위치 이동 애니메이션 남용
- 작은 화면에서 과한 micro-motion

---

## 13. 접근성 / 국제화

새 HUD는 기존 carrot식 고정형 UI와 달리 접근성도 고려해야 한다.

### 권장
- 숫자는 locale 독립 포맷
- label은 짧은 번역 가능 키로 관리
- screen reader는 overlay에서 제한적으로라도 의미 전달 가능하게 구조화

### 주의
- home/drive/overlay에서 다국어 길이가 다르므로
  라벨 고정보다 slot별 축약 정책 필요

---

## 14. 단계별 구현 순서

## 단계 1. layout primitive 정의
먼저 정의할 것:
- `HudSurfaceKind`
- `HudDensityClass`
- `HudSlot`
- `HudLayoutSpec`

## 단계 2. visibility rule 구현
먼저 정보 표시/숨김 규칙부터 고정

## 단계 3. slot widget 구현
speed, set speed, temp, gear, limit, mode, metrics 등

## 단계 4. surface layout 구현
- home
- drive inline
- drive overlay
- system overlay

## 단계 5. preview 연결
mock snapshot으로 각 density 검증

## 단계 6. 실제 live snapshot 연결

---

## 15. 검증 기준

adaptive HUD는 아래 케이스를 모두 통과해야 한다.

### 화면 크기
- compact portrait
- compact landscape
- medium
- expanded
- large
- extraLarge

### 상태
- 정상 live
- stale live
- metrics fallback active
- preview

### 기기 형태
- 일반 slab
- fold vertical hinge
- fold horizontal hinge
- Android overlay

### UX 기준
- Tier 1 정보는 항상 즉시 읽힘
- 정보 과밀로 인한 줄바꿈 붕괴 없음
- slot 충돌 없음
- safe area 침범 없음

---

## 16. 지금 시점의 결론

다음 구현은 “HUD widget 하나 다시 그리기”가 아니다.

정확히는:
- semantic snapshot 위에
- slot 기반 adaptive layout system을 얹고
- home / drive / overlay / preview가
- 같은 규칙으로 다른 density를 보여주게 만드는 작업

이 문서 기준으로 가면,
기존처럼 화면마다 다른 비율 보정 코드를 누적하는 방향은 끊을 수 있다.



