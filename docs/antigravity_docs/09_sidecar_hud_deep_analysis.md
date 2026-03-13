# 사이드카 & HUD 시스템 정밀 분석

> CarrotLink 앱과 comma 디바이스 간 실시간 주행 데이터 & 카메라 스트리밍을 담당하는 핵심 인프라

---

## 전체 아키텍처

```
┌─ comma 디바이스 (CarrotPilot) ─────────────────────────────────────────────┐
│                                                                             │
│  openpilot 프로세스들                                                       │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐          │
│  │ carState │ │ modelV2  │ │radarState│ │ camerad  │ │carrotMan │          │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘          │
│       │cereal IPC   │            │            │            │                │
│       ▼             ▼            ▼            ▼            ▼                │
│  ┌──────────────────────────────────────────────────────────────┐           │
│  │                   sidecar.py (포트 7766)                      │           │
│  │  SidecarApp: SubMaster 구독 → JSON 변환 → WebSocket 브로드캐스트 │          │
│  │  CameraRelayHub: 인코딩 프레임 → 바이너리 WebSocket 릴레이     │           │
│  │  Overlay2D: 3D 차공간 → 2D 화면 좌표 변환 엔진               │           │
│  └──────────┬──────────────────────────┬───────────────────────┘           │
│             │ WebSocket                │ WebSocket                          │
│             ▼                          ▼                                    │
│  ┌──────────────────┐     ┌──────────────────┐                             │
│  │  hud.py (7767)   │     │ camera.py (7768) │                             │
│  │  HUD 프록시 릴레이 │     │ 카메라 전용 릴레이│                              │
│  └────────┬─────────┘     └────────┬─────────┘                             │
│           │                        │          ┌──────────────────┐          │
│           │                        │          │ diag.py (7769)   │          │
│           │                        │          │ 진단 스냅샷 서버   │          │
│           │                        │          └──────────────────┘          │
└───────────┼────────────────────────┼──────────────────────────────────────┘
            │ SSH 터널 / 직접 연결     │
            ▼                        ▼
┌─ CarrotLink 앱 (Flutter) ──────────────────────────────────────────────────┐
│                                                                             │
│  ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐      │
│  │ SidecarService   │    │ LinkHudService   │    │ LiveDriveCanvas  │      │
│  │ (배포/시작/중지)  │    │ (HUD 프록시 관리) │    │ (24개 컴포넌트)  │      │
│  └──────────────────┘    └──────────────────┘    └──────────────────┘      │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 1. sidecar.py (3773줄, 135KB) — 핵심 브로커

### 1.1 역할

comma 디바이스에서 실행되는 **중앙 데이터 브로커**. openpilot 프로세스의 cereal 메시지를 구독하여 JSON으로 변환하고, WebSocket을 통해 CarrotLink 앱에 실시간 전달합니다.

### 1.2 SidecarApp 클래스

#### 프로필 시스템 (p0~p4)

데이터 전송량과 갱신 주기를 제어하는 5단계 프로필:

| 프로필 | 주기 | 코어 서비스 | 용도 |
|--------|------|------------|------|
| **p0** | 160ms | carState, selfdriveState | 최소 모니터링 |
| **p1** | 120ms | + liveCalibration | 기본 |
| **p2** | 40ms | + carControl, controlsState, longitudinalPlan, modelV2, radarState, 카메라상태 | **기본값**, 오버레이 지원 |
| **p3** | 40ms | p2와 동일 | p2 별칭 |
| **p4** | 30ms | p2와 동일 | 고속 HUD 갱신 |

#### 선택적(Optional) 서비스

p2 이상에서 추가 구독: `deviceState`, `peripheralState`, `gpsLocation`, `lateralPlan`, `carrotMan`, `navInstructionCarrot`

#### HUD 전용 서비스

별도 SubMaster로 관리: `carState`, `deviceState`, `selfdriveState`, `peripheralState`, `longitudinalPlan`, `carrotMan`, `gpsLocation`

#### Safety Mode (안전 모드)

openpilot이 engaged(활성) 상태일 때 사이드카가 시스템을 방해하지 않도록 보호:

| 모드 | 조건 | 조치 |
|------|------|------|
| `full` | 비활성 | 모든 데이터 전송 |
| `minimal` | engaged + 코어 서비스 불안정 | 모델/레이더 비포함, 갱신 주기 증가 |
| `camera_only` | engaged + 심각한 불안정 | 카메라만 전송 |

### 1.3 Overlay2D 엔진 (_build_overlay2d)

3D 차량 공간(car space) 좌표를 2D 카메라 이미지 좌표로 투영하는 핵심 엔진:

#### 좌표 변환 파이프라인

```
차량 3D 좌표 (x=거리, y=횡방향, z=높이)
    │
    ▼ _rotation_from_euler(calibration_rpy)
카메라 보정 회전 적용
    │
    ▼ _VIEW_FROM_DEVICE 매트릭스 적용
디바이스→뷰 좌표 변환
    │
    ▼ _intrinsic_for_source(focal, center)
카메라 내부 파라미터 적용 (narrow: f=2648, wide: f=567)
    │
    ▼ perspective division (px/pz, py/pz)
2D 화면 좌표 (sx, sy)
```

#### 렌더링 요소

| 요소 | 함수 | 설명 |
|------|------|------|
| **주행 경로** | `_map_line_to_track_vertices_dist` | 거리 기반 경로 폴리곤, 너비/높이 보간 |
| **차선** | `_map_line_to_polygon_points` | 차선 라인 폴리곤 (좌/우 오프셋) |
| **도로 경계** | 동일 | 도로 가장자리 |
| **선행 차량 1** | `_project_lead_pair_from_car_space` | 레이더 리드 → 2D 바운딩 박스 (스무딩 α=0.85) |
| **선행 차량 2** | 동일 | 2차 리드 (3m+ 간격, 별도 트랙) |
| **레이더 표적** | `_map_to_source` | 좌/우/중앙 레이더 트랙 → 2D 포인트 |
| **TF 마커** | 직접 투영 | 희망 차간거리 위치 표시 |

#### 리드 앵커 스무딩

```python
alpha = 0.85  # 이전 값 85% 유지
fx = fx_old * 0.85 + new_x * 0.15
fy = fy_old * 0.85 + new_y * 0.15
fw = fw_old * 0.85 + new_w * 0.15
```

프레임 리와인드, 소스 크기 변경, 프레임 갭 > 6 시 앵커 리셋

#### 경로 색상 시스템

pathColor 값 ≥ 20일 때 가속/감속에 따른 동적 색상:

| 값 | 의미 |
|-----|------|
| 10 | 감속 중 (리드 감지, accel < -0.5) |
| 11 | 가속 중 (리드 감지, accel ≥ 0.5) |
| 12 | 유지 (리드 감지, |accel| < 0.5) |
| 13 | 활성 (리드 미감지) |
| 19 | 비활성 |

### 1.4 CameraRelayHub 클래스

openpilot의 인코딩된 H.264 영상 프레임을 WebSocket으로 릴레이:

#### 카메라 소스

| 카메라 | 서비스 후보 (quality 모드) | 서비스 후보 (stable 모드) |
|--------|--------------------------|--------------------------|
| road | roadEncodeData → livestreamRoadEncodeData | livestreamRoadEncodeData만 |
| wideRoad | wideRoadEncodeData → livestreamWideRoadEncodeData | livestreamWideRoadEncodeData만 |
| driver | driverEncodeData → livestreamDriverEncodeData | livestreamDriverEncodeData만 |

#### 프레임 패킹 형식

```
[4바이트 big-endian: 메타 JSON 길이][메타 JSON][H.264 페이로드]
```

메타 JSON 포함 필드: camera, codec, frameId, width, height, keyFrame, size, ts

#### 품질 모드

- **quality**: 풀 인코딩 우선, 큐 타임아웃 350ms, 실패 허용 5회
- **stable**: 라이브스트림 우선, 큐 타임아웃 250ms, 실패 허용 4회

### 1.5 HUD 스냅샷 빌더

sidecar.py가 생성하는 HUD JSON 페이로드 구조:

```json
{
  "vehicle": { "speedClusterKph", "setSpeedClusterKph", "gearText", "longActive", "latActive" },
  "tempControl": { "mode": "apply|eco|hidden", "speedKph", "sourceRaw", "isDecel" },
  "driveMode": { "code", "nameOriginal": "ECO|SAFE|NORM|FAST", "kind" },
  "gap": { "personalityRaw", "displayValue", "barCount" },
  "limits": { "mode": "hidden|limit|camera|section", "displaySpeedKph", "isOverLimit" },
  "connectivity": { "activeCarrot", "badgeMode": "hidden|apm|apn" },
  "signals": { "visualState": "off|red|green", "redDot" },
  "gps": { "hasFix", "provider" },
  "device": { "cpuTempAvgC", "memUsagePct", "diskUsedPct", "voltV", "metricPrimaryMode" },
  "visibility": { "showDeviceState", "showDateTimeMode" }
}
```

### 1.6 디버그 플롯 (8모드)

| 모드 | 제목 | Y축 | G축 | O축 |
|------|------|------|------|------|
| 1 | Accel | a_ego | a_target | a_out |
| 2 | Speed/Accel | speed_0 | v_ego | a_ego |
| 3 | Model | pos_32 | vel_32 | vel_0 |
| 4 | Lead | accel | a_lead | v_rel |
| 5 | Lead | a_ego | a_lead | j_lead |
| 6 | Steer | actual | desire | output |
| 7 | SteerA | Actual | Target | Offset×10 |
| 8 | SteerA | curvature×10000 | | |

### 1.7 aiohttp 웹 서버 엔드포인트

| 엔드포인트 | 메서드 | 기능 |
|-----------|--------|------|
| `/health` | GET | 헬스체크 (kind: carrotlink_sidecar_broker_v1) |
| `/ws/live` | WS | 실시간 주행 데이터 스트리밍 |
| `/ws/hud` | WS | HUD 데이터 스트리밍 |
| `/ws/camera/{camera}` | WS | 카메라 프레임 릴레이 (road/wideRoad/driver) |
| `/camera_quality` | GET/POST | 카메라 품질 모드 조회/변경 |

---

## 2. hud.py (209줄) — HUD 프록시 릴레이

### 역할

sidecar.py의 `/ws/hud` 엔드포인트에 연결하여 HUD 데이터를 받아, 다수의 CarrotLink 클라이언트에 팬아웃(fan-out) 합니다.

### 핵심 로직

```
upstream (sidecar:7766/ws/hud)  ──▶  HudProxyApp  ──▶  클라이언트 N개
                                     ├── 자동 재연결 (0.35초)
                                     ├── heartbeat (20초)
                                     └── 마지막 메시지 캐시 (새 클라이언트에 즉시 전송)
```

### 엔드포인트

| 엔드포인트 | 포트 | 기능 |
|-----------|------|------|
| `/health` | 7767 | 프록시 헬스 + 업스트림 브로커 헬스 조회 |
| `/ws/hud` | 7767 | HUD WebSocket (role, session 쿼리 파라미터) |

---

## 3. camera.py (106줄) — 카메라 전용 릴레이

### 역할

sidecar.py의 CameraRelayHub를 별도 포트(7768)에서 노출. 독립 실행 가능.

### 엔드포인트

| 엔드포인트 | 기능 |
|-----------|------|
| `/health` | 카메라 릴레이 헬스 |
| `/camera_quality` GET | 현재 품질 모드 |
| `/camera_quality` POST | 품질 모드 변경 |
| `/ws/camera/{camera}` | 카메라 H.264 스트림 |

---

## 4. diag.py (90줄) — 진단 스냅샷 서버

### 역할

sidecar.py가 주기적으로 저장하는 `diag_snapshot.json` 파일을 HTTP로 서빙.

### 엔드포인트

| 엔드포인트 | 포트 | 기능 |
|-----------|------|------|
| `/health` | 7769 | 스냅샷 상태, 캐시 나이 |
| `/optional` | 7769 | 전체 optional 데이터 조회 |

---

## 5. SidecarService (Dart, 1520줄) — Flutter 측 관리자

### 역할

CarrotLink 앱에서 comma 디바이스의 사이드카 프로세스를 **SSH로 원격 관리**합니다.

### 생명주기

```
ensureRunning()
  ├── 헬스체크 OK → 완료
  ├── start() 시도
  │   └── "SIDECAR_ARTIFACTS_NOT_DEPLOYED" → deploy() → start()
  ├── 리비전 불일치 → deploy() → start()
  └── 최종 start()
```

### 핵심 기능

| 메서드 | 기능 |
|--------|------|
| `deploy()` | 6개 파일(sidecar.py/sh, camera.py/sh, diag.py/sh) SFTP 전송 + 리비전 저장 |
| `start()` | tmux 세션으로 3개 프로세스(sidecar, ~~camera~~, diag) 시작, 포트 헬스체크 대기 |
| `stop()` | tmux 세션 종료, PID kill, 포트 정리 |
| `status()` | 실행 상태, PID, 포트, 리비전, 로그 크기 조회 |
| `ensureRunning()` | 호스트별 쿨다운(20초) + 자동 배포/시작 |
| `cleanupLegacyInstall()` | 구버전 파일/프로세스 정리 |

### 리비전 관리

SHA-256 기반 6개 파일 해시 조합 → 리비전 문자열:

```
carrotlink-sidecar-rev-v3
py={sha256}
sh={sha256}
camera_py={sha256}
camera_sh={sha256}
diag_py={sha256}
diag_sh={sha256}
```

로컬(앱 에셋)과 리모트(기기) 리비전이 다르면 자동 재배포.

### 포트 할당

| 프로세스 | 포트 | 세션 이름 |
|---------|------|----------|
| sidecar (메인 브로커) | 7766 | carrotlink_view |
| hud (프록시) | 7767 | carrotlink_hud |
| camera (릴레이) | 7768 | carrotlink_camera |
| diag (진단) | 7769 | carrotlink_diag |

---

## 6. LinkHudService (Dart, 761줄) — HUD 프록시 관리자

### 역할

HUD 프록시(hud.py)를 SSH로 배포/시작/관리. SidecarService와 동일한 패턴이지만 hud.py/hud.sh 2개 파일만 관리합니다.

### 리비전 스키마

```
carrot-linkhud-rev-v1
py={sha256}
sh={sha256}
```

---

## 7. Shell 스크립트 (4개)

### sidecar.sh

- openpilot 레포 자동 탐색 (/data/openpilot 등 4개 경로)
- `launch_env.sh` 소싱 (openpilot 런타임 환경 일치)
- PYTHONPATH, 환경변수 설정 후 `sidecar.py` 실행

### camera.sh

- sidecar.sh와 동일 구조
- 카메라 전용 환경변수(`CARROTLINK_CAMERA_PORT` 등) 설정 후 `camera.py` 실행

### hud.sh

- 경량. `CARROTLINK_HUD_PORT`, `CARROTLINK_SIDECAR_PORT` 설정 후 `hud.py` 실행
- openpilot PYTHONPATH 불필요 (hud.py는 cereal 미사용)

### diag.sh

- 경량. `CARROTLINK_DIAG_PORT` 설정 후 `diag.py` 실행
- openpilot PYTHONPATH 불필요

---

## 8. 데이터 흐름 요약

### 실시간 주행 데이터 (Live)

```
openpilot SubMaster → sidecar.py SidecarApp
  → sm.update(0) → 각 서비스별 payload 생성
  → overlay2D 계산 (경로/차선/리드/레이더 2D 투영)
  → optional 데이터 합산
  → JSON WebSocket 브로드캐스트 → CarrotLink 앱 LiveDriveCanvas
```

### HUD 데이터

```
openpilot SubMaster → sidecar.py sm_hud
  → _build_hud_snapshot() → 속도/기어/제한속도/신호/GPS/기기상태 JSON
  → WebSocket /ws/hud → hud.py 프록시 → CarrotLink 앱 HUD 위젯
```

### 카메라 스트리밍

```
openpilot camerad → encode → cereal messaging
  → sidecar.py CameraRelayHub._camera_producer_loop()
  → H.264 프레임 패킹 (메타 JSON + 바이너리)
  → asyncio.Queue → _camera_sender_loop()
  → WebSocket 바이너리 → CarrotLink 앱 카메라 뷰
```
