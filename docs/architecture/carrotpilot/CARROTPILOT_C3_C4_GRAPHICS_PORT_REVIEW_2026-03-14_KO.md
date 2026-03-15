# C3/C4 그래픽 포팅 후보 검토 (2026-03-14)

## 문서 목적

- CarrotLink stock 화면에 추가하고 싶은 `c3/c4 계열 온로드 그래픽 요소`를 구현 난이도별로 정리한다.
- 기존 carrotpilot 문서를 참고하되, 결론은 실제 `c3/c4/CarrotLink` 코드 기준으로 잡는다.
- 이후 구현 시 "바로 그릴 수 있는 것"과 "sidecar payload 확장이 먼저 필요한 것"을 구분하는 기준 문서로 사용한다.

## 이번 검토 범위

사용자 요청 기준 후보:

1. 전방 정지선처럼 보이는 요소
2. 좌우 BSD 그래픽
3. 하단 중앙 `Lane/Laneless` 계열 표시
4. 우상단 `LD / LT / SR`

추가로, 사용자 캡처 확인 결과 이번에 실제로 의미를 먼저 확정해야 했던 항목은
`ㅡ 9.8(0.32)` 형태의 전방 하단 마커였다.

## 한 줄 결론

- 시각 기준 원본은 `c4`보다 `c3 selfdrive/ui/carrot.cc`를 먼저 보는 것이 맞다.
- 사용자가 말한 `ㅡ 9.8(0.32)`는 "정지선"보다는 `desiredDistance(tFollow)` 마커로 보는 것이 맞다.
- `BSD`, `Lane/Laneless`, `tf marker`는 1차 구현 후보로 적합하다.
- `LD / LT / SR`은 sidecar payload 확장이 필요하므로 2차 작업이 맞다.

---

## 1. 기준 원본은 c3 쪽이 맞는가

예. 현재 검토한 범위에서는 시각 기준 원본을 `c3`로 두는 것이 맞다.

근거:

- CarrotLink 기존 문서도 실제 활성 onroad 렌더러를 `selfdrive/ui/carrot.cc`로 본다.
  - `C3_STOCK_ONROAD_GRAPHICS_HUD_REFERENCE_2026-03-10_KO.md`
- 실제 원본 구현에서 이번 후보 요소들이 모두 `carrot.cc` 안에 모여 있다.
  - `PathEndDrawer`
  - `BlindSpotDrawer`
  - `DrawCarrot::drawHud`
  - `DrawCarrot::drawDeviceInfo`

핵심 참조:

- `PathEndDrawer`: `E:\Carrot\c3\selfdrive\ui\carrot.cc`
- `BlindSpotDrawer`: `E:\Carrot\c3\selfdrive\ui\carrot.cc:1343`
- `drawHud(...)`: `E:\Carrot\c3\selfdrive\ui\carrot.cc:2301`
- `drawDeviceInfo(...)`: `E:\Carrot\c3\selfdrive\ui\carrot.cc:2696`
- `LD/LT/SR` 문자열: `E:\Carrot\c3\selfdrive\ui\carrot.cc:2977`

판단:

- `c4`는 호환성/데이터 검증 대상에는 중요하지만, 이번 후보의 "원본 모양과 의미"를 따질 때는 1차 기준이 아니다.

---

## 2. `ㅡ 9.8(0.32)` 는 무엇인가

### 2.1 결론

이 값은 "전방 정지선"이라기보다 `desiredDistance(tFollow)` 마커다.

### 2.2 c3 원본 근거

`PathEndDrawer`에서:

- `t_follow = lp.getTFollow();`
- `tf_distance = lp.getDesiredDistance();`
- 이후 `sprintf(str, "%.1f(%.2f)", tf_distance, t_follow);`

참조:

- `E:\Carrot\c3\selfdrive\ui\carrot.cc:703`
- `E:\Carrot\c3\selfdrive\ui\carrot.cc:704`
- `E:\Carrot\c3\selfdrive\ui\carrot.cc:793`

또한 같은 블록 안에서 `trafficState`에 따라 `Signal Ready / Signal Error`도 함께 처리한다.

- `E:\Carrot\c3\selfdrive\ui\carrot.cc:742`

### 2.3 CarrotLink 현재 상태

CarrotLink overlay는 이미 이 개념을 이해하고 있다.

- `tfMarker`를 읽고
- 라인을 그린 뒤
- 텍스트를 `dist(tFollow)` 형식으로 표시한다.

참조:

- `E:\Carrot\CarrotLink\lib\screens\drive\live_drive_canvas_overlay_components.dart:2969`
- `E:\Carrot\CarrotLink\lib\screens\drive\live_drive_canvas_overlay_components.dart:2995`

관련 입력값도 sidecar 쪽에 이미 있다.

- `desiredDistance`
- `tFollow`
- `trafficState`

참조:

- `E:\Carrot\CarrotLink\assets\sidecar\sidecar.py:1955`
- `E:\Carrot\CarrotLink\assets\sidecar\sidecar.py:1959`
- `E:\Carrot\CarrotLink\assets\sidecar\sidecar.py:1960`

### 2.4 구현 판단

- 새 개념을 포팅하는 작업이라기보다, 현재 CarrotLink에서 이 마커를 stock 화면에서 더 명확히 노출하거나 스타일을 c3에 가깝게 맞추는 작업에 가깝다.
- 현재 투영 기준도 `modelPath`만 사용하도록 맞춰져, c3의 `model.getPosition()` 기준과 더 가깝다.
- 우선순위는 높고 난이도는 낮은 편이다.

---

## 3. BSD 그래픽

### 3.1 c3 원본 구조

BSD는 `BlindSpotDrawer`가 담당한다.

- 기본 입력: `leftBlindspot`, `rightBlindspot`
- 추가 입력: `leadLeft`, `leadRight`, `laneChangeState`, `laneChangeDirection`
- 결과: 좌우 바리어형 경고 그래픽

참조:

- `E:\Carrot\c3\selfdrive\ui\carrot.cc:1343`
- `E:\Carrot\c3\selfdrive\ui\carrot.cc:1397`
- `E:\Carrot\c3\selfdrive\ui\carrot.cc:1400`

### 3.2 CarrotLink 현재 상태

CarrotLink sidecar에는 이미 아래 값이 있다.

- `leftBlindspot`
- `rightBlindspot`
- `useLaneLineSpeed`
- `leftLaneLine`
- `rightLaneLine`

참조:

- `E:\Carrot\CarrotLink\assets\sidecar\sidecar.py:1880`
- `E:\Carrot\CarrotLink\assets\sidecar\sidecar.py:1885`
- `E:\Carrot\CarrotLink\assets\sidecar\sidecar.py:1886`

또한 기존 문서도 이 항목을 `E19 블라인드스팟 바리어`로 정리하면서 현재 미구현으로 보고 있다.

- `E:\Carrot\CarrotLink\docs\architecture\carrotpilot\CARROTPILOT_ONROAD_ELEMENT_MATRIX_2026-03-02_KO.md:81`
- `E:\Carrot\CarrotLink\docs\architecture\carrotpilot\CARROTPILOT_ONROAD_ELEMENT_MATRIX_2026-03-02_KO.md:206`

### 3.3 현재 구현 상태와 남은 차이

- 현재 CarrotLink는 `leftBlindspot/rightBlindspot` 금색 바리어를 그린다.
- 또한 `laneChangeState == preLaneChange`일 때는 `radarState.leadLeft/leadRight`를 우선 사용해 녹색 보조 바리어를 그린다.
정리:

- 좌우 바리어의 기본 좌표와 색 의미는 c3와 매우 가깝다.
- 보조 경고 입력도 `leadLeft/leadRight` 기준으로 맞춰졌다.
- `leadsLeft/right` fallback은 제거해 원본보다 더 관대하게 경고를 띄우지 않도록 정리됐다.

---

## 4. 하단 중앙 `Lane / Laneless`

### 4.1 c3 원본 구조

`PathDrawer`에서 `useLaneLineSpeed` 값으로 `LaneMode / Laneless`를 출력한다.
그리고 하단 중앙의 `2.6m | 2.9m | 0.8m` 계열 수치는 별도 추정값이 아니라
`lateralPlan.latDebugText`에서 만들어진다.

참조:

- `E:\Carrot\c3\selfdrive\ui\carrot.cc:1694`
- `E:\Carrot\c3\selfdrive\ui\carrot.cc:1696`
- `E:\Carrot\c3\selfdrive\ui\carrot.cc:3000`
- `E:\Carrot\c3\selfdrive\controls\lib\lateral_planner.py:259`
- `E:\Carrot\c3\selfdrive\controls\lib\lateral_planner.py:267`

### 4.2 CarrotLink 현재 상태

CarrotLink는 이미 `useLaneLineSpeed`를 읽고 있고, path mode 계산에도 쓰고 있다.
또한 sidecar가 `lateralPlan`을 구독하고 있으므로 `latDebugText`도 그대로 옮길 수 있다.

참조:

- `E:\Carrot\CarrotLink\lib\screens\drive\live_drive_canvas_overlay_models_components.dart:591`
- `E:\Carrot\CarrotLink\lib\screens\drive\live_drive_canvas_overlay_models_components.dart:604`
- `E:\Carrot\CarrotLink\lib\screens\drive\live_drive_canvas_overlay_models_components.dart:871`
- `E:\Carrot\CarrotLink\assets\sidecar\sidecar.py:2078`

### 4.3 현재 구현 상태와 남은 차이

- 하단 중앙 수치는 이제 `latDebugText`의 폭 3개만 따로 뽑는 방식이 아니라, 원본처럼 `latDebugText` 전체 문자열을 기준으로 그린다.
- `LaneMode / Laneless`는 사용자 선호를 반영해 CarrotLink에서는 하단 상시 라벨로 유지한다.

정리:

- 이 항목의 데이터 의미는 확정됐다.
- `leftLaneLine/rightLaneLine` raw 값이 아니라 `lateralPlan.latDebugText` 기반으로 보는 것이 맞다.
- 데이터 의미는 c3와 맞고, 표현은 CarrotLink 화면 구조에 맞춘 상시 라벨 방식이다.
- 상시 라벨은 geometry 유무와 분리해 유지하도록 보강됐다.

---

## 5. 우상단 `LD / LT / SR`

### 5.1 c3 원본 구조

이 문자열은 `drawDeviceInfo(...)` 블록의 디버그 텍스트다.

포함 값:

- `liveDelay`
- `liveTorqueParameters`
- `liveParameters.getSteerRatio()`
- `CustomSR`

참조:

- `E:\Carrot\c3\selfdrive\ui\carrot.cc:2696`
- `E:\Carrot\c3\selfdrive\ui\carrot.cc:2977`

### 5.2 CarrotLink 현재 상태

CarrotLink는 이제 sidecar에서 `liveDelay`, `liveTorqueParameters`, `liveParameters`, `CustomSR`
를 묶어 `stockDebug.topRightText`로 만든다.

확인된 점:

- sidecar payload 확장은 반영됨
- overlay도 우상단에 같은 포맷의 문자열을 그린다
- 큰 캔버스에서는 c3에 가까운 고정 margin/font를 우선하고, 작은 화면만 적응형 inset/ellipsis를 허용한다.

### 5.3 구현 판단

- 값 매핑과 문자열 포맷은 사실상 맞다.
- 현재 보정 방향은 "c3처럼 고정형 우상단 배치에 더 가깝게"이다.
  2. Flutter stock overlay 우상단 렌더 추가
  3. c3/c4 호환성 검증

정리:

- "그리기 자체"는 쉽지만
- "지금 데이터 계약으로 바로 구현"은 아니다

---

## 6. 최종 우선순위 제안

### 1차 구현 후보

1. `tf marker` (`9.8(0.32)`)
2. `BSD` 단순 바리어
3. 하단 중앙 `LaneMode / Laneless`

이유:

- 원본 의미가 명확하다
- CarrotLink가 이미 대부분의 입력을 갖고 있다
- 부작용 없이 stock 화면에 자연스럽게 녹이기 쉽다

### 2차 구현 후보

4. 우상단 `LD / LT / SR`
5. BSD의 lane-change/side-lead 강화 버전
6. 하단 중앙 `latDebugText` 기반 폭 수치/보조 텍스트

이유:

- 데이터 계약 확장 또는 화면 미세조정이 먼저 필요하다

---

## 7. 구현 시 권장 원칙

- 시각 기준은 `c3 carrot.cc`
- CarrotLink docs는 범위/정합성 참고용
- `c4`는 시각 기준보다 "호환성 검증 대상"으로 다룬다
- 새 데이터를 늘리기 전에, CarrotLink가 이미 가진 값으로 구현 가능한 것부터 먼저 붙인다

---

## 8. 관련 문서

- `E:\Carrot\CarrotLink\docs\architecture\carrotpilot\C3_STOCK_ONROAD_GRAPHICS_HUD_REFERENCE_2026-03-10_KO.md`
- `E:\Carrot\CarrotLink\docs\architecture\carrotpilot\CARROTPILOT_ONROAD_ELEMENT_MATRIX_2026-03-02_KO.md`
- `E:\Carrot\CarrotLink\docs\architecture\carrotpilot\CARROTPILOT_ORIGINAL_ONROAD_HUD_ANALYSIS_2026-03-07_KO.md`
