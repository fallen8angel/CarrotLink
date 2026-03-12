# CarrotLink Sidecar 배포/실행 가이드 (2026-03-02)

## 목적

`c3-v10-wip` 원본을 수정하지 않고, openpilot repo 내부 managed folder에 sidecar 프로세스를 배포/실행한다.

## 배포 경로/세션

- 배포 경로: `<openpilot_repo>/selfdrive/carrotlink`
- 실행 세션: `tmux carrotlink_view`, `tmux carrotlink_camera`, `tmux carrotlink_diag`
- 기본 포트:
  - live/hud/control: `7766`
  - camera relay: `7768`
  - diag relay: `7769`
- WebSocket: `ws://<comma-ip>:7766/ws/live`
- Camera WebSocket: `ws://<comma-ip>:7768/ws/camera/road`
- 상태 확인:
  - core: `http://127.0.0.1:7766/health`
  - camera: `http://127.0.0.1:7768/health`
  - diag: `http://127.0.0.1:7769/health`

## 앱 메뉴

`하단 메뉴 > 메뉴 > 관리 > CarrotLink Sidecar`

1. `사이드카 배포/업데이트`
2. `사이드카 시작` (P0/P1/P2/P3 선택)
3. `상태 확인`
4. `로그 확인`
5. `사이드카 중지`

## carrotpilot 구조 반영 방식

런처(`sidecar.sh`, `camera.sh`, `diag.sh`)가 아래 순서로 carrotpilot 구조를 따라간다.

1. openpilot repo 경로 자동 탐색: `/data/openpilot` -> `/home/comma/openpilot`
2. `PYTHONPATH`에 탐색된 repo를 주입
3. `python3 <base>/sidecar.py`, `python3 <base>/camera.py`, `python3 <base>/diag.py` 실행

즉, manager `process_config.py`를 수정하지 않고도 openpilot python 모듈(`cereal.messaging`)을 sidecar에서 직접 구독한다. `diag.py`는 optional/debug snapshot을 별도 프로세스로 만들고, `sidecar.py`는 그 snapshot만 merge해서 core live payload를 보낸다.

## 프로파일

- `P0`: 최소 live state
- `P1`: P0 + liveCalibration
- `P2`: overlay core 기본
- `P3`: P2 + 추가 overlay core
- `P4`: high-rate alias, onroad에서는 보호 모드가 우선

기본 권장: `P1`
