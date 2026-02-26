# CarrotMan APK `set` 기능 경로 메모 (carrotpilot/openpilot)

작성일: 2026-02-26

## 결론

- `carrotman APK`에서 `set` 버튼으로 carrotpilot 설정을 바꾸는 기능은
  **`carrot_man.py` 자체보다 `carrot_server.py`의 HTTP API 경로**를 사용할 가능성이 높다.
- 핵심 엔드포인트는 `POST /api/param_set` (기본 포트 `7000`) 이다.

## 확인 근거 (openpilot carrot 코드)

### 1) 실제 설정 저장(`Params.put*`) 경로는 `carrot_server.py`

- 설정 쓰기 핸들러: `selfdrive/carrot/carrot_server.py:473` (`api_param_set`)
- 내부 저장 함수:
  - `selfdrive/carrot/carrot_server.py:410` (`_set_param_value`)
  - `selfdrive/carrot/carrot_server.py:367` (`_put_typed`)
- `Params` 타입에 따라 `put_bool`, `put_int`, `put_float`, `put`, JSON 처리까지 수행

즉, 이 경로는 실제로 openpilot params를 변경하는 코드다.

### 2) 라우트 등록 확인

- `POST /api/param_set` 등록: `selfdrive/carrot/carrot_server.py:1121`
- 함께 존재하는 조회용 API:
  - `/api/settings`: `selfdrive/carrot/carrot_server.py:433`
  - `/api/params_bulk`: `selfdrive/carrot/carrot_server.py:455`

### 3) 서버 포트(기본값) 확인

- 기본 포트 `7000`: `selfdrive/carrot/carrot_server.py:1142`
- 실행 주석 예시에도 `http://<device_ip>:7000/` 표기: `selfdrive/carrot/carrot_server.py:12`

## `carrot_man.py` 쪽과의 구분

### `carrot_man.py`에서 확인된 것

- UDP 수신 스레드 (`7706`)는 수신 JSON을 `carrot_serv.update(json)`로 전달
  - `selfdrive/carrot/carrot_man.py:593`
  - `selfdrive/carrot/carrot_man.py:616`
- ZMQ (`7710`)는 일반 설정 set API가 아니라 아래 성격
  - `echo_cmd` 실행: `selfdrive/carrot/carrot_man.py:850`
  - `tmux_send`: `selfdrive/carrot/carrot_man.py:866`

### `carrot_serv.update()` 확인 결과

- `selfdrive/carrot/carrot_serv.py:1183` (`update`)
- 주로 네비/교통/위치/시간 정보 갱신 로직이며, 일반 파라미터 저장용 `Params.put*` 호출 경로는 본 확인 범위에서 발견하지 못함

## 운영 해석

- APK의 `set` 기능이 “carrot 설정값(params)”을 바꾸는 기능이라면,
  구현 경로는 보통 다음 흐름일 가능성이 큼:
  1. `carrot_server` (`7000`)에 HTTP 요청
  2. `POST /api/param_set`
  3. `name`, `value` 전달
  4. `Params.put*` 반영

## 참고

- 본 문서는 코드 정적 확인 기준 메모이며, APK 네트워크 트래픽 캡처/역공학 검증은 수행하지 않음.
- 실제 APK 구현이 `carrot_server` 대신 다른 래퍼 API를 쓸 가능성은 있으나, 설정 저장 최종 경로는 위 코드가 유력하다.

