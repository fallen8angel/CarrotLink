# Stock 주행 상태 리팩토링 로드맵 (2026-03-19)

## 문서 목적
- `Stock` 주행화면에서 sidecar, 카메라, overlay sync, 상단 배너 상태가 과도하게 얽혀 있는 구조를 정리한다.
- `C3`/`C4`를 모두 지원하되, 원격 openpilot 코드 수정 없이 `CarrotLink` 내부에서 단순화하는 방향을 정의한다.
- "연결 준비 중", "재연결 중", "그래픽 지연", "연결 오류" 수준의 단순한 사용자 경험을 목표로 한다.

---

## 현재 문제 요약

### 1. 상태판단이 너무 많다
현재는 아래 4개 층이 각각 상태를 다시 판단한다.

1. sidecar
2. Flutter sidecar/runtime 관리
3. native camera attach/runtime
4. overlay sync/publish 경로

결과:
- 같은 상황을 서로 다르게 해석한다.
- `running -> verifying -> running` 왕복이 쉽게 발생한다.
- 실제 sidecar 전체가 죽지 않았는데도 "끊겼다/복구됐다"처럼 보인다.

### 2. 카메라와 그래픽이 같이 흔들린다
실제 문제는 종종 `7766` 카메라 websocket 재연결인데, UI는 이를 sidecar reconnect처럼 보이게 만든다.

결과:
- 짧은 camera reconnect도 배너 churn으로 확대된다.
- sidecar health는 정상인데 사용자 체감은 "계속 연결이 흔들린다"가 된다.

### 3. 앱이 sidecar 판단을 다시 조합한다
sidecar는 이미 다음 상태를 내린다.
- `graphicsReady`
- `vehicleReady`
- `controlsReady`
- `driveReady`
- `fullReady`
- `staleReasons`
- `missingFields`
- `serviceAges`

그런데 앱이 이를 다시 조합해 별도 판단을 수행한다.

결과:
- 조건이 중복된다.
- profile, health, camera attach, overlay stale이 서로 꼬인다.

### 4. UI 문구의 기준이 하나가 아니다
현재 배너 문구는 아래 여러 경로가 직접 바꾼다.
- sidecar 연결 상태
- camera attach 상태
- lifecycle 복귀 상태
- runtime recovery 상태

결과:
- 짧은 transient도 사용자에게 과하게 노출된다.

---

## 리팩토링 목표

### 핵심 목표
- 상태판단을 없애는 것이 아니라, **필수 판단만 남기고 한 군데로 몰기**
- 앱은 **카메라 transport + 렌더** 중심으로 단순화
- sidecar는 **데이터 readiness의 단일 truth** 역할 수행
- `C3`/`C4` 공통으로 메시지 churn 감소

### 사용자 기준 목표
- 상단 배너만 사용
- 노출 상태는 아래 4개 수준으로 제한
  - `연결 준비 중`
  - `재연결 중`
  - `그래픽 지연`
  - `연결 오류`

### 기술 목표
- `graphics core`는 가능한 한 항상 유지
  - `modelV2`
  - `liveCalibration`
  - `roadCameraState`
  - 필요 시 `wideRoadCameraState`
- `carState/radarState/controlsState` 문제로 그래픽까지 같이 죽지 않게 분리
- 짧은 reconnect 동안 `running` phase를 유지하고, 성공/복구 메시지 스팸을 제거

---

## 비목표
- remote openpilot `c3/c4` 코드를 수정해서 해결하는 것
- `Stock` 화면에서 raw service를 무가공으로 그대로 렌더하는 것
- exact frame sync를 완전히 포기하는 것
- WebRTC/7000 구조 자체를 이번 단계에서 갈아엎는 것

---

## 목표 구조

## 1. sidecar 책임
sidecar는 **데이터 readiness 판단의 단일 truth**가 된다.

### sidecar가 책임질 것
- `graphicsReady`
- `vehicleReady`
- `controlsReady`
- `driveReady`
- `fullReady`
- `staleReasons`
- `missingFields`
- `serviceAges`

### sidecar가 유지할 원칙
- `graphics core`는 vehicle/full 상태와 분리
- `C3`/`C4` 차이는 sidecar 내부 profile/health에서 흡수
- Flutter는 raw freshness를 다시 조합하지 않음

## 2. 앱 책임
앱은 다음 두 가지에 집중한다.

### A. camera transport state
- socket 연결 여부
- first visible frame 여부
- native view 재attach 필요 여부

### B. render state
- renderable snapshot 존재 여부
- degraded 렌더 가능 여부
- 오래 stale인지 여부

앱은 더 이상 다음을 직접 business logic으로 조합하지 않는다.
- `carState` freshness 의미 해석
- `graphicsReady/driveReady/fullReady` 재계산
- `C3`/`C4`별 startup 의미 재조립

## 3. 배너 책임
배너는 **단일 reducer**가 최종 상태를 계산한다.

입력:
- sidecar health snapshot
- camera attach/transport state
- overlay stale state
- hard error state

출력:
- `bannerState`
- `bannerTitle`
- `bannerDetail`

중요 원칙:
- camera reconnect는 sidecar disconnect와 구분
- 짧은 reconnect는 `재연결 중` 하나로만 표현
- success/recovered 메시지는 반복 출력하지 않음

---

## 단계별 로드맵

## Phase 1. 배너/phase reducer 통합

### 목표
- `_setSidecarPhase()` 직접 호출 지점을 줄인다.
- 배너 상태를 하나의 reducer에서만 계산한다.

### 작업
- camera, sidecar, lifecycle, runtime manager가 직접 phase/message를 세팅하는 구조 축소
- `DriveBannerState` 또는 유사 reducer 도입
- 성공/복구 메시지 반복 제거

### 기대 효과
- `running/verifying/running` churn 감소
- "연결됐다 끊겼다 반복" 체감 완화

---

## Phase 2. graphics-first 렌더 경로 단순화

### 목표
- `graphicsReady`와 renderable snapshot이 있으면 그래픽을 우선 표시한다.
- `carState/radarState` 부족을 이유로 그래픽까지 막지 않는다.

### 작업
- overlay publish 기준을 `graphicsReady` 중심으로 정리
- `strictFrameLock`에 막혀 그래픽이 장시간 숨는 경로 축소
- `synthetic sync` 상태에서도 최신 overlay 갱신 유지

### 기대 효과
- "영상만 뜨고 그래픽 없음" 감소
- 재진입 후 정합 메시지 장기 고착 감소

---

## Phase 3. profile 의미 단순화

### 목표
- `bootstrap`, `drive`, `full`의 의미를 명확히 나눈다.

### 권장 의미
- `bootstrap_graphics`
  - `modelV2`, `liveCalibration`, `roadCameraState`
- `drive_runtime`
  - 위 + `carState`, `controlsState`
- `full_runtime`
  - 위 + `radarState` 및 optional heavy fields

### 작업
- profile별 포함 서비스와 readiness 의미 문서화
- `C3`/`C4`별 steady-state profile 차이를 명확히 유지

### 기대 효과
- bootstrap과 steady-state의 역할이 명확해짐
- `C4` 전용 예외가 줄어듦

---

## Phase 4. 진단/로그 체계 단순화

### 목표
- 문제를 봤을 때 어느 층이 원인인지 빠르게 분리한다.

### 로그 핵심 필드
- sidecar
  - `graphicsReady`
  - `driveReady`
  - `fullReady`
  - `staleReasons`
  - `serviceAges`
- camera
  - `socketConnected`
  - `connectAttempts`
  - `sourceFrameCandidates`
  - `syntheticSyncActive`
  - `firstDecodedWithoutSyncAgeMs`
- render
  - `lastPublishedModelFrameId`
  - `overlay.staleActive`

### 기대 효과
- "sidecar가 죽은 건지", "카메라만 reconnect 중인지", "앱 sync가 과한 건지"를 빠르게 분리 가능

---

## 우선순위

### 가장 먼저 할 것
1. 배너/phase reducer 통합
2. camera reconnect와 sidecar reconnect 분리
3. success/recovered 메시지 스팸 제거

### 다음으로 할 것
4. `graphicsReady` 기준의 overlay publish 경로 단순화
5. `strictFrameLock` 영향 축소
6. profile 의미 재정리

---

## 리스크

### 1. 너무 느슨하게 만들 위험
- stale 그래픽이 너무 오래 남을 수 있다.
- 카메라와 어긋난 overlay가 잠깐 보일 수 있다.

대응:
- degraded 허용 시간과 stale 임계치를 명확히 분리

### 2. sidecar 단일 truth 의존 증가
- sidecar health가 잘못 계산되면 앱이 그대로 따라갈 수 있다.

대응:
- sidecar health contract를 문서화하고 진단 필드 강화

### 3. 기존 코드 경로와 충돌
- camera/lifecycle/runtime manager가 기존 phase 호출을 유지하면 reducer 통합 효과가 약하다.

대응:
- `_setSidecarPhase()` 직접 호출 지점 축소를 Phase 1 완료 기준으로 삼는다.

---

## 완료 기준

다음이 만족되면 1차 완료로 본다.

- Stock 상단 배너가 `연결 준비 중 / 재연결 중 / 그래픽 지연 / 연결 오류` 수준으로만 안정적으로 보인다.
- 짧은 `7766` reconnect 동안 `running/verifying/running` churn이 크게 줄어든다.
- sidecar health가 정상일 때는 camera reconnect가 있어도 "sidecar 끊김"처럼 보이지 않는다.
- `graphicsReady=true` 상태에서 carState/radarState 부족만으로 그래픽이 숨지 않는다.

---

## 참고 메모
- 이 로드맵은 remote openpilot 원본 수정 없이 `CarrotLink` 내부만 대상으로 한다.
- `C3`와 `C4`는 동일 정책을 최대한 공유하되, profile 구성 차이는 유지할 수 있다.
- 장기적으로는 sidecar health contract를 더 명확히 만들고, 앱은 렌더 중심 구조로 줄이는 것이 최종 방향이다.
