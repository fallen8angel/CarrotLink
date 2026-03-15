# Stock 그래픽 1차 미세조정 기준 (2026-03-14)

## 문서 목적

- CarrotLink stock overlay에 1차로 붙인 `tf marker`, `BSD`, `LaneMode/Laneless`의 미세조정 기준을 남긴다.
- 현재는 실차 `alive` 확인이 어려운 상태이므로, 이번 수치는 "실기기 검증 전 안전한 보수값"이라는 전제를 명확히 남긴다.
- 이후 온디바이스에서 위치/크기 조정이 필요할 때 어떤 값이 의도값이고 어떤 값이 임시값인지 빠르게 판단할 수 있게 한다.

## 현재 전제

- 기준 원본은 `E:\Carrot\c3\selfdrive\ui\carrot.cc`
- 1차 구현 완료 범위
  1. `desiredDistance(tFollow)` 전방 마커
  2. 단순 BSD 바리어
  3. 하단 중앙 `LaneMode / Laneless`
- 이번 라운드는 실차 `alive` 검증 없이 진행하므로,
  - 카메라 실제 FoV
  - 하단 HUD 도킹 영역과의 실겹침
  - 세로/가로에서의 실제 체감 크기
  는 코드와 문서 기준으로만 보수 추정한다.

---

## 1. tf marker 미세조정 기준

### 1.1 의미

- 사용자가 말한 `ㅡ 9.8(0.32)`는 정지선이 아니라 `desiredDistance(tFollow)` 마커다.
- 값 원본은 `longitudinalPlan.desiredDistance`, `longitudinalPlan.tFollow`다.

### 1.2 이번 미세조정 방향

- sidecar 2D `tfMarker`가 있으면 그 값을 우선 사용한다.
- sidecar 2D `tfMarker`가 없으면 `modelPath + desiredDistance/tFollow` 기준으로만 투영한다.
- sidecar 2D가 `lead/radar`만 부분적으로 들어온 프레임이어도, `tfMarker`가 비어 있으면 projected fallback은 계속 유지한다.
- 텍스트는 기존보다 조금 작게 유지하고, 라인 오른쪽 끝점에서 약간 떨어뜨린 뒤 캔버스 안쪽으로 clamp 한다.

이유:

- 실차 확인이 없는 상태에서 가장 흔한 실패가 `오른쪽 하단 클리핑`과 `선 위 텍스트 겹침`이기 때문이다.
- c3는 full-screen 기준이고, CarrotLink stock은 HUD/버튼/폰 화면 비율 영향이 더 크다.

### 1.3 의도값

- 라인 기준 투영값
  - `y +/- 1.0`
  - `z + 1.22`
- 텍스트 배치
  - 우측 끝점 바로 위가 아니라 `약간 우하향 offset`
  - 캔버스 내부 margin clamp 적용
  - 큰 캔버스에서는 c3와 비슷한 margin/font 기준을 우선하고, 작은 화면만 적응형 inset/ellipsis를 허용

### 1.4 아직 안 한 것

- `trafficState`에 따른 `Signal Ready / Signal Error` 문구
- c3와 완전 동일한 애니메이션/점멸 표현

---

## 2. BSD 미세조정 기준

### 2.1 의미

- 현재 구현은 `leftBlindspot/rightBlindspot` 기본 바리어에 더해,
  `leadLeft/leadRight + laneChangeState` 기반 보조 경고까지 반영한 상태다.

### 2.2 이번 미세조정 방향

- 기하값은 c3 원본에 최대한 맞춘다.
  - `maxDistance ~= 40m`
  - `lineCenterShift = +/-1.7`
  - `z span ~= 1.15 -> 0.60`
- 다만 모바일 overlay는 c3 전체 화면보다 과하게 진해 보일 수 있어 fill/stroke alpha는 한 단계 보수적으로 둔다.

이유:

- 기하를 바꾸면 "원본과 다른 위치"가 되기 쉽고,
- 반대로 alpha만 조금 낮추면 실차 확인 전에도 과도한 시각 점유를 줄일 수 있다.

### 2.3 아직 안 한 것

- 실기기 기준 alpha/두께 미세조정
- 차종/브랜치별 `leadLeft/leadRight` 가용성 차이에 대한 추가 정책

---

## 3. LaneMode/Laneless 미세조정 기준

### 3.1 의미

- 원본 c3는 `useLaneLineSpeed` 변화 시 `LaneMode / Laneless`를 애니메이션 텍스트로 띄운다.
- 현재 CarrotLink는 사용자 선호상 이 부분을 "상시 상태 라벨"로 유지한다.

### 3.2 이번 미세조정 방향

- 하단 중앙 텍스트는 `latDebugText` 전체 문자열 기준으로 유지한다.
- `LaneMode/Laneless`는 상시 라벨로 두고, 바닥 문자열은 `latDebugText` 전체를 맡긴다.
- `LaneMode/Laneless`는 path/model geometry availability와 무관하게 연결 상태만 있으면 계속 유지한다.
- 하단 두 텍스트는 box bottom이 아니라 `baseline-bottom` 기준으로 맞춰, c3의 바닥 정렬과 더 가깝게 둔다.
- 이유는 주행 중 현재 모드를 즉시 읽기 쉽고, CarrotLink의 stock 레이아웃과도 잘 맞기 때문이다.

아직 일부러 안 한 것:

- c3의 전환 애니메이션을 프레임 단위로 그대로 복제
- bottom 텍스트의 픽셀 위치를 모든 해상도에서 완전 고정

---

## 4. Preview 기준

- 실차 `alive` 확인이 안 되는 동안 preview도 의미 있게 유지해야 한다.
- 그래서 preview에서는 일정 주기로
  - `LaneMode <-> Laneless`
  - `left BSD -> right BSD -> left lane-change assist -> none`
  가 보이도록 순환 샘플을 두는 편이 낫다.

의도:

- 온디바이스가 없어도 최소한 "겹침/클리핑/너무 큼" 문제를 대략 확인할 수 있게 한다.

---

## 5. 온디바이스에서 반드시 확인할 것

1. 세로 stock에서 하단 HUD와 `LaneMode/Laneless`가 겹치지 않는지
2. `tf marker` 텍스트가 우하단 바깥으로 잘리지 않는지
3. BSD 바리어가 차체 중앙을 덮지 않고 좌우 인접 영역처럼 보이는지
4. wide/road 카메라 전환 시 같은 요소가 과하게 점프하지 않는지
5. 낮/밤 화면에서 흰색 `tf marker`와 금색 BSD가 과도하게 튀지 않는지

---

## 6. 다음 단계

1. 온디바이스 캡처 기준으로 `BSD alpha / lane label y / tf marker offset` 3가지만 먼저 미세조정
2. 우상단 `LD / LT / SR`의 세로/가로 해상도별 크기와 잘림 여부 보정
3. 필요하면 bottom `latDebugText` 폭/크기 추가 보정

---

## 관련 문서

- `E:\Carrot\CarrotLink\docs\architecture\carrotpilot\CARROTPILOT_C3_C4_GRAPHICS_PORT_REVIEW_2026-03-14_KO.md`
- `E:\Carrot\CarrotLink\docs\architecture\carrotpilot\C3_STOCK_ONROAD_GRAPHICS_HUD_REFERENCE_2026-03-10_KO.md`
- `E:\Carrot\CarrotLink\docs\architecture\carrotpilot\CARROTPILOT_ONROAD_ELEMENT_MATRIX_2026-03-02_KO.md`
