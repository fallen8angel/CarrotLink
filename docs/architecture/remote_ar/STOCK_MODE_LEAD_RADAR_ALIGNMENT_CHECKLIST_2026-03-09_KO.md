# STOCK MODE LEAD/RADAR ALIGNMENT CHECKLIST 2026-03-09

## 0. 범위

이 문서는 `stock 모드`의 리드/레이더 박스 정합만 다룬다.

- 포함:
  - road / wideRoad camera 위에 그리는 lead/radar box
  - `leadOne`, `leadTwo`, radar distance badge, radar vector
  - sidecar 2D payload -> Flutter overlay 정합
- 제외:
  - `webrtc` 모드
  - 하단 HUD semantic snapshot
  - TBT / nav overlay

핵심 목표는 `c3-v10 원본처럼 전방 차량을 따라다니는 lead/radar box`를 stock 모드에서 맞추는 것이다.


## 1. 현재 검토 결론

현재 CarrotLink 구현은 `원본과 완전히 같은 좌표계/수식`이 아니다.

원본 c3-v10:

- 같은 onroad renderer 안에서
- `radarState + model.position z + mapToScreen()`
- 단일 파이프라인으로 바로 그림

현재 CarrotLink stock:

- lane/path와 동일한 Flutter projection 경로로 `leadOne`, `leadTwo`, radar track을 다시 투영
- sidecar 2D는 `tfMarker`, debug/meta, fallback 참고용으로만 유지
- frame gap gate는 반영되어 있고, 최종 정합은 여전히 `video placement == projection placement` 일치 여부에 좌우됨

즉, 이전보다 원본과 가까워졌지만, 최종 lock은 여전히 실주행 검증이 필요하다.


## 1-1. 원본 리드/레이더 경로는 두 개다

원본 `c3-v10`에는 리드/레이더 관련 표시 경로가 2개 있다.

1. Qt onroad 기본 lead renderer

- `selfdrive/ui/qt/onroad/model.cc`
- `radarState.leadOne/leadTwo`를 `mapToScreen()`으로 바로 투영
- 기본 chevron/lead marker 계열

2. carrot overlay 전용 lead/radar box renderer

- `selfdrive/ui/carrot.cc`
- `leadOne`, `leadTwo`, radar/vision distance badge, radar vector, state text를 별도로 그림
- 사용자가 제시한 첫 번째 사진의 빨간 박스/빨간-파란 배지는 이 경로와 대응된다

즉, 사진 기준 비교 대상으로는 `qt/onroad`보다 `carrot.cc` 쪽이 더 직접적이다.


## 1-2. 현재 앱 구조는 3단계다

현재 CarrotLink의 stock 리드/레이더 box는 아래 3단계로 나뉜다.

1. 장치 원천값

- `radarState.leadOne`
- `radarState.leadTwo`
- `leadsLeft / leadsRight / leadsCenter`
- `modelV2.path / lane / roadEdge`

2. Flutter projection 생성

- `lib/screens/drive/live_drive_canvas_overlay_models_components.dart`
- raw `radarState.leadOne/leadTwo/leads*`를 snapshot에 보존

3. Flutter 렌더

- `lib/screens/drive/live_drive_canvas_overlay_components.dart`
- lane/path와 같은 `_ProjectionTransform + _mapToScreen()` 경로로 stock lead/radar를 직접 그림

4. sidecar 2D 보조 경로

- `assets/sidecar/carrotlink_sidecar.py`
- `tfMarker`, debug/meta, legacy/fallback용 2D 데이터 유지


## 1-3. 색상 체계 결론

사용자 기억의 `빨간색 / 파란색 / 주황색`은 주 리드 박스 기준으로 맞다.

leadOne 기준:

- 빨간색:
  - radar 기반
  - `radarTrackId < 1`
  - 원본 `carrot.cc`의 `COLOR_RED`
  - 현재 앱 sidecar의 `0xFFFF3B30`

- 주황색:
  - radar 기반이지만 SCC 판정이 아닌 경우
  - 원본 `carrot.cc`의 `COLOR_ORANGE`
  - 현재 앱 sidecar의 `0xFFFFA726`

- 파란색:
  - vision only / no radar
  - 원본 `carrot.cc`의 `COLOR_BLUE`
  - 현재 앱 sidecar의 `0xFF3D7BFF`

추가 색:

- leadTwo stroke:
  - 원본은 `COLOR_OCHRE`
  - 현재 앱은 `0xFFB68A3A`
- 일부 radar target badge / vector는 속도/모델 신뢰도에 따라 초록색도 사용한다

즉 첫 번째 사진의 핵심 색 구조는 `빨강 / 주황 / 파랑`이 맞고, 부가적으로 `황토색 leadTwo`, `일부 초록 speed badge`가 섞인다.


## 2. 원본 기준 동작

원본 c3-v10의 lead box 핵심 규칙:

1. lead center의 lateral 기준은 기본적으로 `-lead.getYRel()`
2. z 기준은 `model.position`의 `z`를 `dRel` 거리에서 샘플
3. 좌우 anchor는 `y ± 1.2`, `z + 1.22`
4. 박스 높이는 `path_width * 0.8`
5. smoothing은 `alpha = 0.85`
6. leadTwo는 `leadOne`과 충분히 멀 때만 그림

참조:

- `qt/onroad`: `selfdrive/ui/qt/onroad/model.cc`
- carrot overlay: `selfdrive/ui/carrot.cc`


## 2-1. 원본 색상과 의미

`carrot.cc` 기준:

- main lead box stroke:
  - SCC면 빨강
  - radar detected non-SCC면 주황
  - radar 미검출이면 파랑
- 좌측 distance badge:
  - radar distance
  - 빨강 또는 주황
- 우측 distance badge:
  - vision distance
  - 파랑
- leadTwo:
  - 황토색 stroke
  - active status면 붉은 alpha fill


## 3. 현재 앱 구현 차이

### 3-1. 가장 큰 구조 차이: 원본 단일 투영 vs 앱 projection + 화면 배치

원본 c3-v10:

- 같은 onroad renderer 안에서
- `radarState/model -> mapToScreen()`
- 한 번의 투영으로 바로 그림

현재 앱:

- Flutter가 raw radar/model 값을 직접 projection
- 최종 화면 배치는 Flutter의 source-to-canvas placement에 의존

즉 sidecar 2D 박스 재배치보다 훨씬 원본에 가까워졌지만, 최종 정합은 여전히 `stock video placement`와 projection placement 일치 여부에 좌우된다.


### 3-2. 현재 남아 있는 주요 차이: 최종 화면 배치 정합

현재 stock parity 경로는 badge/state text도 sidecar anchor fallback 없이 projection 결과만 사용한다.

남아 있는 핵심 차이는:

- 실제 stock video layer가 차지하는 위치/크기
- Flutter projection 결과가 올라가는 위치/크기

이 둘이 완전히 같은지 여부다.


### 3-3. 색 체계는 대체로 맞지만, 세부 스타일 parity는 완전하지 않음

현재 구현은 주 색 체계는 원본과 맞춰져 있다.

- leadOne: 빨강 / 주황 / 파랑
- leadTwo: 황토색
- radar target badge: 파랑 / 초록 / 주황 / 빨강

하지만 아래는 아직 완전 동일이라고 보긴 어렵다.

- badge 텍스트 색 전환
- 폰트 크기 / 패딩 / 코너 반경
- 상태 텍스트 세부 배치와 크기


### 3-4. frame mismatch는 1차 방어만 들어간 상태

현재는 `modelFrameId`와 `cameraFrameId` gap이 큰 경우 lead/radar 장식을 그리지 않도록 1차 gate가 들어가 있다.

다만 이것만으로 `video layer`와 `overlay layer`의 실제 배치가 완전히 같은지 보장되지는 않는다.


### 3-5. stock은 수식 parity는 많이 올라왔지만, 최종 lock은 실주행 검증이 필요

현재는 이미 다음이 반영된 상태다.

- `yRel`
- `y ± 1.2`
- `width * 0.8`
- `alpha = 0.85`
- `leadTwo + 3m`
- `x ± 80`, `y + 195` badge/state anchor 계열

즉 수식 parity는 꽤 올라왔다.

남은 핵심은:

- `displayTransform`와 실제 stock 영상 배치의 1:1 검증
- fallback 경로가 실제로 안 타는지 확인
- 실주행에서 앞차 중심에 계속 붙는지 확인


## 4. 우선순위 높은 원인 후보

### P0

- [x] leadOne/leadTwo lateral 기준을 `dPath 우선`이 아니라 `yRel 기준`으로 원본 parity 1차 반영
- [x] lead box shape를 `path_width * 0.8` 규칙으로 원본과 동일화 1차 반영
- [x] stock 모드에서 frame gap이 큰 경우 lead/radar box를 차단하는 1차 gate 반영

### P1

- [x] sidecar smoothing/clamp를 원본 `carrot.cc` 계열로 1차 정리
- [x] leadTwo 게이트를 원본과 동일한 거리 기준 계열로 1차 정리
- [x] radar badge / state text anchor를 원본 `x ± 80`, `y + 195` 계열 source-space 오프셋으로 재배치

### P2

- [x] road / wideRoad camera kind 전환, frame rewind, source 변경 시 anchor cache 즉시 무효화
- [ ] 실제 stock video placement와 Flutter projection placement가 완전히 같은지 실기기 로그로 검증
- [x] model/camera frame gap, selected camera kind를 overlay debug dump에 상시 기록
- [x] stock lead/radar 장식은 parity 확인 전까지 road camera에만 고정


## 4-4. 2026-03-09 1차 반영 내용

이번 1차 반영에서는 아래만 먼저 들어갔다.

- sidecar leadOne/leadTwo center 계산을 `yRel` 기준으로 정리
- sidecar leadOne/leadTwo box 높이를 `width * 0.8` 규칙으로 정리
- sidecar leadOne/leadTwo 폭 기준을 원본 `y ± 1.2` 계열로 조정
- sidecar leadTwo gate를 `leadOne보다 3m 이상 멀 때`만 보이도록 원본 계열로 조정
- primary lead anchor smoothing을 원본 `alpha = 0.85`로 복원
- primary lead width clamp를 원본 계열 `120..800`로 조정
- Flutter draw 단계에서 `modelFrameId`와 `cameraFrameId` gap이 큰 경우 lead/radar 장식을 그리지 않도록 gate 추가
- sidecar anchor cache를 `frame rewind / source 변경 / 큰 frame gap` 시 즉시 초기화
- overlay debug dump에 `selected camera`, `displayTransform`, `lead anchorCenter/anchorWidth/top/bottom`, `reset reason` 추가
- parity 검증 전까지 stock lead/radar 장식을 `road` camera에만 고정
- leadOne radar/vision badge 및 state text anchor를 원본 `carrot.cc`의 고정 오프셋 계열로 정리
- stock parity 경로에서는 radar/vision badge와 state text를 sidecar anchor가 있을 때만 그림 (bounds 기반 fallback 제거)
- stock parity 경로에서 raw `radarState`를 snapshot에 보존하고 Flutter projection으로 lead/radar를 직접 그림
- stock parity 경로에서 sidecar 2D는 TF/debug/fallback 참고용으로만 사용

아직 남아 있는 것:

- 실기기 parity 검증
- x/y clamp의 완전 parity 확인
- `displayTransform`와 실제 stock video placement의 1:1 검증
- leadTwo badge/state 계열이 필요할 경우 별도 규칙 정의


## 4-1. "콤마와 똑같이 선행차량 정위치 추종"을 위해 추가로 꼭 확인할 것

사용자 목표는 단순히 박스가 "대충 앞차 근처"에 있는 것이 아니라,

- 실제 선행차량 중심에
- 원본 c3-v10처럼
- 정위치로 붙어서 따라다니는 것

이다.

그 목표를 위해 아래 항목을 별도 필수 조건으로 둔다.

### Must-have A. source 좌표계와 camera 배치 일치

- [ ] stock camera surface placement와 sidecar `displayTransform`가 1:1로 같은지 검증
- [ ] road camera 기준 `sourceWidth/sourceHeight`가 실제 draw source와 같은지 검증
- [ ] crop/zoom/center offset이 video layer와 overlay layer에서 동일하게 적용되는지 캡처 기반 검증

완료 기준:

- 차가 화면 중앙에서 좌/우로 이동할 때 박스 중심도 같은 비율로 이동한다.

### Must-have B. lead center는 경로가 아니라 차량 기준

- [ ] leadOne/leadTwo center의 lateral 기준을 `dPath`가 아니라 `yRel`로 고정한 비교 실험
- [ ] `dPath`는 디버그 비교용 필드로만 남기고 박스 중심 계산에서는 분리 검증

완료 기준:

- 차선 중앙을 벗어난 선행차량도 차량 body에 맞게 박스가 붙는다.

### Must-have C. frame mismatch 방어

- [ ] `modelFrameId`, `cameraFrameId`, `roadFrameId` gap을 박스 draw 조건에 반영
- [ ] gap이 크면 박스 숨김 또는 degraded 처리
- [ ] frame mismatch 로그를 screenshot/video와 같이 저장

완료 기준:

- frame 어긋남이 큰 순간에 엉뚱한 차량에 박스가 잠깐 붙는 현상이 줄어든다.

### Must-have D. 원본과 같은 박스 shape

- [ ] main leadOne box 높이 규칙을 `path_width * 0.8`로 맞춘 버전 검증
- [ ] leadTwo도 원본과 같은 height/offset 계열 검증
- [ ] top point 투영 규칙은 parity 확인 후 유지/폐기 판단

완료 기준:

- 박스가 차량보다 과하게 위로 뜨거나 아래로 깔리지 않는다.


## 4-2. 정합 검증 로그/계측 보강

현재 문서에 있는 항목 외에 아래를 추가로 남기는 것이 좋다.

- [ ] screenshot와 함께 `dRel`, `yRel`, `dPath`, `radarTrackId`, `radar`, `status`를 한 줄 dump
- [x] sidecar에서 만든 `anchorCenter`, `anchorWidth`, `y_top`을 dump
- [ ] Flutter 매핑 후 bounds center / bounds width도 dump
- [x] video placement `left/top/width/height/scale/xOffset/yOffset`를 dump
- [x] road vs wideRoad, frame gap, displayTransform 값도 같이 기록

완료 기준:

- "왜 박스가 안 맞는지"를 감으로 보지 않고 한 frame 단위로 설명할 수 있다.


## 4-3. 디자인 개선 후보

정합이 먼저고, 디자인 개선은 그 다음이다.

하지만 원본 parity를 유지하면서 손볼 수 있는 디자인 후보는 있다.

### leadOne / leadTwo box

- [ ] 코너 반경을 원본에 맞게 유지하되 화면 해상도 비례로 약간 조정
- [ ] stroke 두께를 차량 거리/anchor width 기준으로 미세 조정
- [ ] leadTwo는 leadOne보다 한 단계 얇거나 덜 강조된 stroke로 유지

### 거리 배지

- [ ] 좌측 radar, 우측 vision 배지 위치를 `anchorCenter + badge offset` 기준으로 더 안정화
- [ ] badge 세로 위치가 차량 bumper 아래쪽에 과하게 내려가지 않는지 검증
- [ ] 숫자 패딩과 corner radius를 source가 아닌 화면 스케일 기준으로 보정
- [x] stock parity 경로에서 badge/state fallback 배치 제거

### 상태 텍스트 / 보조 라인

- [ ] state text가 차량 body를 가리지 않게 하단 offset 검토
- [ ] tf line / radar vector가 lead box와 과도하게 겹치지 않도록 계층 순서 검토
- [ ] 필요하면 lead box 내부 중앙 정렬 대신 하단 외부 정렬 버전도 비교

디자인 원칙:

- geometry parity를 깨지 않는 범위에서만 개선
- 좌표가 맞지 않은 상태에서 corner radius나 색만 손보지 않기


## 5. 구현 체크리스트

### 단계 1. stock 전용 parity 모드 고정

- [ ] lead/radar box parity 작업은 `stock`에서만 검증
- [ ] `webrtc` 경로는 기준 비교에서 제외
- [ ] stock + road camera를 1차 기준으로 고정
- [ ] wideRoad는 road parity 후 별도 검증

완료 기준:

- stock road camera에서만 재현/비교 스크린샷을 수집한다.


### 단계 2. 원본 수식 parity

- [ ] leadOne center는 `-yRel`만 사용한 버전으로 비교
- [ ] leadTwo center도 `-yRel`만 사용한 버전으로 비교
- [ ] z 샘플은 `model.position z @ dRel` 규칙 유지
- [ ] 좌우 폭은 `y ± 1.2`, `z + 1.22` 규칙 유지
- [ ] box top은 roof projection이 아니라 `path_width * 0.8` 규칙으로 원본 버전 구현
- [ ] smoothing `alpha = 0.85` 적용
- [ ] clamp 범위도 원본과 동일 계열로 맞춤

완료 기준:

- 정지 차량, 저속 추종, 곡선 도로에서 박스 중심이 차량 중심과 더 잘 맞는다.


### 단계 3. frame sync gate

- [ ] draw 시 `cameraFrameId`, `modelFrameId` gap 측정
- [ ] gap threshold 초과 시 lead/radar box 숨김 또는 약화
- [ ] road/wideRoad 선택 camera와 payload camera가 일치하는지 검증
- [ ] camera kind 바뀌면 anchor 상태 초기화

완료 기준:

- frame mismatch가 클 때 박스가 엉뚱한 차에 붙는 현상이 줄어든다.


### 단계 4. 실기기 검증

- [ ] 정차 후 출발
- [ ] 저속 시내 추종
- [ ] 중속 직선
- [ ] 곡선 도로
- [ ] leadOne/leadTwo 교체 상황
- [ ] radar only / vision only 추정 상황

수집 항목:

- [ ] stock screenshot/video
- [ ] `modelFrameId`, `cameraFrameId`, selected camera kind
- [ ] leadOne `dRel`, `yRel`, `dPath`, `radarTrackId`
- [ ] leadTwo `dRel`, `yRel`, `dPath`, `radarTrackId`
- [ ] anchor center / width


## 6. 코드 기준 점검 포인트

원본:

- `d:/CarrotLink/c3-v10-wip/selfdrive/ui/carrot.cc`
- `d:/CarrotLink/c3-v10-wip/selfdrive/ui/qt/onroad/model.cc`

현재 앱:

- `d:/CarrotLink/CarrotLink-dev/assets/sidecar/carrotlink_sidecar.py`
- `d:/CarrotLink/CarrotLink-dev/lib/screens/drive/live_drive_canvas_overlay_components.dart`
- `d:/CarrotLink/CarrotLink-dev/lib/screens/drive/live_drive_canvas_overlay_math_components.dart`
- `d:/CarrotLink/CarrotLink-dev/lib/screens/drive/live_drive_canvas_layout_components.dart`

특히 봐야 할 현재 차이:

- 원본 단일 투영 vs 현재 `sidecar -> Flutter` 2단계 투영
- Flutter의 `displayTransform` 재매핑과 실제 stock video placement의 일치 여부
- badge/state text fallback 경로가 실제로 발동하는지
- stock camera placement와 overlay placement의 실기기 정합


## 7. 권장 작업 순서

1. `stock road` 한정으로 parity 모드 만들기
2. lateral 기준을 `yRel`로 원복해 비교
3. box shape를 원본 규칙으로 원복해 비교
4. smoothing/clamp를 원본과 맞추기
5. frame gap gate 넣기
6. wideRoad까지 확장


## 8. 최종 목표

최종 목표는 `리드/레이더 box가 c3-v10처럼 실제 전방 차량을 안정적으로 따라다니는 것`이다.

즉 목표는 단순히 “보기 좋은 박스”가 아니라:

- 같은 차를 계속 추적하고
- 차 중심과 lateral 위치가 맞고
- frame mismatch 때 엉뚱한 차에 붙지 않으며
- stock road / wideRoad에서 일관되게 동작하는 것
