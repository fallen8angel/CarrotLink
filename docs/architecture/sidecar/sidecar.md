# Sidecar Refactor And Migration Spec

## 목적

CarrotLink sidecar는 openpilot `v10` 코드를 직접 수정하지 않고 side-load로 기능을 붙인다.  
다만 현재 monolith 구조는 onroad 중 `card`, `calibrationd`, `locationd`, `selfdrived`, `modeld`의 timing 취약 구간에 간접 부하를 줄 수 있다.  
이 문서는 다음 두 목표를 동시에 만족시키는 리팩토링 기준이다.

- 기존 openpilot 그래픽 무결성 유지
- HUD, overlay, camera relay, diag 기능 유지 또는 확장

관련 앱 lifecycle / shared runtime 후속 계획:
- [`../link/CARROTLINK_SHARED_RUNTIME_REFACTOR_PLAN_2026-03-11_KO.md`](D:/CarrotLink/CarrotLink-dev/docs/architecture/link/CARROTLINK_SHARED_RUNTIME_REFACTOR_PLAN_2026-03-11_KO.md)

## 현재 문제

현재 [`assets/sidecar/sidecar.py`](D:/CarrotLink/CarrotLink-dev/assets/sidecar/sidecar.py)는 overlay core에 가까운 책임을 맡고 있고, [`assets/sidecar/camera.py`](D:/CarrotLink/CarrotLink-dev/assets/sidecar/camera.py), [`assets/sidecar/hud.py`](D:/CarrotLink/CarrotLink-dev/assets/sidecar/hud.py), [`assets/sidecar/diag.py`](D:/CarrotLink/CarrotLink-dev/assets/sidecar/diag.py)가 별도 프로세스로 분리돼 있다.

이 상태는 이전 giant monolith보다는 안전하고, upstream 구독 owner도 이제 사실상 `camera + sidecar(data broker)` 두 축으로 정리됐다.  
다만 compatibility 경로와 얇은 wrapper가 남아 있어, `role/session`을 포함한 wire contract 정리가 다음 단계다.

현재 기준:
- `sidecar.py`는 직접 `SubMaster(PROFILE_SERVICES)`와 `SubMaster(HUD_SERVICES)`, `PROFILE_OPTIONAL_SERVICES`를 연다.
- `hud.py`는 openpilot를 다시 구독하지 않고 `sidecar.py /ws/hud`를 프록시하는 thin wrapper다.
- `diag.py`도 openpilot를 다시 구독하지 않고 `sidecar.py`가 기록한 `diag_snapshot.json`을 서빙하는 thin wrapper다.

즉 upstream openpilot producer 관점에서 남아 있는 실질 owner는 `camera.py`와 `sidecar.py`다.

로그 기준으로 실제 증상은 아래 체인과 연결된다.

- `carState freq/alive` 흔들림
- `liveCalibration valid/updated` 문제
- `livePose.inputsOK` 하락
- `locationdTemporaryError`, `commIssue`, HUD 값 누락

즉 sidecar가 직접 `locationd`를 깨는 것은 아니어도, 현재 구조는 취약한 구간을 더 흔들 수 있다.

## 설계 원칙

### 1. openpilot core 우선

다음은 절대 sidecar보다 우선한다.

- `card`
- `locationd`
- `selfdrived`
- `modeld`
- `plannerd`
- `dmonitoringd`

sidecar는 항상 fail-open이어야 한다. sidecar가 죽거나 축소돼도 기본 openpilot 주행 그래픽과 주행 제어는 유지돼야 한다.

### 2. side-load 유지

리팩토링 후에도 `v10` 저장소 코드는 수정하지 않는다.

- openpilot python/module registration을 추가하지 않음
- `system/manager/process_config.py`에 새 프로세스 등록하지 않음
- SSH로 side-load 파일 배포 후 `tmux/nohup`로만 실행

### 3. monolith 금지, owner 단일화

카메라 relay, overlay core, HUD/diag를 하나의 giant process에 몰지 않는다.

다만 `분리된 프로세스 = upstream 구독 owner도 분리`를 뜻하면 안 된다.

최종 기준:
- `camera`는 별도 owner 허용
- openpilot state/data는 `data broker` 하나만 구독 owner
- HUD/diag는 별도 프로세스를 유지하더라도 openpilot를 다시 직접 구독하지 않고 broker 결과만 소비

### 4. latest-wins

backpressure가 생기면 queue를 늘리지 말고 최신 snapshot 하나만 유지한다.

### 5. onroad 보호 모드

다음 징후가 보이면 sidecar는 자동으로 축소돼야 한다.

- `liveCalibration valid=false`
- `carState freq_ok=false`
- `modeld` frame drop 증가
- `commIssue` 동반

## 목표 아키텍처

## 현재 구현 상태

현재 `dev` 기준으로 이미 들어간 분리는 아래까지다.

- 배포 경로를 `<openpilot_repo>/selfdrive/carrotlink` 우선으로 전환
- legacy base path / legacy repo folder / stale tmux session 자동 정리
- 파일명 단순화
  - `sidecar.py`, `sidecar.sh`, `camera.py`, `camera.sh`, `hud.py`, `hud.sh`
- HUD 전용 `SubMaster` 분리
  - HUD-only 세션은 `modelV2/radarState/roadCameraState`를 poll하지 않음
- live relay 내부 `core` / `optional` 분리 시작
  - `self.sm`는 `carState/selfdriveState/controlsState/longitudinalPlan/liveCalibration/modelV2/radarState/roadCameraState` 등 core만 구독
  - `self.sm_optional`은 `deviceState/peripheralState/gps/lateralPlan/carrotMan/navInstructionCarrot` 등 optional/diag만 구독
  - `self.sm_optional`은 `full` payload가 실제 필요할 때만 열고, `minimal/camera_only`나 live client 부재 시에는 닫음
  - optional payload는 cache + background sampler + 저주기 rebuild로만 갱신
  - live websocket broadcast는 steady-state에서 optional `SubMaster.update(0)`를 직접 호출하지 않음
- camera relay 프로세스 분리 시작
  - `camera.py`가 `7768`에서 `/ws/camera/*`, `/camera_quality`, `/health`를 담당
  - `sidecar.py`는 `7766`에서 `ws/live`, `ws/hud`, `/health`, `/profile`만 담당
- diag relay 프로세스 분리 시작
- `diag.py`가 `7769`에서 `/health`, `/optional`을 담당
- optional/debug snapshot은 이제 `sidecar.py`가 broker owner로 직접 `diag_snapshot.json`에 기록
- `diag.py`는 그 snapshot을 서빙하는 thin wrapper만 담당
- `hud.py`는 `7767`에서 dedicated HUD endpoint를 유지하되, broker `7766/ws/hud`를 프록시하는 thin wrapper만 담당

즉 현재 구조는 `sidecar(core broker) / camera / hud proxy / diag snapshot server` 4단까지 왔다.

최종 권장 구조는 아래다.
- `camera relay`는 별도 유지
- `data broker`는 하나만 openpilot를 구독
- `HUD`, `overlay`, `diag`는 broker의 논리 stream 또는 broker 결과물만 소비

따라서 이후 작업은 구조 분리보다 `stream contract`, `role/session`, `compatibility 경로 제거`가 중심이 된다.

현재 구현 메모:
- app의 기본 HUD consumer는 `7767`만 사용하고 `7766/ws/hud` fallback은 기본 경로에서 제거됐다.
- `sidecar.py /ws/live`, `sidecar.py /ws/hud`는 `role/session` query를 받아 health에서 세션별 상태를 노출한다.

주의:
- sidecar 구조 정리만으로 HOME HUD / drive HUD / drive overlay의 "다시 초기화되는 느낌"이 완전히 사라지진 않는다.
- 그 문제는 앱 쪽 shared runtime / shared snapshot cache 리팩토링이 별도로 필요하다.

### 프로세스 분리

최종 목표는 아래 2축 구조다.

1. `camera relay`
2. `data broker`

`data broker` 내부 논리 stream:
- `overlay`
- `hud`
- `diag`

즉 포트/프로세스는 일부 남아도 될 수 있지만, upstream openpilot 구독 owner는 `camera`와 `data broker` 두 축만 남기는 것이 목표다.

### 권장 스크립트 구성

- `camera.py`
  - camera websocket relay 전용
  - live video fanout만 담당
- `data broker`
  - `modelV2`, `radarState`, `roadCameraState`, `wideRoadCameraState`, `liveCalibration`, `controlsState`
  - `carState`, `selfdriveState`, `deviceState`, `peripheralState`
  - `gpsLocation*`, `carrotMan`, `navInstructionCarrot`, `debugPlot`
  - 위 데이터를 openpilot에서 한 번만 읽고, `overlay/hud/diag` 논리 stream으로 fanout

주의:
- `hud.py`와 `diag.py`는 최종적으로 broker client 또는 thin wrapper여야 한다.
- 현재 구현은 이미 그 방향으로 들어와 있다.
- 별도 프로세스를 유지하더라도 openpilot를 다시 직접 구독하면 안 된다.

### 채널 분리

각 논리 stream은 필요한 데이터만 fanout 받는다.

- HUD minimal
  - `carState`
  - `selfdriveState`
  - `deviceState`
  - `peripheralState`
- overlay core
  - `modelV2`
  - `radarState`
  - `roadCameraState`
  - `wideRoadCameraState`
  - `liveCalibration`
  - `controlsState`
- diag/debug
  - `gpsLocation*`
  - `carrotMan`
  - `navInstructionCarrot`
  - `debugPlot`

### pipeline 분리

각 프로세스는 내부에서도 아래 3단을 분리한다.

1. poll
2. transform/cache
3. broadcast

`ws send`는 payload build를 직접 수행하지 않는다. optional/diag는 background sampler가 cache를 갱신하고, broadcast는 최신 cache만 fanout하는 방향을 유지한다.

### protocol / transport 기준

최종 기준은 `새로운 무거운 transport`보다 `ownership 정리`다.

- openpilot 내부:
  - 기존 `cereal/msgq` 계약 유지
- 앱 외부:
  - `camera`는 별도 transport 유지
  - `data broker`는 versioned WebSocket multiplex 사용

비권장:
- HUD 전용 owner와 compatibility owner를 둘 다 영구 유지하는 구조
- `hud.py`, `diag.py`가 openpilot를 직접 다시 구독하는 구조
- `camera`와 `telemetry`를 하나의 giant websocket으로 합치는 구조

## 배포 경로 정책

### 이전 구조

기존 배포 경로:

- `/data/media/0/carrotlink_sidecar`

### 새 구조

새 기본 경로:

- `<openpilot_repo>/selfdrive/carrotlink`

의도는 다음과 같다.

- openpilot repo 내부에서 sidecar 관련 파일을 한곳에 모음
- `selfdrive/carrot` 같은 예전 legacy 흔적과 구분
- HUD와 주행 sidecar를 같은 managed folder 아래에서 관리

### migration 규칙

앱은 아래를 자동 정리해야 한다.

- `/data/media/0/carrotlink_sidecar`
- `<repo>/selfdrive/carrot`
- 예전 `tmux` 세션
- 예전 pid/log/revision 파일
- legacy process registration 흔적

정리 기준은 idempotent 해야 한다.

- marker 파일로 cleanup 1회 완료 상태 기록
- 필요 시 force cleanup 지원

## fail-open 정책

### 원칙

기존 openpilot 그래픽은 절대 YOLO, diag, sidecar debug 때문에 흔들리면 안 된다.

### 강등 순서

1. `full`
2. `minimal`
3. `camera_only`

### 모드별 허용 기능

#### full

- camera relay
- overlay core
- HUD
- diag/debug

#### minimal

- camera relay
- overlay core
- HUD
- non-essential diag 저주기 또는 off

#### camera_only

- camera relay
- 최소 HUD
- overlay core 중 non-essential field 제외
- diag/debug off

## onroad 마진 가이드

절대 다시 공격적으로 줄이지 말 것:

- engaged 상태의 relay interval을 무리하게 `30~40ms`대로 낮추는 것
- relay cycle마다 heavy payload를 재조립하는 것
- `debugPlot`, `gps`, `carrotMan`, `navInstructionCarrot`를 high-frequency push로 보내는 것

튜닝 전 확인할 징후:

- `locationd output invalid`
- `cameraOdometry freq_ok=False`
- stale `liveCalibration`
- `Dropped N frames`
- `commIssue`

이 징후가 보이면 sidecar는 더 줄여야지 더 키우면 안 된다.

## 앱 서비스 책임

### `SidecarService`

역할:

- 주행 sidecar deploy/start/stop/status
- migration cleanup
- revision 관리
- launcher/supervisor 관리

### `LinkHudService`

역할:

- HUD sidecar deploy/start/ensure/status
- 주행 sidecar와 동일한 base path 사용
- migration cleanup 공유

### 추후 launcher

필요 시 `run_carrotlink_stack.sh` 같은 supervisor launcher를 추가할 수 있다.

역할:

- `camera relay`
- `overlay core relay`
- `diag relay`
- `HUD relay`

여러 프로세스를 함께 띄우되, 각 세션/로그는 분리한다.

## 단계별 리팩토링 순서

### Phase 0. 응급 안정화

- load shed 유지
- onroad 시 aggressive profile 제한
- `/health`에 강등 상태와 이유 표기

### Phase 1. 배포 경로 migration

- `selfdrive/carrotlink`를 기본 base path로 전환
- `/data/media/0/carrotlink_sidecar` legacy 자동 정리
- `selfdrive/carrot` legacy 자동 정리

### Phase 2. monolith 내부 분리

- poll / cache / broadcast 분리
- heavy field를 low-rate/on-demand로 전환
- slim schema 도입

### Phase 3. 프로세스 분리

- `camera relay` 분리
- `overlay core` 분리
- `hud/diag` 분리

### Phase 4. supervisor 정리

- multi-sidecar launcher 정식화
- 앱 deploy/health/status를 새 구조에 맞게 통합

## 하지 말아야 할 것

- `v10`의 `process_config.py`에 새 sidecar 프로세스 상시 등록
- openpilot core python 파일 직접 수정
- sidecar가 `locationd`, `livePose`, GPS 값을 위조하거나 덮어쓰기
- frame-sync core를 YOLO/debug 용 synthetic signal과 섞기

## 결론

기능 유지와 openpilot 무결성을 같이 잡으려면 답은 전체 리버트가 아니라 구조 분리다.

- `v10` 코드는 건드리지 않는다
- side-load는 유지한다
- monolith sidecar는 단계적으로 해체한다
- `camera / overlay core / hud-diag` 분리형으로 간다
- 앱은 새 경로 배포와 legacy cleanup을 자동 처리한다
