# CarrotLink Shared Runtime Refactor Plan (2026-03-11)

## 목적
- HOME HUD, drive HUD, stock overlay가 화면 전환/백그라운드/주행 진입마다 다시 초기화되는 느낌을 줄인다.
- `camera`는 빨리 보이고 `overlay/hud`는 늦게 붙는 현재 체감을 구조적으로 줄인다.
- sidecar `camera + data broker` 구조 위에서 앱 쪽 consumer/lifecycle를 재정리한다.

## 한 줄 결론
현재 병목은 `transport 속도`보다 `화면 lifecycle에 묶인 세션 구조`다.  
따라서 다음 대형 작업은 `single app-scope runtime + shared latest snapshot cache`로 가는 것이 맞다.

## 왜 필요한가
현재 구현은 아래 성격이 강하다.

- HOME HUD는 탭 활성/foreground 상태에 영향을 크게 받는다.
- drive 화면은 별도 sidecar runtime/startup/recovery를 탄다.
- HUD/overlay가 화면 단위 attach/detach를 반복한다.
- 짧은 탭 이동, 백그라운드, 주행 진입에서도 세션이 다시 붙는 느낌이 난다.

즉 사용성 문제는 개별 websocket bug보다, `연결 유지`와 `UI 표시`가 분리되지 않은 데서 온다.

## 현재 구조의 핵심 한계

### 1. camera는 비교적 빨리 뜨지만 overlay/hud는 늦다
- `camera.py`는 별도 relay라 빠르게 올라올 수 있다.
- 하지만 overlay/hud는 broker snapshot, frame sync, widget lifecycle을 같이 기다린다.

### 2. 세션이 화면 단위다
- HOME HUD와 drive HUD가 같은 host라도 화면별 attach/detach가 많다.
- drive overlay도 화면 진입 시점에 sidecar runtime과 강하게 결합돼 있다.

### 3. foreground 전체에서 살아 있는 shared runtime이 없다
- 지금은 dashboard 전역 prewarm이 일부 들어가 있지만,
- `snapshot store`, `shared session`, `lifecycle grace`까지 완전히 통합된 상태는 아니다.

## 목표 구조

### 1. app-scope shared runtime manager
앱 전체에서 host별로 하나만 유지한다.

역할:
- broker/camera prewarm
- sidecar/hud health 확인
- latest HUD snapshot cache
- latest overlay snapshot cache
- session/host lifecycle 관리

### 2. UI는 consumer만
- HOME HUD
- drive HUD
- drive overlay

위 셋은 transport owner가 아니라, shared runtime이 가진 최신 snapshot만 소비한다.

### 3. 탭 전환과 transport를 분리
- 탭 비활성은 UI 갱신 빈도만 줄인다.
- transport/session은 foreground 동안 유지한다.
- 긴 백그라운드/명시 disconnect/host 변경에서만 실제 정리한다.

### 4. last-good snapshot 유지
- 데이터가 잠깐 비면 즉시 빈 화면으로 떨어지지 않는다.
- `stale` 상태 표시로 전환하고, 최신 정상 snapshot을 잠시 유지한다.

## sidecar와의 관계
이 작업은 `sidecar.py / camera.py / hud.py / diag.py` 구조를 뒤집는 작업이 아니다.

전제:
- `camera.py`는 video owner 유지
- `sidecar.py`는 data broker 유지
- `hud.py`, `diag.py`는 thin wrapper 또는 compatibility로 축소

즉 다음 페이즈의 본체는 sidecar보다 **앱 consumer/lifecycle 리팩토링**이다.

## 작업량 평가
작업량은 `중간`보다 크고 `대형`에 가깝다.

이유:
- `features/hud`
- `home_tab`
- `dashboard_screen`
- `drive canvas runtime/lifecycle/sync`
- `sidecar service`

까지 동시에 영향이 있다.

단순 버그 수정이 아니라 아래 3축을 같이 바꿔야 한다.

1. session ownership
2. snapshot cache
3. lifecycle policy

## 단계별 작업안

### Phase 1. shared runtime manager 추가
- dashboard/app scope에 host별 runtime manager 도입
- broker/camera prewarm, health, snapshot cache를 한곳으로 이동

현재 진행:
- 1차 slice로 `features/hud`에 shared controller lease를 넣어
  HOME/drive HUD가 같은 live subscription을 재사용하도록 바꿈
- widget dispose가 즉시 HUD transport를 끊지 않도록 변경
- 2차 slice로 app scope runtime provider를 올려
  SSH 연결 시 broker prewarm과 shared HUD bind를 전역에서 유지하도록 바꿈
- 이후 runtime이 shared overlay websocket/buffer cache까지 맡도록 확장
- 짧은 background에서는 overlay shared runtime을 grace로 유지하고,
  sync miss에서는 last-good overlay + stale banner를 사용하도록 변경

### Phase 2. HOME HUD 분리
- HOME HUD는 `_realtimeWorkEnabled`와 transport를 분리
- 화면은 shared HUD snapshot만 구독

### Phase 3. drive overlay 연계
- drive 화면은 camera surface만 새로 붙이고
- overlay snapshot은 shared runtime cache를 먼저 사용
- startup provisional sync는 shared cache와 결합

### Phase 4. stale/idle 정책 정리
- 짧은 background/tab switch는 유지
- 긴 background만 idle/sleep
- 빈 화면 대신 stale 표시

### Phase 5. compatibility 정리
- 필요하면 `hud.py` 경로를 더 축소
- `7766/ws/hud`와 `7767` owner 규칙을 최종 정리

현재 진행:
- 앱 HUD consumer 기본 경로를 `7767/ws/hud` 우선으로 전환
- shared/runtime HUD bind 시 `sidecar + hud.py proxy` bootstrap을 같이 ensure
- `7766/ws/hud`는 fallback compatibility 경로로 유지

## 기대 효과
- HOME HUD가 주행 진입 없이 바로 뜸
- 탭 이동 후 HUD가 다시 초기화되는 느낌 감소
- stock 주행화면에서 영상과 그래픽이 더 자연스럽게 같이 뜸
- drive 진입 후 sidecar start 체감 감소
- background 복귀 시 fast resume 가능

## 리스크
- dashboard scope state가 커질 수 있음
- host 변경/재연결 시 session invalidation을 정확히 처리해야 함
- stale snapshot 유지 시간을 과하게 잡으면 오래된 정보가 남을 수 있음

## 지금 시점의 권장 판단
- 방향은 맞다.
- 하지만 영향 범위가 넓어서, 기능 급한 상황에 바로 들어가기보다 문서 기준을 먼저 고정하는 게 맞다.
- 다음 실제 구현은 이 문서를 기준으로 phase 단위로 잘라 들어간다.
