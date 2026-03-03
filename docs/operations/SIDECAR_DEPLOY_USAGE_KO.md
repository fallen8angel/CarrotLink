# CarrotLink Sidecar 배포/실행 가이드 (2026-03-02)

## 목적

`c3-v10-wip` 원본을 수정하지 않고, 콤마 기기 외부 경로(`/data/media/0/...`)에 별도 sidecar 프로세스를 배포/실행한다.

## 배포 경로/세션

- 배포 경로: `/data/media/0/carrotlink_sidecar`
- 실행 세션: `tmux carrotlink_sidecar`
- 기본 포트: `7766`
- WebSocket: `ws://<comma-ip>:7766/ws/live`
- 상태 확인: `http://127.0.0.1:7766/health`

## 앱 메뉴

`하단 메뉴 > 메뉴 > 관리 > CarrotLink Sidecar`

1. `사이드카 배포/업데이트`
2. `사이드카 시작` (P0/P1/P2/P3 선택)
3. `상태 확인`
4. `로그 확인`
5. `사이드카 중지`

## carrotpilot 구조 반영 방식

런처(`run_sidecar.sh`)가 아래 순서로 carrotpilot 구조를 따라간다.

1. openpilot repo 경로 자동 탐색: `/data/openpilot` -> `/home/comma/openpilot`
2. `PYTHONPATH`에 탐색된 repo를 주입
3. `python3 /data/media/0/carrotlink_sidecar/carrotlink_sidecar.py` 실행

즉, manager `process_config.py`를 수정하지 않고도 openpilot python 모듈(`cereal.messaging`)을 sidecar에서 직접 구독한다.

## 프로파일

- `P0`: carState, deviceState, selfdriveState
- `P1`: P0 + liveCalibration
- `P2`: P1 + modelV2
- `P3`: P2 + radarState

기본 권장: `P1`
