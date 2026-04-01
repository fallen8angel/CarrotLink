# Unified Realtime WS 페이즈 문서

작성일: 2026-03-31  
상태: 작업 기준 문서  
용도: 실제 구현 순서와 완료 기준을 관리하는 로드맵

## 0. 이 문서의 역할

이 문서는 아래 문서와 같이 본다.

- 기준 설계서:
  - `UNIFIED_REALTIME_WS_REFACTOR_PLAN_C3_C4_CARROTLINK_2026-03-31_KO.md`
- 개발 작업 문서:
  - `UNIFIED_REALTIME_WS_DEVELOPMENT_GUIDE_C3_C4_CARROTLINK_2026-03-31_KO.md`

원칙:

- `c3/c4`를 따로 개발하지 않는다
- `web`과 `CarrotLink`를 실시간 데이터 consumer 관점에서 구분하지 않는다
- semantic realtime data는 `/ws/live`
- 영상은 `/ws/camera/road`

## 1. 현재 최종 목표

```text
SubMaster + Params
        ->
  RealtimeBroker
        ->
 service-raw semantic payload
        ->
/ws/live + /ws/camera/road
        ->
 web + CarrotLink
```

## 1.1 현재 진행 상태

현재 기준:

- `selfdrive/carrot/realtime/` 공통 골격 생성 완료
- `COMMON_SERVICES` / `OPTIONAL_SERVICES` 분리 완료
- service-raw semantic payload 1차 구현 완료
- `alive 아님 / 데이터 없음 -> 안전한 빈값` 처리 반영 완료
- TMUX runner 기준 offroad / alive 상태 검증 완료
- `/ws/live` 서버 연결 완료
- `/ws/live`에서 `hello -> payload -> payload` 순서 확인 완료
- `/ws/camera/road` direct relay 검증 완료
- `/ws/live`는 현재 `msgpack` 기본 동작까지 확인 완료
- 현재 방향은 canonical snapshot이 아니라 `services.<serviceName>` 중심 raw semantic relay 쪽으로 확정

현재 단계 해석:

- `Phase 1`: 완료
- `Phase 2`: 기본 완료
- `Phase 3`: `/ws/live` 기준 1차 통과
- 다음 우선순위: `raw semantic relay` contract 기준으로 web/CarrotLink consumer 조립 정리

## 2. Phase 1. 공통 realtime 골격 만들기

목표:

- `selfdrive/carrot/realtime/` 경로 확정
- `broker.py`
- `services.py`
- `snapshot.py`
- `normalize.py`
- `contract.py`
- `transports/live_ws.py`
- `transports/camera_ws.py`

원칙:

- `c3 전용`, `c4 전용` 파일을 만들지 않는다
- 같은 상대 경로, 같은 파일명, 같은 코드 구조 유지
- 아직 web/CarrotLink consumer 연결은 하지 않는다

완료 기준:

- 브로커 프로세스가 단독으로 뜬다
- `SubMaster + Params`를 한 번만 읽는다
- 메모리 안에서 공통 realtime payload 생성 가능

## 3. Phase 2. service-raw payload 고정

목표:

- `/ws/live` schema 확정
- HUD / stock 그래픽 / sync 메타 필드 확정
- `road` 카메라 기준 정책 확정

원칙:

- semantic field 우선
- HUD 배치는 `c3` 스타일 기준
- 차선/path/lead box projection 원리는 CarrotLink 기준

완료 기준:

- payload 필드 표와 실제 코드가 대응
- web/CarrotLink가 같은 필드 계약 사용 가능

## 4. Phase 3. broker 단독 검증

목표:

- TMUX 로그
- stdout/stderr 로그
- `/ws/live`
- `/ws/camera/road`

만으로 broker 동작 검증

원칙:

- consumer UI 연결은 하지 않는다
- `/health`에 의존하지 않는다
- data-plane freshness로만 본다

완료 기준:

- snapshot 주기 정상
- stale 판정 정상
- road camera frame 송출 정상
- fan-out 정책 정상

현재 상태:

- runner 단독 검증은 사실상 통과
- `/ws/live` raw 수신도 통과
- `hello` 누락 이슈는 수정 완료
- `/ws/camera/road` transport도 검증 완료

## 5. Phase 4. legacy 경로 축소 준비

대상:

- `/ws/state`
- `/ws/carstate`
- `/ws/hud`
- `/stream`

의미:

- 이 단계는 삭제가 아니라 삭제 준비 단계다
- 누가 아직 쓰는지 확인
- 새 경로로 치환 가능한 상태를 만든다

완료 기준:

- legacy 경로가 새 contract로 치환 가능한 상태
- consumer 연결 전 의존성 맵 정리 완료

## 6. Phase 5. consumer 연결

목표:

- `web`
- `CarrotLink`

가 공통 broker endpoint를 소비하게 연결

원칙:

- 둘을 다른 consumer 구조로 설계하지 않는다
- 같은 `/ws/live`
- 같은 `/ws/camera/road`
- 차이는 렌더/UI에서만 둔다

완료 기준:

- web/CarrotLink 모두 같은 contract로 동작
- consumer가 broker 내부 구현을 모른다

## 7. Phase 6. 정리와 제거

목표:

- legacy WS 제거
- debug 전용 경로 최소화
- 문서와 코드 contract 최종 동기화

완료 기준:

- 실시간 데이터 경로는 `/ws/live`
- 영상 경로는 `/ws/camera/road`
- 터미널은 `/ws/terminal`만 별도 유지

## 8. 현재 작업 우선순위

지금 당장 집중할 것:

1. `msgpack`을 브랜치 기본 의존성으로 포함
2. `/ws/live`를 `msgpack` 기본 인코딩으로 확인
3. `web`에서 `/ws/live` raw 수신 연결
4. 기존 HUD 최소셋을 `/ws/live` 기준으로 매핑
5. `/ws/camera/road` transport 구현
6. 이후 frame sync / stock graphics 연결

지금 하지 않을 것:

- web consumer 연결
- CarrotLink consumer 연결
- legacy endpoint 제거
- wide 사용자 노출 제거

주의:

- 위의 "지금 하지 않을 것"은 문서 초안 기준이고, 현재는 `web`의 `/ws/live` 소비 연결을 다음 단계로 본다
- 다만 `CarrotLink` consumer 연결과 legacy 제거는 여전히 뒤로 둔다

## 9. 한 줄 요약

> 지금은 consumer보다 producer를 먼저 완성하는 단계이고, 브로커를 단독으로 충분히 검증한 뒤 web과 CarrotLink를 같은 contract로 붙인다.
