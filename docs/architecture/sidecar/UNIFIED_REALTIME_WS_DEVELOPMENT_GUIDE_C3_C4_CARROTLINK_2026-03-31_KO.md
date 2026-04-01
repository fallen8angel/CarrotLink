# Unified Realtime WS 개발 작업 문서

작성일: 2026-03-31  
상태: 작업 기준 문서  
용도: 구현 시 계속 참고하는 개발 규칙/구조/추가삭제 절차

## 0. 같이 보는 문서

- 기준 설계서:
  - `UNIFIED_REALTIME_WS_REFACTOR_PLAN_C3_C4_CARROTLINK_2026-03-31_KO.md`
- 페이즈 문서:
  - `UNIFIED_REALTIME_WS_PHASES_C3_C4_CARROTLINK_2026-03-31_KO.md`

## 1. 개발 원칙

- `c3/c4`를 따로 개발하지 않는다
- `web`과 `CarrotLink`를 실시간 데이터 consumer 관점에서 구분하지 않는다
- semantic realtime data는 `/ws/live`
- 영상은 `/ws/camera/road`
- `road`를 기본 카메라 기준으로 둔다
- HUD 배치는 `c3` 스타일 기준
- 그래픽 좌표/맵핑/리드 박스 원리는 CarrotLink 기준
- `SubMaster + Params`는 `RealtimeBroker`만 구독한다
- `RealtimeBroker`는 렌더된 그래픽이 아니라 **그래픽을 그릴 데이터**를 보낸다
- `/ws/live`는 canonical UI snapshot이 아니라 **service-raw semantic payload**를 보낸다
- `web`과 `CarrotLink`는 받은 service payload를 각 클라이언트에서 직접 조립/연산/렌더한다

## 1.1 현재 구현 상태

현재 이미 확인된 것:

- `realtime broker`는 `SubMaster + Params`를 읽어 service-raw payload를 생성한다
- `/ws/live`가 실제로 살아 있고, 첫 메시지로 `hello`를 보낸다
- 이후 payload가 연속 전송된다
- `alive 아님 / 데이터 없음` 상태는 예외가 아니라 안전한 빈 상태로 내려간다
- `msgpack` 기본 동작과 offline 보장 경로까지 확인했다

다음 구현 목표:

- web/CarrotLink consumer를 `services.<serviceName>` 기준으로 정리
- HUD/overlay 조립 로직을 broker 밖으로 더 이동
- active churn이 큰 service는 더 얇게 유지

## 2. 권장 디렉터리 구조

공통 경로:

```text
selfdrive/carrot/realtime/
  broker.py
  services.py
  snapshot.py
  normalize.py
  contract.py
  transports/
    live_ws.py
    camera_ws.py
```

원칙:

- `c3.py`, `c4.py` 같은 분리 파일 금지
- `c3 전용`, `c4 전용` 브로커 금지
- 같은 상대 경로, 같은 파일명, 같은 책임 유지

## 3. 파일별 책임

### `broker.py`

- 메인 루프
- 갱신 주기 관리
- snapshot 생성 호출
- fan-out 호출

### `services.py`

- 공통 서비스 세트
- 선택 서비스 세트
- 서비스 추가/삭제 지점 단일화

### `snapshot.py`

- `/ws/live`용 service-raw semantic payload 조립
- service별 최소 semantic field relay 작성

### `normalize.py`

- 값 형태 보정
- 서비스 유무 차이 흡수
- 공통 snapshot 기준 보정

### `contract.py`

- `/ws/live` schema 정의
- schema version
- capability flags

### `transports/live_ws.py`

- `/ws/live`
- `msgpack` 직렬화
- client queue / drop policy / fan-out

### `transports/camera_ws.py`

- `/ws/camera/road`
- road frame dispatch
- video queue / fan-out

## 4. 서비스 목록 관리 규칙

서비스는 최소한 두 그룹으로 나눈다.

### `COMMON_SERVICES`

- 거의 모든 snapshot에서 필요
- 제거 시 기본 contract가 흔들릴 수 있음

예:

- `selfdriveState`
- `carState`
- `controlsState`
- `modelV2`
- `roadCameraState`
- `deviceState`

### `OPTIONAL_SERVICES`

- 특정 기능 확장용
- 제거 시 일부 기능만 비활성

예:

- `radarState`
- `carrotMan`
- `gpsLocationExternal`
- `lateralPlan`
- `navInstructionCarrot`
- `wideRoadCameraState`

## 5. SubMaster 항목 주석 규칙

각 항목 옆에는 최소한 다음을 적는다.

- 무엇에 쓰는지
- 필수인지 선택인지
- 누가 소비하는지
- 제거 시 영향

예:

```python
COMMON_SERVICES = [
  "selfdriveState",   # HUD 기본 상태, 제거 시 기본 contract 흔들림
  "carState",         # 속도/기어/브레이크, 대부분 consumer가 사용
  "modelV2",          # 차선/path/lead 그래픽 원본
  "roadCameraState",  # road frameId / timestamp / sync 기준
]
```

## 6. `/ws/live` payload 작성 규칙

기본 구조는 다음을 유지한다.

```json
{
  "meta": {},
  "runtime": {},
  "services": {
    "carState": {},
    "selfdriveState": {},
    "controlsState": {},
    "longitudinalPlan": {},
    "modelV2": {},
    "roadCameraState": {}
  }
}
```

원칙:

- top-level `camera/model/vehicle/...` 재조립을 늘리지 않는다
- service 이름 중심으로 보낸다
- raw capnp 바이트 그대로 보내지는 않지만, UI 전용 문자열/상태 재조립은 broker에서 하지 않는다
- 문자열 포맷보다 semantic field/service field 우선
- 서버가 미리 그린 결과물을 싣지 않는다
- lane/path/lead box는 **클라이언트 렌더용 입력 데이터**로 보내고, 좌표/표시 계산은 클라이언트가 맡는다

## 6.1 브라우저 렌더 기준

브라우저도 `CarrotLink`와 동일하게:

- `/ws/live` snapshot 수신
- 필요 시 `/ws/camera/road` frame 수신
- 브라우저 디바이스에서 HUD / lane / path / lead box 직접 렌더

구조로 간다.

즉:

- broker는 **producer**
- 브라우저/앱은 **renderer**

로 역할을 분리한다.

## 7. 경량화/안정화 최소 원칙

- `msgpack` 기본화
- snapshot은 한 번 encode 후 fan-out
- client별 bounded queue
- 오래된 payload drop, 최신 우선
- road-only 영상
- `/health` 대신 data-plane freshness 우선

현재 메모:

- 지금은 `/ws/live`가 동작 중이지만, `msgpack` 미설치 시 JSON fallback으로 송출될 수 있다
- 이는 오류가 아니라 브랜치 기본 의존성 작업이 아직 끝나지 않은 상태다

## 8. 검증 기준

초기 검증은 consumer UI가 아니라 다음으로 한다.

- TMUX 로그
- broker stdout/stderr
- `/ws/live` raw 수신
- `/ws/camera/road` raw 수신

본다:

- 첫 snapshot 도착
- snapshot age
- 첫 road frame 도착
- frame age
- queue/drop 동작

## 9. 추가/삭제 절차

### 서비스 추가

1. `services.py`에 추가
2. 주석에 용도/영향 기록
3. `snapshot.py`에 매핑 추가
4. `contract.py`에 노출 필드 반영

### 서비스 제거

1. 실제 consumer 사용 여부 확인
2. `snapshot.py` 매핑 제거
3. `contract.py` deprecated 여부 반영
4. 주석과 문서 동기화

## 10. 하지 말아야 할 것

- `c3`와 `c4`를 따로 구현하기
- 브랜치별 전용 파일 만들기
- consumer마다 다른 실시간 schema 만들기
- `/ws/state`, `/ws/carstate`, `/ws/hud`를 새 구조에 다시 복제하기
- 모든 로직을 `broker.py` 하나에 몰아넣기
- `/health`를 운영 경로의 주 판단 기준으로 쓰기

## 11. 한 줄 요약

> 브로커는 공통 경로에, 공통 파일 구조로, 최소 책임 분리만 두고 구현한다. 추가/삭제는 `services.py`와 `snapshot.py`를 중심으로 관리한다.
