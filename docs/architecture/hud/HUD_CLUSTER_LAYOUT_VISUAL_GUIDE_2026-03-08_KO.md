# HUD Cluster Layout / Visual Guide (2026-03-08)

## 문서 목적
- 이 문서는 `좌하단 원본 HUD 클러스터`를 기준으로 adaptive HUD를 다시 정렬하기 위한 최신 시각 가이드다.
- `OriginalHudSnapshot`의 **필드 의미는 유지**하고, **레이아웃과 시각 표현만** 재정의한다.
- 기존 [HUD_ADAPTIVE_LAYOUT_SPEC_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_ADAPTIVE_LAYOUT_SPEC_2026-03-07_KO.md)의 일반 adaptive 원칙 위에 올라가는 **최신 보정 가이드**다.

관련 문서:
- [HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_SEMANTIC_SNAPSHOT_SPEC_2026-03-07_KO.md)
- [HUD_ADAPTIVE_LAYOUT_SPEC_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/hud/HUD_ADAPTIVE_LAYOUT_SPEC_2026-03-07_KO.md)
- [CARROTPILOT_ORIGINAL_ONROAD_HUD_ANALYSIS_2026-03-07_KO.md](/e:/CarrotLink/CarrotLink/docs/architecture/carrotpilot/CARROTPILOT_ORIGINAL_ONROAD_HUD_ANALYSIS_2026-03-07_KO.md)

---

## 1. 최신 방향 수정

기존 adaptive HUD는 같은 semantic field를 사용하지만, 결과적으로:
- 카드형 패널 느낌이 강했고
- 원본 좌하단 HUD의 클러스터 감각이 약했고
- 작은 사이즈에서 정보가 과하게 분산되거나 overflow 되기 쉬웠다.

최신 방향은 아래다.

- `원본 좌하단 HUD 클러스터 감각`을 다시 기준으로 삼는다.
- adaptive는 `카드를 재배치`하는 게 아니라 `하나의 클러스터를 density별로 압축`하는 방식으로 본다.
- `driveMode`만 한글화하고, 나머지 필드 표기는 원본 느낌을 유지한다.
- device metrics는 중요도가 가장 낮으므로 가장 먼저 축약한다.

한 줄 요약:
- `새 HUD를 만든다`가 아니라
- `원본 좌하단 HUD를 adaptive하게 다시 배치한다`

---

## 2. 의미 유지 원칙

레이아웃을 바꿔도 아래 의미는 유지해야 한다.

- 메인 속도: `vehicle.speedClusterKph`
- 설정 속도: `vehicle.setSpeedClusterKph`
- temp 제어: `tempControl.label`, `tempControl.speedKph`
- 갭: `gap.displayValue`
- 기어: `vehicle.gearText`
- 드라이브 모드: `driveMode.nameOriginal`
- 제한속도/CAM: `limits.label`, `limits.displaySpeedKph`
- APN/APM: `connectivity.badgeLabel`
- 장치 상태: `device.cpuTempAvgC`, `device.memUsagePct`, `device.voltV`, `device.diskUsedPct`

중요:
- Flutter/UI는 temp, limit, connectivity의 의미를 다시 추론하지 않는다.
- source에서 이미 계산된 semantic state를 그대로 쓴다.

---

## 3. 공통 HUD 클러스터 골격

모든 adaptive size는 아래 `좌측 주행 / 우측 보조` 2축 클러스터를 기준으로 변형한다.

```text
┌──────────────────────── HUD CLUSTER ────────────────────────┐
│                                            [cpu] [mem] [v] │
│                                                            │
│  ●                                                         │
│  34                    80                         [ 7 ]     │
│                        eco / vturn                         │
│                        (2)                                 │
│                                                            │
│  [일반]               [ LIMIT 70 ]               [ APN ]   │
└────────────────────────────────────────────────────────────┘
```

구성 해석:
- 좌측: 현재 속도 중심 메인 영역
- 좌측 하단: 드라이브모드 / 제한속도 / APN/APM
- 우측 상단: CPU / MEM / VOLT 또는 DISK
- 우측 중하단: 설정속도 / temp / gap / 기어 / signal

이 골격은 `driveOverlay`, `driveInline`, `homePreview` 모두 공유한다.

---

## 4. 필드별 시각 우선순위

### 4-1. 절대 보존
- 현재 속도
- 설정속도
- 기어
- LIMIT/CAM

### 4-2. 높은 우선순위
- temp label
- temp speed
- 드라이브모드
- APN/APM

### 4-3. 보조
- gap
- GPS
- signal/red dot

### 4-4. 가장 낮은 우선순위
- CPU
- MEM
- VOLT/DISK
- source/quality/compat 같은 개발 메타

원칙:
- 공간이 줄어들면 device metrics가 가장 먼저 축약/숨김된다.
- 개발 메타는 기본 사용자 HUD에서 항상 최하위다.
- `LON / LAT`, `SIG OFF`, `NO GPS`, `hidden`처럼 의미 설명이 필요한 내부 상태 문자열은 기본 HUD의 메인 정보로 올리지 않는다.
- `gearText == U`는 unknown 상태로 보고, 큰 기어 박스가 아니라 작은 보조 표기로만 남긴다.

---

## 5. 필드 표기 규칙

### 5-1. 드라이브 모드
`driveMode.nameOriginal`은 UI에서만 한글로 바꾼다.

매핑:
- `ECO -> 에코`
- `SAFE -> 안전`
- `NORM -> 일반`
- `FAST -> 고속`

### 5-2. 나머지 표기
아래는 원본 느낌 유지:
- `LIMIT`
- `CAM`
- `APN`
- `APM`
- 기어 숫자/문자
- temp label (`eco`, `vturn`, `nda`, ...)

즉, `driveMode`만 한글이고 나머지는 원본 계열 표기를 최대한 유지한다.

---

## 6. density별 레이아웃 목표

## 6-1. `micro`
대상:
- 매우 작은 overlay
- 작은 멀티윈도우

구조:

```text
[cpu][mem][v]

34   80   [7]
     eco
     (2)

[일반] [70] [APN]
```

원칙:
- `CPU/MEM/VOLT`는 아이콘 + 값
- temp는 1줄
- gap은 숫자만
- LIMIT는 라벨 없이 숫자만 허용 가능

## 6-2. `compact`
대상:
- 일반 폰 세로
- 좁은 overlay

구조:

```text
                    [cpu][mem][v]

●
34        80                    [7]
          eco / vturn
          (2)

[일반]      [ LIMIT 70 ]      [ APN ]
```

원칙:
- 원본 좌하단 클러스터 느낌 유지
- 속도 / 설정속도 / 기어 3축 고정
- 하단 strip 유지

## 6-3. `regular`
대상:
- 일반 폰 가로
- 주행 HUD 기본

구조:

```text
                              [cpu 75][mem 63][12.7]

●
34            80                            [7]
              eco / vturn
              (2)

[일반]            [ LIMIT 70 ]            [ APN ]
```

원칙:
- 사진과 가장 비슷한 형태
- 정보 추가보다 spacing 개선 우선

## 6-4. `spacious`
대상:
- 큰 화면
- 여유 있는 preview

구조:

```text
                                [cpu 75][mem 63][volt 12.7]

●
  34               80                               [7]
                   eco / vturn
                   (2)

[일반]                [ LIMIT 70 ]                 [ APN ]
```

원칙:
- regular와 같은 정보 구조
- 여백과 정렬 개선
- 카드 추가 금지

---

## 7. surface별 적용 원칙

## 7-1. `driveOverlay`
- 가장 중요한 기준 surface
- 항상 좌하단 도킹 클러스터 느낌 유지
- device metrics는 가장 작게
- 개발 메타는 기본 숨김

## 7-2. `driveInline`
- 같은 클러스터 구조 유지
- overlay보다 약간 정리된 panel형
- metrics는 overlay보다 조금 더 보여줄 수 있다

## 7-3. `homePreview`
- live parity보다는 summary
- 그래도 클러스터 언어는 동일
- 속도 / 설정속도 / mode / limit 중심

---

## 8. device metrics 축약 규칙

원본 사진처럼 `CPU / MEM / VOLT`가 있는 것은 맞다.
하지만 adaptive에서는 중요도상 가장 약해야 한다.

권장 규칙:
- `spacious`: `CPU 75 / MEM 63 / 12.7V`
- `regular`: `CPU 75 / MEM 63 / 12.7`
- `compact`: 아이콘 + 숫자
- `micro`: 아이콘 + 숫자 또는 1개만

권장 아이콘:
- CPU: thermometer 또는 chip
- MEM: stacked layers 또는 memory
- VOLT/DISK: bolt 또는 storage

중요:
- 라벨 박스 3개가 주 정보보다 더 크면 안 된다.
- 항상 `속도/설정속도`보다 시각 강조가 약해야 한다.

---

## 9. 색상 / UX UI 방향

## 9-1. 기본 원칙
- 색상은 많이 쓰지 않는다.
- 밝은 장면과 어두운 장면에서 모두 읽혀야 한다.
- `채도 높은 색`은 상태 강조용으로만 쓴다.
- 기본은 `중성 + 고대비 + 제한된 accent`다.

## 9-2. 권장 팔레트

기본 중성:
- 배경: `rgba(10, 14, 18, 0.62)` 또는 `rgba(255, 255, 255, 0.12)` 계열 중 상황별 선택
- 외곽선: `rgba(255, 255, 255, 0.22)`
- 본문 텍스트: `#F4F7FB`
- 보조 텍스트: `#B8C2CF`
- 약한 구분선: `rgba(255, 255, 255, 0.10)`

상태 accent:
- 주행 기본 accent: `#6BFF9A` 계열의 낮은 면적 사용
- 제한속도 / 주의: `#FFC94D`
- 위험 / 초과 / red dot: `#FF5C5C`
- APN/APM / 연결 강조: `#7FD6FF`

원칙:
- 동시에 강하게 쓰는 accent는 최대 2개
- 기본 화면은 거의 `white + muted green + amber`
- red는 경고용으로만

## 9-3. 밝은/어두운 배경 대응

권장 방식:
- 반투명 단일 패널 위에 그리기
- 텍스트는 항상 어두운 외곽선 또는 shadow를 가짐
- 숫자/중요 pill은 1px 정도의 어두운 stroke를 둠
- 초록/노랑 같은 accent는 채도만 올리지 말고, 반드시 어두운 테두리와 같이 사용

즉:
- `밝은 배경에서는 테두리/그림자`
- `어두운 배경에서는 fill/밝기`

둘 다 있는 방향으로 가야 한다.

## 9-4. 코드 레벨 방향

색상과 스타일은 하드코딩 분산보다 `theme/token`으로 묶는 게 맞다.

예시:
- `HudColorTokens.background`
- `HudColorTokens.surfaceBorder`
- `HudColorTokens.primaryText`
- `HudColorTokens.secondaryText`
- `HudColorTokens.accentDrive`
- `HudColorTokens.accentWarning`
- `HudColorTokens.accentDanger`
- `HudColorTokens.accentConnectivity`

그리고 slot별로:
- `speed`
- `setSpeed`
- `temp`
- `gear`
- `limit`
- `mode`
- `connectivity`
- `metrics`

가 어떤 색 토큰을 쓸지만 지정하는 식이 맞다.

---

## 10. overflow 방지 원칙

- adaptive는 전체 scale-down이 아니라 slot 재배치여야 한다.
- 같은 정보를 줄일 때는:
  1. 메타 제거
  2. metrics 축약
  3. temp label 축약
  4. APN/APM 최소화
  5. 마지막까지 속도 / 설정속도 / 기어 / LIMIT 보존

금지:
- 속도 숫자 폰트만 과하게 줄이기
- 메인/보조 정보 위계를 뒤집는 카드 증가
- density가 낮아졌는데 박스 수가 늘어나는 구조

---

## 11. 구현 전에 고정할 기준

실제 구현 전에 아래를 고정해야 한다.

- `좌하단 HUD 클러스터`를 공통 기본 뼈대로 삼는다
- `driveMode`만 한글화한다
- `CPU/MEM/VOLT(DISK)`는 아이콘형 소형 정보로 내린다
- `source/quality/compat`는 기본 HUD 본체에서 제거하거나 개발 모드에만 남긴다
- 모든 size는 같은 클러스터를 압축한 형태여야 한다

한 줄 결론:
- `adaptive card panel`을 계속 다듬는 방식보다
- `원본 좌하단 HUD 클러스터 기반 adaptive layout`으로 다시 정렬하는 것이 맞다
